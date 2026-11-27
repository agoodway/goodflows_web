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

  Report contents are read only inside Postgres: `failed_tests/3` computes
  a run's failed tests, and `get_report/4` and `report_tests/2` read one
  report's summary records, groups and a page of its tests. There is no update, delete or retention API,
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

  @groups_limit 200

  @report_details_sql """
  SELECT
    tr.payload->'source',
    tr.payload->'report'->'truncated',
    tr.payload->'report'->'records'->0,
    jsonb_path_query_first(tr.payload->'report'->'records', '$[*] ? (@.event == "suite_finished")'),
    jsonb_path_exists(tr.payload->'report'->'records', '$[*] ? (@.event == "interrupted")'),
    jsonb_path_exists(tr.payload->'report'->'records', '$[*] ? (@.event == "max_failures_reached")'),
    g.groups,
    g.total
  FROM test_reports tr
  CROSS JOIN LATERAL (
    SELECT
      coalesce(jsonb_agg(
        jsonb_build_object(
          'group', s.r->'group', 'file', s.r->'file', 'outcome', s.r->'outcome',
          'counts', s.r->'counts', 'duration_us', s.r->'duration_us'
        ) ORDER BY s.failing DESC, s.i
      ) FILTER (WHERE s.n <= $5), '[]') AS groups,
      count(*) AS total
    FROM (
      SELECT rec.r, rec.i, rec.r->>'outcome' IN ('failed', 'errored') AS failing,
        row_number() OVER (ORDER BY rec.r->>'outcome' IN ('failed', 'errored') DESC, rec.i) AS n
      FROM jsonb_array_elements(tr.payload->'report'->'records') WITH ORDINALITY AS rec(r, i)
      WHERE rec.r->>'event' = 'group_finished'
    ) s
  ) g
  WHERE tr.id = $1 AND tr.account_id = $2 AND tr.project_id = $3 AND tr.workflow_run_id = $4
  """

  @doc """
  One test report of the run `run_id` in `project`, by its server `id`,
  for the report page. Report contents are read inside Postgres: only the
  envelope's `source` and `truncated`, the `suite_started` and
  `suite_finished` records, whether `interrupted` or `max_failures_reached`
  was recorded, and the first #{@groups_limit} finished groups (failed and
  errored first, then in record order) reach the application.

  Returns `{:ok, details}` with `report` (summary fields plus `workflow`,
  `environment` and `inserted_at`), `source`, `truncated`, `suite_started`
  and `suite_finished` (nil when missing), `interrupted`,
  `max_failures_reached`, `groups` and `groups_total`. A `run_id` or `id`
  that is not a lowercase canonical UUID, or a report of another run,
  project or account, is `{:error, :not_found}`.
  """
  @spec get_report(Account.t(), Project.t(), term(), term()) ::
          {:ok, map()} | {:error, :not_found}
  def get_report(
        %Account{id: account_id},
        %Project{account_id: account_id, id: project_id},
        run_id,
        id
      ) do
    with true <- canonical_uuid?(run_id) and canonical_uuid?(id),
         %Report{} = report <- fetch_report(account_id, project_id, run_id, id) do
      {:ok, Map.put(report_details(account_id, project_id, run_id, id), :report, report)}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_report(%Account{}, %Project{}, _run_id, _id), do: {:error, :not_found}

  defp canonical_uuid?(value), do: GoodFlows.WorkflowRuns.Validator.canonical_uuid?(value)

  defp fetch_report(account_id, project_id, run_id, id) do
    Report
    |> where(account_id: ^account_id, project_id: ^project_id, workflow_run_id: ^run_id, id: ^id)
    |> select(
      [r],
      struct(
        r,
        ^(Report.summary_fields() ++
            [:account_id, :project_id, :workflow, :environment, :inserted_at])
      )
    )
    |> Repo.one()
  end

  defp report_details(account_id, project_id, run_id, id) do
    %{rows: [[source, truncated, first, finished, interrupted, max_failures, groups, total]]} =
      Repo.query!(
        @report_details_sql,
        [
          Ecto.UUID.dump!(id),
          Ecto.UUID.dump!(account_id),
          Ecto.UUID.dump!(project_id),
          Ecto.UUID.dump!(run_id),
          @groups_limit
        ],
        log: false,
        timeout: db_timeout_ms()
      )

    %{
      source: source || %{},
      truncated: truncated == true,
      suite_started: if(first["event"] == "suite_started", do: first),
      suite_finished: finished,
      interrupted: interrupted,
      max_failures_reached: max_failures,
      groups:
        Enum.map(groups, fn g ->
          %{
            group: g["group"],
            file: g["file"],
            outcome: g["outcome"],
            counts: g["counts"] || %{},
            duration_us: g["duration_us"]
          }
        end),
      groups_total: total
    }
  end

  @test_filters ~w(all failed passed skipped retried)
  @test_sorts ~w(order slowest)
  @tests_page_size 100

  @doc "The `report_tests/2` outcome filters: final outcome, or `retried`."
  @spec test_filters() :: [String.t()]
  def test_filters, do: @test_filters

  @doc "The `report_tests/2` sort orders."
  @spec test_sorts() :: [String.t()]
  def test_sorts, do: @test_sorts

  @doc "Tests per `report_tests/2` page."
  @spec tests_page_size() :: pos_integer()
  def tests_page_size, do: @tests_page_size

  @report_tests_sql """
  WITH finished AS (
    SELECT rec.r, rec.i
    FROM test_reports tr
    CROSS JOIN LATERAL jsonb_array_elements(tr.payload->'report'->'records')
      WITH ORDINALITY AS rec(r, i)
    WHERE tr.id = $1 AND tr.account_id = $2 AND tr.project_id = $3
      AND rec.r->>'event' = 'test_finished'
  ),
  tests AS (
    SELECT min(i) AS first_i,
      (array_agg(r ORDER BY i DESC))[1] AS final,
      jsonb_agg(
        jsonb_build_object(
          'outcome', r->'outcome', 'duration_us', r->'duration_us',
          'meta', coalesce(r->'meta', '{}'::jsonb)
        ) ORDER BY i
      ) AS attempts,
      bool_or(r->>'outcome' IN ('failed', 'errored')) AS ever_failed
    FROM finished
    GROUP BY r->>'group', r->'path', r->>'name'
  ),
  searched AS (
    SELECT first_i, final, attempts,
      CASE WHEN final->>'outcome' IN ('failed', 'errored') THEN 'failed'
        WHEN final->>'outcome' = 'passed' THEN 'passed'
        ELSE 'skipped' END AS kind,
      final->>'outcome' = 'passed' AND ever_failed AS retried
    FROM tests
    WHERE $4 = '' OR strpos(lower(concat_ws(' › ',
      final->>'group',
      (SELECT string_agg(p, ' › ') FROM jsonb_array_elements_text(final->'path') AS p),
      final->>'name')), lower($4)) > 0
  ),
  matching AS (
    SELECT * FROM searched
    WHERE $5 = 'all' OR kind = $5 OR ($5 = 'retried' AND retried)
  ),
  page AS (
    SELECT *, row_number() OVER (
      ORDER BY CASE WHEN $6 = 'slowest' THEN coalesce((final->>'duration_us')::bigint, -1) END
        DESC NULLS LAST, first_i
    ) AS n
    FROM matching
    ORDER BY n
    LIMIT $7 OFFSET $8
  )
  SELECT
    (SELECT jsonb_build_object(
      'all', count(*),
      'failed', count(*) FILTER (WHERE kind = 'failed'),
      'passed', count(*) FILTER (WHERE kind = 'passed'),
      'skipped', count(*) FILTER (WHERE kind = 'skipped'),
      'retried', count(*) FILTER (WHERE retried)
    ) FROM searched),
    (SELECT count(*) FROM matching),
    (SELECT coalesce(jsonb_agg(
      jsonb_build_object(
        'group', final->'group', 'path', final->'path', 'name', final->'name',
        'file', final->'file', 'line', final->'line', 'duration_us', final->'duration_us',
        'outcome', final->'outcome', 'retried', retried, 'attempts', attempts
      ) ORDER BY n
    ), '[]') FROM page)
  """

  @doc """
  One page of the tests of `report` (from `get_report/4`), computed inside
  Postgres. A test is one `group`, `path` and `name`; its row is its final
  execution (the last `test_finished`), with every execution's outcome,
  duration and `meta` in `attempts`. Tests whose `test_finished` never
  arrived are not listed.

  Options:

    * `:outcome` – `"all"` (default), `"failed"` (final outcome failed or
      errored), `"passed"`, `"skipped"` or `"retried"` (final execution
      passed after an earlier one failed or errored)
    * `:search` – keeps tests whose `group › path › name` contains it,
      ignoring case
    * `:sort` – `"order"` (default, by first execution) or `"slowest"`
      (final duration, longest first)
    * `:page` – 1-based, #{@tests_page_size} tests per page

  Returns `tests`, `total` (tests matching the filter and search) and
  `counts` (tests matching the search, per filter).
  """
  @spec report_tests(Report.t(), keyword()) :: %{
          tests: [map()],
          total: non_neg_integer(),
          counts: %{String.t() => non_neg_integer()}
        }
  def report_tests(%Report{id: id, account_id: account_id, project_id: project_id}, opts) do
    outcome = Keyword.get(opts, :outcome, "all")
    sort = Keyword.get(opts, :sort, "order")
    page = Keyword.get(opts, :page, 1)

    %{rows: [[counts, total, tests]]} =
      Repo.query!(
        @report_tests_sql,
        [
          Ecto.UUID.dump!(id),
          Ecto.UUID.dump!(account_id),
          Ecto.UUID.dump!(project_id),
          Keyword.get(opts, :search, ""),
          if(outcome in @test_filters, do: outcome, else: "all"),
          if(sort in @test_sorts, do: sort, else: "order"),
          @tests_page_size,
          (max(page, 1) - 1) * @tests_page_size
        ],
        log: false,
        timeout: db_timeout_ms()
      )

    %{
      counts: counts,
      total: total,
      tests:
        Enum.map(tests, fn test ->
          test
          |> test_fields()
          |> Map.merge(%{
            retried: test["retried"],
            attempts:
              Enum.map(test["attempts"], fn a ->
                %{outcome: a["outcome"], duration_us: a["duration_us"], meta: a["meta"]}
              end)
          })
        end)
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
