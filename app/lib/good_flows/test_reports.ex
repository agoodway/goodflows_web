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

  `failed_tests/3` is the only read of report contents: it computes a run's
  failed tests inside Postgres. There is no update, delete or retention API,
  no aggregation across partitions and no link to Spry runs. Insert and comparison queries run
  with `log: false` so the document never reaches Ecto logs, and with the
  timeout `config :good_flows, :test_report_db_timeout_ms` (default 15,000).
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.StorageErrors
  alias GoodFlows.TestReports.{Document, Report, StorageError, Store, Validator}

  @identity [:account_id, :project_id, :workflow_run_id, :job, :report_id]

  @default_db_timeout_ms 15_000

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

  @doc """
  The failed tests of each test report of the run `run_id` in `project`
  (design D5), computed inside Postgres: report records never reach the
  application.

  For each report, ordered by `job` then `report_id`, it returns the report
  summary (`GoodFlows.TestReports.Report.summary_fields/0`) and:

    * `failed`: the first 200 tests, by record order, whose final
      execution (the last `test_finished` of the same `group`, `path` and
      `name`) is `failed` or `errored`
    * `failed_total`: how many such tests the report has
    * `retried`: the first 200 tests, by record order, whose final
      execution passed after an earlier one failed or errored
    * `retried_total`: how many such tests the report has

  Each test is a map of `group`, `path`, `name`, `file`, `line`,
  `duration_us` and `outcome`. A `run_id` that is not a lowercase canonical
  UUID, or a project of another account, has no reports. The query runs
  with `log: false` and `db_timeout_ms/0`.
  """
  @spec failed_tests(Account.t(), Project.t(), term()) :: [
          %{
            report: Report.t(),
            failed: [map()],
            failed_total: non_neg_integer(),
            retried: [map()],
            retried_total: non_neg_integer()
          }
        ]
  def failed_tests(
        %Account{id: account_id},
        %Project{account_id: account_id, id: project_id},
        run_id
      ) do
    if GoodFlows.WorkflowRuns.Validator.canonical_uuid?(run_id) do
      tests = failed_test_rows(account_id, project_id, run_id)

      account_id
      |> report_summaries(project_id, run_id)
      |> Enum.map(&report_failures(&1, Map.get(tests, &1.id, [])))
    else
      []
    end
  end

  def failed_tests(%Account{}, %Project{}, _run_id), do: []

  @failed_limit 200

  @failed_tests_sql """
  WITH finished AS (
    SELECT tr.id AS report_id, rec.r, rec.i
    FROM test_reports tr
    CROSS JOIN LATERAL jsonb_array_elements(tr.payload->'report'->'records')
      WITH ORDINALITY AS rec(r, i)
    WHERE tr.account_id = $1 AND tr.project_id = $2 AND tr.workflow_run_id = $3
      AND rec.r->>'event' = 'test_finished'
  ),
  executions AS (
    SELECT report_id, r, i,
      row_number() OVER test_key_desc AS latest,
      bool_or(r->>'outcome' IN ('failed', 'errored')) OVER test_key AS ever_failed
    FROM finished
    WINDOW test_key AS (PARTITION BY report_id, r->>'group', r->'path', r->>'name'),
      test_key_desc AS (PARTITION BY report_id, r->>'group', r->'path', r->>'name' ORDER BY i DESC)
  ),
  final AS (
    SELECT report_id, r, i, ever_failed FROM executions WHERE latest = 1
  ),
  classified AS (
    SELECT report_id, r, i,
      CASE WHEN r->>'outcome' IN ('failed', 'errored') THEN 'failed' ELSE 'retried' END AS kind
    FROM final
    WHERE r->>'outcome' IN ('failed', 'errored') OR (r->>'outcome' = 'passed' AND ever_failed)
  ),
  numbered AS (
    SELECT report_id, kind, r, i,
      row_number() OVER (PARTITION BY report_id, kind ORDER BY i) AS n,
      count(*) OVER (PARTITION BY report_id, kind) AS total
    FROM classified
  ),
  shown AS (
    SELECT report_id, kind, r, i, total FROM numbered WHERE n <= $4
  )
  SELECT report_id::text, kind,
    jsonb_build_object(
      'group', r->'group', 'path', r->'path', 'name', r->'name', 'file', r->'file',
      'line', r->'line', 'duration_us', r->'duration_us', 'outcome', r->'outcome'
    ),
    total
  FROM shown
  ORDER BY report_id, kind, i
  """

  defp failed_test_rows(account_id, project_id, run_id) do
    %{rows: rows} =
      Repo.query!(
        @failed_tests_sql,
        [
          Ecto.UUID.dump!(account_id),
          Ecto.UUID.dump!(project_id),
          Ecto.UUID.dump!(run_id),
          @failed_limit
        ],
        log: false,
        timeout: db_timeout_ms()
      )

    Enum.group_by(rows, &hd/1, fn [_report_id, kind, test, total] ->
      {kind, test_fields(test), total}
    end)
  end

  defp report_failures(report, rows) do
    %{
      report: report,
      failed: for({"failed", test, _total} <- rows, do: test),
      failed_total: total(rows, "failed"),
      retried: for({"retried", test, _total} <- rows, do: test),
      retried_total: total(rows, "retried")
    }
  end

  defp total(rows, kind),
    do: Enum.find_value(rows, 0, fn {row_kind, _test, total} -> row_kind == kind && total end)

  defp test_fields(test) do
    %{
      group: test["group"],
      path: test["path"] || [],
      name: test["name"],
      file: test["file"],
      line: test["line"],
      duration_us: test["duration_us"],
      outcome: test["outcome"]
    }
  end

  @doc """
  The summaries of the test reports whose `workflow_run_id` is `run_id` in
  the account's project, ordered by `job` then `report_id`, without report
  contents. Shared by `failed_tests/3` and
  `GoodFlows.WorkflowRuns.get_run/3`.
  """
  @spec report_summaries(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: [Report.t()]
  def report_summaries(account_id, project_id, run_id) do
    Report
    |> where(account_id: ^account_id, project_id: ^project_id, workflow_run_id: ^run_id)
    |> order_by([r], asc: r.job, asc: r.report_id)
    |> select([r], struct(r, ^Report.summary_fields()))
    |> Repo.all()
  end

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
    StorageErrors.persist(fun,
      unavailable: :test_report_storage_unavailable,
      project_fkey: @project_fkey,
      storage_error: StorageError,
      label: "Test report storage failed"
    )
  end
end
