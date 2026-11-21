defmodule GoodFlows.WorkflowRuns do
  @moduledoc """
  Storage-only ingestion of goodflows run-history documents.

  `ingest/4` validates one `schema_version` 1 document
  (`GoodFlows.WorkflowRuns.Validator`) and stores it immutably under the
  authenticated account and the project from the request path. The project
  slug never enters the stored document. `list_runs/3` pages those rows
  newest first. `get_run/3` returns one document plus the test-report
  summaries that share its `run_id` in the same account and project.

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

  A first insert whose `source.commit` is the head of a `draft` or `open`
  change request of the project recomputes that verdict in the same
  transaction (`GoodFlows.ChangeRequests.recompute_for_commit/2`).

  Insert and comparison queries run with `log: false` so the document never
  reaches Ecto logs, and with the timeout
  `config :good_flows, :workflow_run_db_timeout_ms` (default 15_000).
  """
  import Ecto.Query

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.ChangeRequests
  alias GoodFlows.JsonDocument
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.StorageErrors
  alias GoodFlows.TestReports.Report
  alias GoodFlows.WorkflowRuns.{Run, StorageError, Store, Validator}

  @identity [:account_id, :project_id, :run_id]

  @default_db_timeout_ms 15_000
  @default_page_size 50
  @max_page_size 200

  @summary_fields [
    :id,
    :run_id,
    :workflow,
    :environment,
    :outcome,
    :started_at,
    :duration_ms,
    :parallelism,
    :max_in_flight,
    :graph_sha256,
    :source_commit,
    :source_dirty,
    :source_branch,
    :ci,
    :host,
    :inserted_at
  ]

  @cursor_time ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/

  @project_fkey "workflow_runs_project_id_fkey"

  @typedoc "One page of run summaries. `next_cursor` is nil on the last page."
  @type run_page :: %{runs: [Run.t()], next_cursor: String.t() | nil}

  @typedoc "A stored run plus the test-report summaries linked by `run_id`."
  @type shown_run :: %{run: Run.t(), test_reports: [Report.t()]}

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

  @doc """
  One page of `project`'s runs, newest `started_at` first, ties broken by
  `run_id` descending.

  Params (string keys, as from a query string): `"limit"` (1 to
  #{@max_page_size}, default #{@default_page_size}), `"cursor"` (the
  previous page's `next_cursor`) and the exact-match filters `"workflow"`,
  `"environment"`, `"outcome"`, `"commit"` (`source.commit`), `"branch"`
  (`source.branch`), `"event"` (`ci.event`) and `"graph_sha256"`, and the
  link filters `"ticket"` and `"thread_url"`. Unknown keys are ignored. A
  filter, limit or cursor that breaks its rule returns a changeset (`422`).

  `"ticket"` follows the ticket rule and matches any of a run's
  `links.tickets` ignoring ASCII case. `"thread_url"` is normalized first
  (lowercase scheme and host, no empty or 443 port, `/` for an empty path,
  percent triplets as sent), must then be a valid thread URL, and matches
  one of a run's `links.threads` exactly. Both use the GIN-indexed
  `link_tickets` and `link_threads` columns, which are never selected.

  Only the copied columns are selected, never `payload`. `source` is
  rebuilt by the JSON view from `source_commit`, `source_dirty` and
  `source_branch`.
  """
  @spec list_runs(Account.t(), Project.t(), map()) ::
          {:ok, run_page()} | {:error, :not_found | Ecto.Changeset.t()}
  def list_runs(
        %Account{id: account_id},
        %Project{account_id: account_id, id: project_id},
        params
      )
      when is_map(params) do
    with {:ok, filters} <- list_params(params) do
      runs =
        Run
        |> where(account_id: ^account_id, project_id: ^project_id)
        |> apply_filters(filters)
        |> after_cursor(filters.cursor)
        |> order_by([r], desc: r.started_at, desc: r.run_id)
        |> limit(^(filters.limit + 1))
        |> select([r], struct(r, ^@summary_fields))
        |> Repo.all()

      {page, rest} = Enum.split(runs, filters.limit)
      next_cursor = if rest != [], do: encode_cursor(List.last(page))
      {:ok, %{runs: page, next_cursor: next_cursor}}
    end
  end

  def list_runs(%Account{}, %Project{}, _params), do: {:error, :not_found}

  @doc """
  Loads one run and its test-report summaries.

  `run_id` must already be a lowercase canonical UUID. Any other spelling,
  including uppercase, is `:not_found` and is not looked up. Summaries are
  the reports in the same account and project whose `workflow_run_id`
  equals `run_id`, ordered by `job` then `report_id`, without report
  contents.
  """
  @spec get_run(Account.t(), Project.t(), term()) ::
          {:ok, shown_run()} | {:error, :not_found}
  def get_run(%Account{id: account_id}, %Project{account_id: account_id, id: project_id}, run_id) do
    if Validator.canonical_uuid?(run_id) do
      fetch_run(account_id, project_id, run_id)
    else
      {:error, :not_found}
    end
  end

  def get_run(%Account{}, %Project{}, _run_id), do: {:error, :not_found}

  defp fetch_run(account_id, project_id, run_id) do
    query =
      from r in Run,
        where: r.account_id == ^account_id and r.project_id == ^project_id and r.run_id == ^run_id

    case Repo.one(query, log: false) do
      nil ->
        {:error, :not_found}

      run ->
        {:ok, %{run: run, test_reports: report_summaries(account_id, project_id, run_id)}}
    end
  end

  defp report_summaries(account_id, project_id, run_id) do
    Report
    |> where(account_id: ^account_id, project_id: ^project_id, workflow_run_id: ^run_id)
    |> order_by([r], asc: r.job, asc: r.report_id)
    |> select([r], struct(r, ^Report.summary_fields()))
    |> Repo.all()
  end

  defp list_params(params) do
    types = %{
      limit: :integer,
      cursor: :string,
      workflow: :string,
      environment: :string,
      outcome: :string,
      commit: :string,
      branch: :string,
      event: :string,
      graph_sha256: :string,
      ticket: :string,
      thread_url: :string
    }

    defaults = %{
      limit: @default_page_size,
      cursor: nil,
      workflow: nil,
      environment: nil,
      outcome: nil,
      commit: nil,
      branch: nil,
      event: nil,
      graph_sha256: nil,
      ticket: nil,
      thread_url: nil
    }

    # `empty_values: []` keeps a whitespace-only filter. Ecto's default
    # treats it as missing, and a blank environment or workflow must be
    # `422`, not an unfiltered list.
    {defaults, types}
    |> Ecto.Changeset.cast(params, Map.keys(types), empty_values: [])
    |> Ecto.Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_page_size
    )
    |> GoodFlows.KeysetCursor.put_cursor(&decode_cursor/1)
    |> validate_filter(:workflow, &Validator.valid_name?/1)
    |> validate_filter(:environment, &Validator.valid_name?/1)
    |> validate_filter(:outcome, &Validator.valid_outcome?/1)
    |> validate_filter(:commit, &Validator.valid_commit?/1)
    |> validate_filter(:branch, &Validator.valid_branch?/1)
    |> validate_filter(:event, &Validator.valid_name?/1)
    |> validate_filter(:graph_sha256, &Validator.valid_graph_sha256?/1)
    |> validate_filter(:ticket, &Validator.valid_ticket?/1)
    |> rewrite_filter(:ticket, &String.downcase(&1, :ascii))
    |> rewrite_filter(:thread_url, &normalize_thread_url/1)
    |> validate_filter(:thread_url, &Validator.valid_thread_url?/1)
    |> Ecto.Changeset.apply_action(:list)
  end

  defp rewrite_filter(changeset, field, fun) do
    case Ecto.Changeset.get_change(changeset, field) do
      nil -> changeset
      value -> Ecto.Changeset.put_change(changeset, field, fun.(value))
    end
  end

  # Design D3: lowercase the scheme and host, drop a port that is empty or
  # 443 (`:`, `:443`, `:0443`) and turn an empty path into `/`. Nothing
  # else changes: percent triplets, dot segments, IP spellings and other
  # port spellings (`:080`) stay as sent, so the result must still pass
  # `Validator.valid_thread_url?/1`. `URI.to_string/1` is not used because
  # it would also unpad `:080`.
  defp normalize_thread_url(value) do
    case String.split(value, "://", parts: 2) do
      [scheme, rest] ->
        {authority, tail} = split_authority(rest)
        String.downcase(scheme, :ascii) <> "://" <> drop_https_port(authority) <> root(tail)

      [_no_authority] ->
        value
    end
  end

  defp split_authority(rest) do
    case :binary.match(rest, ["/", "?", "#"]) do
      {at, _length} -> :erlang.split_binary(rest, at)
      :nomatch -> {rest, ""}
    end
  end

  # A bracketed IPv6 host ends in `]`, so only a trailing `:digits` is a port.
  defp drop_https_port(authority) do
    authority = String.downcase(authority, :ascii)

    case Regex.run(~r/\A(.*):([0-9]*)\z/s, authority) do
      [_all, host, port] -> if https_port?(port), do: host, else: authority
      nil -> authority
    end
  end

  defp https_port?(""), do: true
  defp https_port?(port), do: String.trim_leading(port, "0") == "443"

  defp root("/" <> _path = tail), do: tail
  defp root(tail), do: "/" <> tail

  defp validate_filter(changeset, field, valid?) do
    case Ecto.Changeset.get_change(changeset, field) do
      nil -> changeset
      value -> filter_error(changeset, field, value, valid?)
    end
  end

  defp filter_error(changeset, field, value, valid?) do
    if valid?.(value),
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, field, "is invalid")
  end

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [timestamp, run_id] <- split_cursor(decoded),
         true <- Validator.canonical_uuid?(run_id),
         {:ok, started_at} <- cursor_time(timestamp) do
      {:ok, {started_at, run_id}}
    else
      _ -> :error
    end
  end

  defp split_cursor(decoded) do
    case String.split(decoded, "|", parts: 2) do
      [timestamp, run_id] -> [timestamp, run_id]
      _other -> :error
    end
  end

  defp cursor_time(timestamp) do
    if Regex.match?(@cursor_time, timestamp) do
      case DateTime.from_iso8601(timestamp) do
        {:ok, started_at, 0} -> {:ok, started_at}
        _other -> :error
      end
    else
      :error
    end
  end

  defp encode_cursor(%Run{started_at: started_at, run_id: run_id}) do
    Base.url_encode64("#{DateTime.to_iso8601(started_at)}|#{run_id}", padding: false)
  end

  defp apply_filters(query, filters) do
    query
    |> filter(:workflow, filters.workflow)
    |> filter(:environment, filters.environment)
    |> filter(:outcome, filters.outcome)
    |> filter(:graph_sha256, filters.graph_sha256)
    |> filter(:commit, filters.commit)
    |> filter(:branch, filters.branch)
    |> filter(:event, filters.event)
    |> filter(:ticket, filters.ticket)
    |> filter(:thread_url, filters.thread_url)
  end

  defp filter(query, _field, nil), do: query

  # `@>` on the GIN-indexed `text[]` columns. The cast is `text[]`: Ecto's
  # `{:array, :string}` would send `varchar[]`, which has no `@>` here.
  defp filter(query, :ticket, ticket),
    do: where(query, [r], fragment("? @> ?::text[]", r.link_tickets, ^[ticket]))

  defp filter(query, :thread_url, url),
    do: where(query, [r], fragment("? @> ?::text[]", r.link_threads, ^[url]))

  defp filter(query, :commit, commit), do: where(query, [r], r.source_commit == ^commit)
  defp filter(query, :branch, branch), do: where(query, [r], r.source_branch == ^branch)

  defp filter(query, :event, event),
    do: where(query, [r], fragment("?->>'event'", r.ci) == ^event)

  defp filter(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {started_at, run_id}) do
    where(
      query,
      [r],
      r.started_at < ^started_at or (r.started_at == ^started_at and r.run_id < ^run_id)
    )
  end

  # A new run on the head of a `draft` or `open` change request recomputes
  # its verdict in the insert's transaction.
  defp store(project, api_key, payload, columns) do
    row = row(project, api_key, payload, columns)

    {:ok, result} =
      Store.transaction(fn -> insert_or_compare(row) end, timeout: db_timeout_ms())

    result
  end

  defp insert_or_compare(row) do
    case Store.insert_all(Run, [row],
           on_conflict: :nothing,
           conflict_target: @identity,
           returning: [:id],
           log: false,
           timeout: db_timeout_ms()
         ) do
      {1, [%Run{id: id}]} ->
        ChangeRequests.recompute_for_commit(row.project_id, row.source_commit)
        {:ok, ack(id, row.run_id, false)}

      {0, []} ->
        compare(row)
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
      source_branch: columns.source_branch,
      ci: columns.ci,
      host: columns.host,
      link_tickets: columns.link_tickets,
      link_threads: columns.link_threads,
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
