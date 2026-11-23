defmodule GoodFlows.Calibration do
  @moduledoc """
  Review calibration (the `review-calibration` capability): defects found
  after change requests merged, and a read-only report of merges and
  defects by lane, policy version, rule and path glob, so admins can judge
  whether the review policy lets defects through. Nothing here creates a
  policy version, changes a setting or recomputes a verdict.

  `record_defect/3` stores a defect naming exactly one change request
  number or commit SHA. A commit is attributed, once, to the earliest
  `merged_at` merged change request whose `merged_commit` is that SHA or
  whose merged head's `git-facts` commits list it, or stored unattributed. The `defect_recorded` event is
  recorded in the same transaction, with the attributed change request's
  number (or nil). `list_defects/2` pages a project's defects newest
  first. `report/2` is computed on read for a `[from, to)` window of
  `merged_at`, counting every defect of those change requests whenever it
  was recorded, and lists those defects (at most 500, newest first) with
  their lane, policy version, rules and matched globs. Unattributed
  defects are only counted, by `recorded_at` in the window.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Calibration.Defect
  alias GoodFlows.ChangeRequests.{ChangeRequest, GitFacts, Params}
  alias GoodFlows.DocumentErrors
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.Review.Answer
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ReviewPolicies.{Document, Glob}
  alias GoodFlows.TestReports.Shape

  @default_page_size 50
  @max_page_size 200
  @max_ticket_chars 200
  @default_window_days 90
  @lanes ~w(auto reviewed bypass)
  @max_listed_defects 500

  @typedoc "One page of defects; `next_cursor` is nil on the last page."
  @type page :: %{defects: [Defect.t()], next_cursor: String.t() | nil}

  @doc "The report lanes."
  @spec lanes() :: [String.t()]
  def lanes, do: @lanes

  @doc """
  Stores a defect for `project` from a normalized body, recorded by
  `api_key` and its membership. Returns `{:ok, defect}` (with
  `change_request` preloaded) or `{:error, {:invalid_body, errors}}`.
  """
  @spec record_defect(Project.t(), ApiKey.t(), term()) ::
          {:ok, Defect.t()} | {:error, {:invalid_body, DocumentErrors.errors()}}
  def record_defect(%Project{} = project, %ApiKey{} = api_key, body) do
    with {:ok, attrs} <- validate(body),
         {:ok, change_request, attribution} <- attribute(project, attrs) do
      Repo.transaction(fn ->
        defect =
          Repo.insert!(%Defect{
            project_id: project.id,
            change_request_id: change_request && change_request.id,
            commit: attrs.commit,
            attribution: attribution,
            severity: attrs.severity,
            ticket: attrs.ticket,
            account_user_id: api_key.account_user_id,
            api_key_id: api_key.id,
            recorded_at: DateTime.utc_now()
          })

        ProjectEvents.record(
          project.id,
          change_request && change_request.number,
          "defect_recorded",
          %{
            "defect_id" => defect.id,
            "commit" => defect.commit,
            "attribution" => attribution,
            "severity" => defect.severity,
            "ticket" => defect.ticket
          },
          api_key
        )

        %{defect | change_request: change_request}
      end)
    end
  end

  defp validate(body) do
    spec =
      {:object,
       %{
         "change_request" => {:omit, {:int, 1}},
         "commit" => {:omit, Params.sha_spec()},
         "severity" => {:omit, {:enum, Defect.severities()}},
         "ticket" => {:omit, {:fun, &ticket_errors/2, :ticket}}
       }}

    case Shape.check(body, spec, []) do
      [] ->
        if Map.has_key?(body, "change_request") == Map.has_key?(body, "commit") do
          invalid(%{"body" => ["must have exactly one of change_request or commit"]})
        else
          {:ok,
           %{
             change_request: Map.get(body, "change_request"),
             commit: Map.get(body, "commit"),
             severity: Map.get(body, "severity"),
             ticket: Map.get(body, "ticket")
           }}
        end

      errors ->
        invalid(DocumentErrors.render(errors))
    end
  end

  defp ticket_errors(value, path) when is_binary(value) do
    if value != "" and String.length(value) <= @max_ticket_chars,
      do: [],
      else: [{path, "must be 1 to #{@max_ticket_chars} characters"}]
  end

  defp ticket_errors(_value, path), do: [{path, "must be a string"}]

  defp invalid(errors), do: {:error, {:invalid_body, errors}}

  defp attribute(project, %{change_request: number}) when is_integer(number) do
    case Repo.get_by(ChangeRequest, project_id: project.id, number: number) do
      nil -> invalid(%{"change_request" => ["must be a change request number of the project"]})
      change_request -> {:ok, change_request, "change_request"}
    end
  end

  defp attribute(project, %{commit: commit}) do
    query =
      from c in ChangeRequest,
        left_join: f in GitFacts,
        on: f.change_request_id == c.id and f.head == c.merged_head,
        where:
          c.project_id == ^project.id and c.state == "merged" and
            (c.merged_commit == ^commit or
               fragment(
                 "?->'commits' @> jsonb_build_array(jsonb_build_object('sha', ?::text))",
                 f.document,
                 ^commit
               )),
        order_by: [asc: c.merged_at, asc: c.number],
        limit: 1

    case Repo.one(query) do
      nil -> {:ok, nil, "unattributed"}
      change_request -> {:ok, change_request, "commit"}
    end
  end

  @doc """
  One page of `project`'s defects, newest `recorded_at` first, with the
  attributed change request preloaded. Params: `"limit"` (1 to
  #{@max_page_size}, default #{@default_page_size}) and `"cursor"`.
  """
  @spec list_defects(Project.t(), map()) :: {:ok, page()} | {:error, Ecto.Changeset.t()}
  def list_defects(%Project{id: project_id}, params) do
    with {:ok, %{limit: limit, cursor: cursor}} <- page_params(params) do
      defects =
        Defect
        |> where(project_id: ^project_id)
        |> after_cursor(cursor)
        |> order_by(desc: :recorded_at, desc: :id)
        |> limit(^(limit + 1))
        |> preload(:change_request)
        |> Repo.all()

      {page, rest} = Enum.split(defects, limit)
      next = if rest != [], do: encode_cursor(List.last(page))
      {:ok, %{defects: page, next_cursor: next}}
    end
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {recorded_at, id}) do
    where(
      query,
      [d],
      d.recorded_at < ^recorded_at or (d.recorded_at == ^recorded_at and d.id < ^id)
    )
  end

  defp page_params(params) do
    {%{limit: @default_page_size, cursor: nil}, %{limit: :integer, cursor: :string}}
    |> Ecto.Changeset.cast(params, [:limit, :cursor], empty_values: [])
    |> Ecto.Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_page_size
    )
    |> GoodFlows.KeysetCursor.put_cursor(&decode_cursor/1)
    |> Ecto.Changeset.apply_action(:list)
  end

  defp encode_cursor(%Defect{recorded_at: recorded_at, id: id}),
    do: Base.url_encode64("v1:#{DateTime.to_iso8601(recorded_at)}|#{id}", padding: false)

  defp decode_cursor(cursor) do
    with {:ok, "v1:" <> rest} <- Base.url_decode64(cursor, padding: false),
         [time, id] <- String.split(rest, "|"),
         {:ok, recorded_at, 0} <- DateTime.from_iso8601(time),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {recorded_at, id}}
    else
      _other -> :error
    end
  end

  @doc """
  The calibration report of `project`. Params: optional ISO 8601 `"from"`
  and `"to"` (default `to` now and `from` #{@default_window_days} days
  before it); `from` not before `to` is a changeset error on `from`.
  """
  @spec report(Project.t(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def report(%Project{} = project, params) do
    with {:ok, window} <- window_params(params) do
      merged = merged_in(project.id, window)
      defects = defects_of(merged)
      answered = answered(merged)
      lanes = Map.new(merged, &{&1.id, lane(&1, answered)})
      counts = Map.new(merged, &{&1.id, length(Map.get(defects, &1.id, []))})

      {globs, unmatched, matched} = glob_stats(project, merged, defects)
      {listed, truncated?} = defect_entries(merged, defects, lanes, matched)

      {:ok,
       %{
         from: window.from,
         to: window.to,
         lanes: lane_stats(merged, lanes, counts),
         policy_versions: policy_version_stats(merged, lanes, counts),
         rules: rule_stats(merged, counts),
         gaps: gaps(merged, counts),
         globs: globs,
         unmatched_defect_count: unmatched,
         defects: listed,
         defects_truncated: truncated?,
         unattributed_defect_count: unattributed_count(project.id, window)
       }}
    end
  end

  # Every defect of the merged change requests with its change request's
  # lane, policy version and rules and the globs its files matched, newest
  # `recorded_at` (then `id`) first, cut at #{@max_listed_defects}.
  defp defect_entries(merged, defects, lanes, matched) do
    by_id = Map.new(merged, &{&1.id, &1})

    entries =
      for {change_request_id, list} <- defects, defect <- list do
        change_request = Map.fetch!(by_id, change_request_id)

        %{
          id: defect.id,
          change_request: change_request.number,
          commit: defect.commit,
          attribution: defect.attribution,
          severity: defect.severity,
          ticket: defect.ticket,
          recorded_at: defect.recorded_at,
          lane: Map.fetch!(lanes, change_request_id),
          policy_version: change_request.policy_version,
          rules: change_request |> rules() |> Enum.sort(),
          globs: Map.get(matched, defect.id, [])
        }
      end
      |> Enum.sort_by(&{DateTime.to_unix(&1.recorded_at, :microsecond), &1.id}, :desc)

    {Enum.take(entries, @max_listed_defects), length(entries) > @max_listed_defects}
  end

  defp unattributed_count(project_id, window) do
    Repo.aggregate(
      from(d in Defect,
        where:
          d.project_id == ^project_id and d.attribution == "unattributed" and
            d.recorded_at >= ^window.from and d.recorded_at < ^window.to
      ),
      :count
    )
  end

  defp window_params(params) do
    types = %{from: :utc_datetime_usec, to: :utc_datetime_usec}

    changeset =
      {%{from: nil, to: nil}, types}
      |> Ecto.Changeset.cast(params, [:from, :to], empty_values: [])

    to = Ecto.Changeset.get_field(changeset, :to) || DateTime.utc_now()

    from =
      Ecto.Changeset.get_field(changeset, :from) || DateTime.add(to, -@default_window_days, :day)

    changeset
    |> Ecto.Changeset.put_change(:from, from)
    |> Ecto.Changeset.put_change(:to, to)
    |> then(fn changeset ->
      if changeset.valid? and DateTime.compare(from, to) != :lt,
        do: Ecto.Changeset.add_error(changeset, :from, "must be before to"),
        else: changeset
    end)
    |> Ecto.Changeset.apply_action(:report)
  end

  defp merged_in(project_id, window) do
    Repo.all(
      from c in ChangeRequest,
        where:
          c.project_id == ^project_id and c.state == "merged" and c.merged_at >= ^window.from and
            c.merged_at < ^window.to,
        order_by: c.number,
        select: %{
          id: c.id,
          number: c.number,
          head: c.merged_head,
          target_branch: c.target_branch,
          policy_version: c.merged_policy_version,
          reasons: c.merged_reasons,
          without_mergeable_verdict: c.merged_without_mergeable_verdict,
          without_lease: c.merged_without_lease
        }
    )
  end

  defp defects_of(merged) do
    ids = Enum.map(merged, & &1.id)

    Repo.all(from d in Defect, where: d.change_request_id in ^ids, order_by: d.recorded_at)
    |> Enum.group_by(& &1.change_request_id)
  end

  defp answered(merged) do
    ids = Enum.map(merged, & &1.id)

    Repo.all(
      from a in Answer,
        join: c in ChangeRequest,
        on: c.id == a.change_request_id,
        where: a.change_request_id in ^ids and a.head == c.merged_head,
        distinct: true,
        select: a.change_request_id
    )
    |> MapSet.new()
  end

  defp lane(change_request, answered) do
    cond do
      change_request.without_mergeable_verdict or change_request.without_lease -> "bypass"
      MapSet.member?(answered, change_request.id) -> "reviewed"
      true -> "auto"
    end
  end

  defp lane_stats(merged, lanes, counts) do
    grouped = Enum.group_by(merged, &Map.fetch!(lanes, &1.id))
    Map.new(@lanes, &{&1, stats(Map.get(grouped, &1, []), counts)})
  end

  defp stats(change_requests, counts) do
    merged_count = length(change_requests)
    defect_counts = Enum.map(change_requests, &Map.fetch!(counts, &1.id))
    defective_count = Enum.count(defect_counts, &(&1 > 0))

    %{
      merged_count: merged_count,
      defect_count: Enum.sum(defect_counts),
      defective_count: defective_count,
      defect_rate: if(merged_count > 0, do: defective_count / merged_count)
    }
  end

  defp policy_version_stats(merged, lanes, counts) do
    merged
    |> Enum.group_by(& &1.policy_version)
    |> Enum.sort_by(fn {version, _crs} -> version end)
    |> Enum.map(fn {version, change_requests} ->
      %{version: version, lanes: lane_stats(change_requests, lanes, counts)}
    end)
  end

  defp rules(change_request),
    do: (change_request.reasons || []) |> Enum.map(& &1["rule"]) |> Enum.uniq()

  defp rule_stats(merged, counts) do
    merged
    |> Enum.flat_map(fn change_request ->
      Enum.map(rules(change_request), &{&1, change_request})
    end)
    |> Enum.group_by(fn {rule, _cr} -> rule end, fn {_rule, cr} -> cr end)
    |> Enum.sort_by(fn {rule, _crs} -> rule end)
    |> Enum.map(fn {rule, change_requests} ->
      %{
        rule: rule,
        fired_count: length(change_requests),
        fired_with_defects_count: Enum.count(change_requests, &(Map.fetch!(counts, &1.id) > 0))
      }
    end)
  end

  defp gaps(merged, counts) do
    for change_request <- merged,
        Map.fetch!(counts, change_request.id) > 0,
        (change_request.reasons || []) == [],
        do: change_request.number
  end

  # Each defect's files: the commit's `changed_files` when attributed by
  # commit, else the merged head's diff files (paths and old paths).
  defp glob_stats(project, merged, defects) do
    globs =
      merged
      |> Enum.map(& &1.policy_version)
      |> Enum.uniq()
      |> Enum.flat_map(&policy_globs(project, &1))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&{&1, Glob.compile(&1)})

    by_id = Map.new(merged, &{&1.id, &1})

    # Each defect's id with the sorted globs that match its files.
    matched =
      for {change_request_id, list} <- defects,
          document <- [merged_facts(Map.fetch!(by_id, change_request_id))],
          defect <- list,
          into: %{} do
        files = defect_files(defect, document)
        hit = for {glob, regex} <- globs, Enum.any?(files, &Glob.match?(regex, &1)), do: glob
        {defect.id, hit}
      end

    stats =
      Enum.map(globs, fn {glob, _regex} ->
        %{glob: glob, defect_count: Enum.count(matched, fn {_id, hit} -> glob in hit end)}
      end)

    unmatched = Enum.count(matched, fn {_id, hit} -> hit == [] end)

    {stats, unmatched, matched}
  end

  defp policy_globs(project, version) do
    case ReviewPolicies.get_version(project, version) do
      {:ok, stored} -> Enum.map(Document.effective(stored.document)["paths"], & &1["glob"])
      {:error, :not_found} -> []
    end
  end

  # A change request merged with no reported head has no Git facts.
  defp merged_facts(%{head: nil}), do: nil

  defp merged_facts(%{id: id, head: head, target_branch: target}) do
    Repo.one(
      from f in GitFacts,
        where: f.change_request_id == ^id and f.head == ^head,
        order_by: [desc: f.target_branch == ^target, desc: f.inserted_at],
        limit: 1,
        select: f.document
    )
  end

  defp defect_files(_defect, nil), do: []

  # A commit matched as the merged commit, not in `commits`, gets the diff:
  # a squash or merge commit holds all of it, and the merge method is unknown.
  defp defect_files(%Defect{attribution: "commit", commit: commit}, document) do
    case Enum.find(document["commits"], &(&1["sha"] == commit)) do
      nil -> paths(document["diff"]["files"])
      found -> paths(found["changed_files"])
    end
  end

  defp defect_files(%Defect{}, document), do: paths(document["diff"]["files"])

  defp paths(files),
    do: files |> Enum.flat_map(&[&1["path"], &1["old_path"]]) |> Enum.filter(&is_binary/1)
end
