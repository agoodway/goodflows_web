defmodule GoodFlows.ChangeRequests.Grading do
  @moduledoc """
  Loads the grading inputs of a change request's verdict (design D2, D7,
  D8): its current intent and diff set versions, whether each is approved,
  accepted and graded, the diff set's baseline and the Musts it weakens,
  the verify runs that count at the head, and the project's compiled
  feature index. `GoodFlows.ChangeRequests.Rules` turns them into
  reasons.

  The intent set is graded when its current digest is approved, or always
  when `scenarios.require_approved_intent` is false. The diff set is graded
  when its `revision` names the head (`names_head?/4`): the head or a
  prefix of it, or an earlier commit in the head's `git-facts.commits`
  followed only by commits that change ignored paths.

  A run counts at head H (`counts?/4`) when it is `final`, clean, has no
  `merge_result`, grades a graded set's digest with that set's source, and
  its commit is H or appears in H's `git-facts.commits` with every later
  commit changing only files that match `evidence.ignore_paths`.
  Merge-result runs (`merge_result_runs/3`) never count at the head; they
  decide only the merge-result check of a leased change request.
  """
  import Ecto.Query

  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.FeatureIndex
  alias GoodFlows.Repo
  alias GoodFlows.ScenarioSets
  alias GoodFlows.ScenarioSets.Document, as: SetDocument
  alias GoodFlows.ScenarioSets.Version
  alias GoodFlows.VerifyRuns.Run

  @typedoc """
  A set as the rules see it. A diff set also has its `baseline` (`version`
  and `digest`) and the `weakened` Musts: each `removed` or `demoted` Must
  of the baseline, with `from_priority` and `to_priority`.
  """
  @type set :: %{
          required(:version) => pos_integer(),
          required(:digest) => String.t(),
          required(:approved) => boolean(),
          required(:accepted) => boolean(),
          required(:graded) => boolean(),
          required(:revision) => String.t() | nil,
          required(:scenarios) => [%{id: String.t(), priority: String.t()}],
          required(:coverage) => [map()],
          optional(:baseline) => %{version: pos_integer(), digest: String.t()},
          optional(:weakened) => [map()]
        }

  @typedoc "A counted run as the rules see it."
  @type run :: %{
          id: Ecto.UUID.t(),
          run_id: String.t(),
          source: String.t(),
          digest: String.t(),
          finished_at: DateTime.t(),
          results: %{String.t() => String.t()},
          features: [map()]
        }

  @typedoc "Everything the grading rules read."
  @type t :: %{
          linked?: boolean(),
          intent: set() | nil,
          diff: set() | nil,
          runs: [run()],
          index: FeatureIndex.compiled() | nil
        }

  @doc "No sets, runs or index: what a verdict without grading inputs sees."
  @spec empty() :: t()
  def empty, do: %{linked?: false, intent: nil, diff: nil, runs: [], index: nil}

  @doc """
  Loads the grading inputs of `change_request` with its current Git facts
  document (or nil) and compiled `policy`.
  """
  @spec load(ChangeRequest.t(), map() | nil, map()) :: t()
  def load(%ChangeRequest{} = change_request, facts_document, policy) do
    require? = policy.effective["scenarios"]["require_approved_intent"]
    approved = ScenarioSets.approved_digests(change_request)
    commits = (facts_document && facts_document["commits"]) || []
    ignore = Map.get(policy, :ignore, [])
    head = {change_request.head, commits, ignore}
    intent = set(ScenarioSets.current(change_request, "intent"), approved, head)
    diff_version = ScenarioSets.current(change_request, "diff")
    diff = set(diff_version, approved, head)
    intent = intent && Map.put(intent, :graded, intent.approved or not require?)
    diff = diff && diff_baseline(diff, diff_version, change_request, approved)

    %{
      linked?: change_request.openspec_change != nil,
      intent: intent,
      diff: diff,
      runs: counted_runs(change_request, facts_document, policy, [intent, diff]),
      index: FeatureIndex.compiled(change_request.project_id)
    }
  end

  defp set(nil, _approved, _head), do: nil

  defp set(%Version{} = version, approved, {head, commits, ignore}) do
    revision = version.front_matter["revision"]

    %{
      version: version.version,
      digest: version.digest,
      approved: ScenarioSets.approved?(version, approved),
      accepted: ScenarioSets.accepted?(version, approved),
      graded: version.source == "diff" and names_head?(revision, head, commits, ignore),
      revision: revision,
      scenarios: Version.scenarios(version),
      coverage: version.front_matter["coverage"] || []
    }
  end

  defp diff_baseline(diff, version, change_request, approved) do
    baseline = ScenarioSets.baseline(change_request, approved)

    Map.merge(diff, %{
      baseline: %{version: baseline.version, digest: baseline.digest},
      weakened: weakened(baseline, version)
    })
  end

  @doc """
  The Musts of diff version `baseline` that `current` removes or demotes
  to `should` or `could` (`ScenarioSets.changes/2`), each with `id`,
  `change` (`removed` or `demoted`), `from_priority` and `to_priority`.
  A renamed Must is removed; an edited Must that stays `must` is not
  listed.
  """
  @spec weakened(Version.t(), Version.t()) :: [map()]
  def weakened(%Version{} = baseline, %Version{} = current) do
    baseline
    |> ScenarioSets.changes(current)
    |> Enum.filter(& &1.weakening)
    |> Enum.map(&Map.take(&1, [:id, :change, :from_priority, :to_priority]))
  end

  @doc """
  Whether a diff set `revision` names `head`: it is `head` or a prefix of
  it, or else it is a prefix of exactly one commit in the head's
  `git-facts.commits` and that commit counts at the head (`counts?/4`
  with the `ignore_paths` regexes). Without facts (`commits` `[]`) only
  the prefix rule applies.
  """
  @spec names_head?(String.t() | nil, String.t() | nil, [map()], [Regex.t()]) :: boolean()
  def names_head?(revision, head, commits \\ [], ignore \\ [])

  def names_head?(revision, head, commits, ignore)
      when is_binary(revision) and is_binary(head) do
    String.starts_with?(head, revision) or
      case Enum.filter(commits, &String.starts_with?(&1["sha"], revision)) do
        [%{"sha" => sha}] -> counts?(sha, head, commits, ignore)
        _none_or_many -> false
      end
  end

  def names_head?(_revision, _head, _commits, _ignore), do: false

  defp counted_runs(_change_request, nil, _policy, _sets), do: []

  defp counted_runs(change_request, facts, policy, [intent, diff]) do
    graded =
      [{"intent", intent}, {"diff", diff}]
      |> Enum.filter(fn {_source, set} -> set && set.graded end)
      |> Enum.map(fn {source, set} -> {source, set.digest} end)

    head = change_request.head
    commits = facts["commits"]
    shas = Enum.uniq([head | Enum.map(commits, & &1["sha"])])

    if graded == [] do
      []
    else
      for run <- final_clean_runs(change_request.project_id, shas, graded),
          counts?(run.commit, head, commits, policy.ignore) do
        results = Map.new(run.results, &{SetDocument.id_string(&1["id"]), &1["result"]})
        run |> Map.delete(:commit) |> Map.put(:results, results)
      end
    end
  end

  defp digest_match(graded) do
    Enum.reduce(graded, dynamic(false), fn {source, digest}, acc ->
      dynamic(
        [r],
        ^acc or (r.scenario_set_source == ^source and r.scenario_set_digest == ^digest)
      )
    end)
  end

  defp final_clean_runs(project_id, shas, graded) do
    digest_match = digest_match(graded)

    Repo.all(
      from r in Run,
        where:
          r.project_id == ^project_id and r.status == "final" and
            r.dirty == false and r.merge_result == false and r.source_commit in ^shas,
        where: ^digest_match,
        select: %{
          id: r.id,
          run_id: type(r.run_id, :string),
          source: r.scenario_set_source,
          digest: r.scenario_set_digest,
          commit: r.source_commit,
          finished_at: r.finished_at,
          results: fragment("?->'results'", r.document),
          features: fragment("?->'features'", r.document)
        }
    )
  end

  @typedoc """
  Why grading ignores a verify run at the head, in the order
  `explain_runs/4` checks them, or `:counts`.
  """
  @type run_status ::
          :counts
          | :uploading
          | :dirty
          | :merge_result
          | :older_version
          | :intent_not_approved
          | :diff_not_at_head
          | :no_git_facts
          | :commit_not_counted

  @typedoc """
  A verify run on one of a change request's set digests: summary columns,
  the set `version` its digest belongs to, and the number of results of
  each outcome.
  """
  @type listed_run :: %{
          id: Ecto.UUID.t(),
          run_id: String.t(),
          status: String.t(),
          dirty: boolean(),
          merge_result: boolean(),
          commit: String.t(),
          inserted_at: DateTime.t(),
          source: String.t(),
          digest: String.t(),
          version: pos_integer() | nil,
          finished_at: DateTime.t(),
          counts: %{String.t() => non_neg_integer()}
        }

  @max_listed_runs 50

  @doc """
  Up to #{@max_listed_runs} verify runs of the project on the digest of
  any of the change request's intent or diff set versions, newest
  `finished_at` first, then `run_id`. With `stored_by`, only runs stored
  at or before it, applied before the limit. Result counts are summed in
  SQL, so documents are not loaded.
  """
  @spec runs_on_sets(ChangeRequest.t(), DateTime.t() | nil) :: [listed_run()]
  def runs_on_sets(%ChangeRequest{id: id, project_id: project_id}, stored_by \\ nil) do
    versions =
      Repo.all(
        from v in Version,
          where: v.change_request_id == ^id,
          select: {v.source, v.digest, v.version}
      )

    version_of =
      Enum.reduce(versions, %{}, fn {source, digest, version}, acc ->
        Map.update(acc, {source, digest}, version, &max(&1, version))
      end)

    digests = versions |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    if digests == [] do
      []
    else
      on_sets =
        from r in Run,
          where: r.project_id == ^project_id and r.scenario_set_digest in ^digests

      on_sets =
        if stored_by, do: where(on_sets, [r], r.inserted_at <= ^stored_by), else: on_sets

      Repo.all(
        from r in on_sets,
          order_by: [desc: r.finished_at, desc: r.run_id],
          limit: @max_listed_runs,
          select: %{
            id: r.id,
            run_id: type(r.run_id, :string),
            status: r.status,
            dirty: r.dirty,
            merge_result: r.merge_result,
            commit: r.source_commit,
            inserted_at: r.inserted_at,
            source: r.scenario_set_source,
            digest: r.scenario_set_digest,
            finished_at: r.finished_at,
            counts:
              fragment(
                """
                (SELECT jsonb_build_object(
                   'passed', count(*) FILTER (WHERE e->>'result' = 'passed'),
                   'failed', count(*) FILTER (WHERE e->>'result' = 'failed'),
                   'not_run', count(*) FILTER (WHERE e->>'result' = 'not_run'))
                 FROM jsonb_array_elements(?->'results') AS e)
                """,
                r.document
              )
          }
      )
      |> Enum.map(&Map.put(&1, :version, Map.get(version_of, {&1.source, &1.digest})))
    end
  end

  @doc """
  `runs_on_sets/2` with each run's `explanation`: `:counts` when the run
  counts at the head (exactly the runs `load/3` counts), or else the first
  reason that applies, in the order of `t:run_status/0`. `grading` is
  `load/3` of the same change request, facts document and policy.
  """
  @spec explain_runs(ChangeRequest.t(), map() | nil, map(), t()) :: [
          %{required(:explanation) => run_status(), optional(atom()) => term()}
        ]
  def explain_runs(%ChangeRequest{} = change_request, facts_document, policy, grading) do
    commits = (facts_document && facts_document["commits"]) || []
    ignore = Map.get(policy, :ignore, [])
    sets = %{"intent" => grading.intent, "diff" => grading.diff}
    explain = &explain(&1, change_request.head, facts_document, commits, ignore, sets)

    change_request
    |> runs_on_sets()
    |> Enum.map(&Map.put(&1, :explanation, explain.(&1)))
  end

  defp explain(run, head, facts_document, commits, ignore, sets) do
    set = sets[run.source]

    [
      uploading: fn -> run.status != "final" end,
      dirty: fn -> run.dirty end,
      merge_result: fn -> run.merge_result end,
      older_version: fn -> set == nil or set.digest != run.digest end,
      intent_not_approved: fn -> not set.graded and run.source == "intent" end,
      diff_not_at_head: fn -> not set.graded end,
      no_git_facts: fn -> facts_document == nil end,
      commit_not_counted: fn -> not counts?(run.commit, head, commits, ignore) end
    ]
    |> Enum.find_value(:counts, fn {reason, applies?} -> if applies?.(), do: reason end)
  end

  @doc """
  The verify runs that decide the merge-result check for a lease `base`:
  `final`, clean runs with a `merge_result` whose `base` is `base`, on a
  set the verdict grades at the head (`grading`'s graded intent and diff
  sets), on any commit. Each has the run shape of `t:run/0`.
  """
  @spec merge_result_runs(Ecto.UUID.t(), String.t(), t()) :: [run()]
  def merge_result_runs(project_id, base, grading) do
    graded =
      [{"intent", grading.intent}, {"diff", grading.diff}]
      |> Enum.filter(fn {_source, set} -> set && set.graded end)
      |> Enum.map(fn {source, set} -> {source, set.digest} end)

    if graded == [] do
      []
    else
      Repo.all(
        from r in Run,
          where:
            r.project_id == ^project_id and r.status == "final" and r.dirty == false and
              r.merge_result == true and
              fragment("?->'merge_result'->>'base'", r.document) == ^base,
          where: ^digest_match(graded),
          select: %{
            id: r.id,
            run_id: type(r.run_id, :string),
            source: r.scenario_set_source,
            digest: r.scenario_set_digest,
            finished_at: r.finished_at,
            results: fragment("?->'results'", r.document),
            features: fragment("?->'features'", r.document)
          }
      )
      |> Enum.map(fn run ->
        %{run | results: Map.new(run.results, &{SetDocument.id_string(&1["id"]), &1["result"]})}
      end)
    end
  end

  @doc """
  Whether a run on `commit` counts at `head`, given the head's
  `git-facts.commits` (oldest first) and the `ignore_paths` regexes.
  """
  @spec counts?(String.t(), String.t(), [map()], [Regex.t()]) :: boolean()
  def counts?(head, head, _commits, _ignore), do: true

  def counts?(commit, _head, commits, ignore) do
    case Enum.find_index(commits, &(&1["sha"] == commit)) do
      nil ->
        false

      index ->
        commits
        |> Enum.drop(index + 1)
        |> Enum.all?(fn later ->
          Enum.all?(later["changed_files"], &FeatureIndex.ignored?(&1, ignore))
        end)
    end
  end
end
