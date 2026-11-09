defmodule GoodFlows.WorkflowRuns do
  @moduledoc """
  Storage-only ingestion of goodflows run-history documents.

  `ingest/4` validates one `schema_version` 1 document
  (`GoodFlows.WorkflowRuns.Validator`) and stores it immutably under the
  authenticated account and the project from the request path. The project
  slug never enters the stored document.

  Idempotency: the identity `(account, project, run_id)` names one
  immutable document. The first insert is acknowledged as new. A retry
  whose validated body is the same JSON value (object key order ignored;
  arrays compared in order; strings compared exactly; numbers, which
  validation limits to integers, compared by value) is acknowledged as a
  duplicate with the same server id. Any other body under that identity is
  a conflict and changes nothing. Concurrent requests follow the same rules
  through `INSERT … ON CONFLICT DO NOTHING`. Each row stores
  `payload_digest`, the SHA-256 of the payload's canonical JSON
  (`GoodFlows.JsonDocument.digest/1`: keys sorted, no whitespace), so a
  retry that loses the insert is compared by digest in SQL. The comparison
  is filtered by `(account_id, project_id, run_id)`: scoping only to the
  account and project would make `Repo.one/2` raise once a second run
  exists.

  A connection failure, timeout or other transient database error while
  storing returns `{:error, :workflow_run_storage_unavailable}`. The commit
  outcome is then unknown: the row may exist. Publishers retry the same
  frozen body, which resolves through the rules above. Any other database
  error is logged by SQLSTATE and constraint name only and raised as
  `GoodFlows.WorkflowRuns.StorageError` (a 500), never with its message.

  Insert and comparison queries run with `log: false` so the document never
  reaches Ecto logs, and with the timeout
  `config :good_flows, :workflow_run_db_timeout_ms` (default 15_000).
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.JsonDocument
  alias GoodFlows.Projects.Project
  alias GoodFlows.StorageErrors
  alias GoodFlows.WorkflowRuns.{Run, StorageError, Store, Validator}

  @identity [:account_id, :project_id, :run_id]

  @default_db_timeout_ms 15_000

  @project_fkey "workflow_runs_project_id_fkey"

  @typedoc "Storage acknowledgement returned to the publisher."
  @type ack :: %{id: Ecto.UUID.t(), run_id: Ecto.UUID.t(), duplicate: boolean()}

  @typedoc "Reasons `ingest/4` can fail."
  @type error ::
          {:invalid_workflow_run, Validator.errors()}
          | :not_found
          | :workflow_run_conflict
          | :workflow_run_storage_unavailable

  @doc """
  Validates and stores `document` (decoded JSON, see
  `GoodFlows.JsonDocument.decode/1`) for `project` of `account`.

  Returns `{:ok, ack}` where `ack.duplicate` tells an exact retry from a
  first insert, or `{:error, reason}`:

    * `{:invalid_workflow_run, errors}` – the document breaks the contract;
      nothing is stored
    * `:not_found` – the project is not the account's, or it was deleted
      before the insert; nothing is stored
    * `:workflow_run_conflict` – the identity holds a different document
    * `:workflow_run_storage_unavailable` – the database could not be
      reached, timed out or failed transiently, or a referenced row other
      than the project (the submitting API key or the account) disappeared
      before the insert; a retry re-authenticates
  """
  @spec ingest(Account.t(), Project.t(), ApiKey.t() | nil, term()) ::
          {:ok, ack()} | {:error, error()}
  def ingest(%Account{id: account_id}, %Project{account_id: account_id} = project, api_key, doc) do
    case Validator.validate(doc) do
      {:ok, payload, columns} -> persist(fn -> store(project, api_key, payload, columns) end)
      {:error, {:invalid, errors}} -> {:error, {:invalid_workflow_run, errors}}
    end
  end

  def ingest(%Account{}, %Project{}, _api_key, _document), do: {:error, :not_found}

  @doc "The timeout for the insert and comparison queries, in milliseconds."
  @spec db_timeout_ms() :: pos_integer()
  def db_timeout_ms,
    do: Application.get_env(:good_flows, :workflow_run_db_timeout_ms, @default_db_timeout_ms)

  defp store(project, api_key, payload, columns) do
    row = row(project, api_key, payload, columns)

    case Store.insert_all(Run, [row],
           on_conflict: :nothing,
           conflict_target: @identity,
           returning: [:id],
           log: false,
           timeout: db_timeout_ms()
         ) do
      {1, [%Run{id: id}]} -> {:ok, ack(id, row.run_id, false)}
      {0, []} -> compare(row)
    end
  end

  # Only the digest is sent: the payload went once with the insert.
  # `run_id` is part of the filter so a later run in the same project does
  # not make `Repo.one/2` raise.
  defp compare(row) do
    query =
      from r in Run,
        where:
          r.account_id == ^row.account_id and r.project_id == ^row.project_id and
            r.run_id == ^row.run_id,
        select: {r.id, r.payload_digest == ^row.payload_digest}

    case Store.one(query, log: false, timeout: db_timeout_ms()) do
      {id, true} -> {:ok, ack(id, row.run_id, true)}
      {_id, false} -> {:error, :workflow_run_conflict}
      nil -> {:error, :not_found}
    end
  end

  defp row(project, api_key, payload, columns) do
    %{
      id: Ecto.UUID.generate(),
      account_id: project.account_id,
      project_id: project.id,
      api_key_id: api_key && api_key.id,
      run_id: columns.run_id,
      workflow: columns.workflow,
      environment: columns.environment,
      outcome: columns.outcome,
      started_at: columns.started_at,
      duration_ms: columns.duration_ms,
      parallelism: columns.parallelism,
      max_in_flight: columns.max_in_flight,
      graph_sha256: columns.graph_sha256,
      source_commit: columns.source_commit,
      source_dirty: columns.source_dirty,
      host: columns.host,
      payload: payload,
      payload_digest: JsonDocument.digest(payload),
      inserted_at: DateTime.utc_now()
    }
  end

  defp ack(id, run_id, duplicate?), do: %{id: id, run_id: run_id, duplicate: duplicate?}

  defp persist(fun) do
    StorageErrors.persist(fun,
      unavailable: :workflow_run_storage_unavailable,
      project_fkey: @project_fkey,
      storage_error: StorageError,
      label: "Workflow run storage failed"
    )
  end
end
