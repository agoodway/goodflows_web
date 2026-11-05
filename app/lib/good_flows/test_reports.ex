defmodule GoodFlows.TestReports do
  @moduledoc """
  Storage-only ingestion of externally generated test reports.

  `ingest/4` validates one `test-timings/1` report
  (`GoodFlows.TestReports.Validator`), derives its per-report completion
  (`GoodFlows.TestReports.Completion`) and stores it immutably under the
  authenticated account and the project from the request path. The project
  slug never enters the stored document.

  Idempotency: the identity `(account, project, workflow_run_id, job,
  report_id)` names one immutable document. The first insert is
  acknowledged as new. A retry whose validated body is the same JSON value
  (object key order ignored; arrays compared in order; strings compared
  exactly; numbers, which validation limits to integers, compared by value)
  is acknowledged as a duplicate with the same server id. Any other body
  under that identity is a conflict and changes nothing, including for an
  incomplete stored report. Concurrent requests follow the same rules
  through `INSERT … ON CONFLICT DO NOTHING`. Each row stores
  `payload_digest`, the SHA-256 of the payload's canonical JSON
  (`GoodFlows.TestReports.Document.digest/1`: keys sorted, no whitespace),
  so a retry that loses the insert is compared by digest in SQL: the
  payload is sent once per request and the stored payload is never loaded
  into the application.

  A connection failure, timeout or other transient database error while
  storing returns `{:error, :test_report_storage_unavailable}`. The commit
  outcome is then unknown: the row may exist. Publishers retry the same
  frozen body, which resolves through the rules above. Any other database
  error is logged by SQLSTATE and constraint name only and raised as
  `GoodFlows.TestReports.StorageError` (a 500), never with its message.

  There is no query, update, delete or retention API, no aggregation across
  partitions and no link to Spry runs. Insert and comparison queries run
  with `log: false` so the document never reaches Ecto logs, and with the
  timeout `config :good_flows, :test_report_db_timeout_ms` (default 15,000).
  """
  import Ecto.Query

  require Logger

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.Projects.Project
  alias GoodFlows.TestReports.{Document, Report, StorageError, Store, Validator}

  @identity [:account_id, :project_id, :workflow_run_id, :job, :report_id]

  @default_db_timeout_ms 15_000

  # SQLSTATE classes meaning the server could not finish the statement now,
  # rather than that the request was wrong: 08 connection exception,
  # 40 transaction rollback (serialization failure, deadlock), 53
  # insufficient resources, 57 operator intervention (query canceled,
  # shutdown, cannot connect now).
  @transient_classes ["08", "40", "53", "57"]
  # 55P03 lock_not_available; 25006 read_only_sql_transaction (a failover
  # left the connection on a standby).
  @transient_codes ["55P03", "25006"]

  @project_fkey "test_reports_project_id_fkey"

  @typedoc "Storage acknowledgement returned to the publisher."
  @type ack :: %{
          id: Ecto.UUID.t(),
          report_id: String.t(),
          status: String.t(),
          duplicate: boolean()
        }

  @typedoc "Reasons `ingest/4` can fail."
  @type error ::
          {:invalid_test_report, Validator.errors()}
          | :not_found
          | :test_report_conflict
          | :test_report_storage_unavailable

  @doc """
  Validates and stores `document` (decoded JSON, see
  `GoodFlows.TestReports.Document.decode/1`) for `project` of `account`.

  Returns `{:ok, ack}` where `ack.duplicate` tells an exact retry from a
  first insert, or `{:error, reason}`:

    * `{:invalid_test_report, errors}` – the document breaks the contract;
      nothing is stored
    * `:not_found` – the project is not the account's, or it was deleted
      before the insert; nothing is stored
    * `:test_report_conflict` – the identity holds a different document
    * `:test_report_storage_unavailable` – the database could not be
      reached, timed out or failed transiently, or a referenced row other
      than the project (the submitting API key or the account) disappeared
      before the insert; a retry re-authenticates
  """
  @spec ingest(Account.t(), Project.t(), ApiKey.t() | nil, term()) ::
          {:ok, ack()} | {:error, error()}
  def ingest(%Account{id: account_id}, %Project{account_id: account_id} = project, api_key, doc) do
    case Validator.validate(doc) do
      {:ok, payload, status} -> persist(fn -> store(project, api_key, payload, status) end)
      {:error, {:invalid, errors}} -> {:error, {:invalid_test_report, errors}}
    end
  end

  def ingest(%Account{}, %Project{}, _api_key, _document), do: {:error, :not_found}

  @doc "The timeout for the insert and comparison queries, in milliseconds."
  @spec db_timeout_ms() :: pos_integer()
  def db_timeout_ms,
    do: Application.get_env(:good_flows, :test_report_db_timeout_ms, @default_db_timeout_ms)

  defp store(project, api_key, payload, status) do
    row = row(project, api_key, payload, status)

    case Store.insert_all(Report, [row],
           on_conflict: :nothing,
           conflict_target: @identity,
           returning: [:id, :status],
           log: false,
           timeout: db_timeout_ms()
         ) do
      {1, [%Report{id: id, status: status}]} -> {:ok, ack(id, row.report_id, status, false)}
      {0, []} -> compare(row)
    end
  end

  # Only the digest is sent: the payload went once with the insert.
  defp compare(row) do
    query =
      from r in Report,
        where:
          r.account_id == ^row.account_id and r.project_id == ^row.project_id and
            r.workflow_run_id == ^row.workflow_run_id and r.job == ^row.job and
            r.report_id == ^row.report_id,
        select: {r.id, r.status, r.payload_digest == ^row.payload_digest}

    case Store.one(query, log: false, timeout: db_timeout_ms()) do
      {id, status, true} -> {:ok, ack(id, row.report_id, status, true)}
      {_id, _status, _equal?} -> {:error, :test_report_conflict}
      nil -> {:error, :not_found}
    end
  end

  defp row(project, api_key, payload, status) do
    report = payload["report"]

    %{
      id: Ecto.UUID.generate(),
      account_id: project.account_id,
      project_id: project.id,
      api_key_id: api_key && api_key.id,
      workflow_run_id: payload["workflow_run_id"],
      workflow: payload["workflow"],
      environment: payload["environment"],
      job: payload["job"],
      job_status: payload["job_status"],
      suite_id: report["suite_id"],
      report_id: report["report_id"],
      partition: report["partition"],
      partition_count: report["partition_count"],
      status: status,
      payload: payload,
      payload_digest: Document.digest(payload),
      inserted_at: DateTime.utc_now()
    }
  end

  defp ack(id, report_id, status, duplicate?),
    do: %{id: id, report_id: report_id, status: status, duplicate: duplicate?}

  defp persist(fun) do
    fun.()
  rescue
    DBConnection.ConnectionError ->
      {:error, :test_report_storage_unavailable}

    error in Postgrex.Error ->
      sqlstate = sqlstate(error)

      cond do
        sqlstate == "23503" -> foreign_key_error(error)
        transient?(sqlstate) -> {:error, :test_report_storage_unavailable}
        true -> unexpected(error, sqlstate, __STACKTRACE__)
      end
  end

  # Only the project foreign key means the path's project is gone (404).
  # Any other reference vanishing between authentication and insert (the
  # submitting API key or the account) is transient for this request: a
  # retry re-runs authentication, which then fails cleanly.
  defp foreign_key_error(%Postgrex.Error{postgres: %{constraint: @project_fkey}}),
    do: {:error, :not_found}

  defp foreign_key_error(%Postgrex.Error{}), do: {:error, :test_report_storage_unavailable}

  defp transient?(sqlstate) when is_binary(sqlstate),
    do: String.starts_with?(sqlstate, @transient_classes) or sqlstate in @transient_codes

  defp transient?(nil), do: false

  # The Postgrex message and detail can quote submitted values: keep only
  # the SQLSTATE and constraint name.
  defp unexpected(error, sqlstate, stacktrace) do
    constraint = constraint(error)

    Logger.error(
      "Test report storage failed: SQLSTATE #{sqlstate || "unknown"}, " <>
        "constraint #{constraint || "none"}"
    )

    reraise StorageError, [sqlstate: sqlstate, constraint: constraint], stacktrace
  end

  defp sqlstate(%Postgrex.Error{postgres: %{pg_code: code}}) when is_binary(code), do: code
  defp sqlstate(%Postgrex.Error{}), do: nil

  defp constraint(%Postgrex.Error{postgres: %{constraint: name}}) when is_binary(name), do: name
  defp constraint(%Postgrex.Error{}), do: nil
end
