defmodule GoodFlows.ChangeRequests.Grading do
  @moduledoc """
  Loads the grading inputs of a change request's verdict (design D2, D7,
  D8): its current intent and diff set versions, whether each is approved
  and graded, the verify runs that count at the head, and the project's
  compiled feature index. `GoodFlows.ChangeRequests.Rules` turns them into
  reasons.

  The intent set is graded when its current digest is approved, or always
  when `scenarios.require_approved_intent` is false. The diff set is graded
  when its `revision` is the head or a prefix of it.

  A run counts at head H (`counts?/4`) when it is `final`, clean, has no
  `merge_result`, grades a graded set's digest with that set's source, and
  its commit is H or appears in H's `git-facts.commits` with every later
  commit changing only files that match `evidence.ignore_paths`.
  """
  import Ecto.Query

  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.FeatureIndex
  alias GoodFlows.Repo
  alias GoodFlows.ScenarioSets
  alias GoodFlows.ScenarioSets.Document, as: SetDocument
  alias GoodFlows.ScenarioSets.Version
  alias GoodFlows.VerifyRuns.Run

  @typedoc "A set as the rules see it."
  @type set :: %{
          version: pos_integer(),
          digest: String.t(),
          approved: boolean(),
          graded: boolean(),
          revision: String.t() | nil,
          scenarios: [%{id: String.t(), priority: String.t()}],
          coverage: [map()]
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
    intent = set(ScenarioSets.current(change_request, "intent"), approved, change_request.head)
    diff = set(ScenarioSets.current(change_request, "diff"), approved, change_request.head)
    intent = intent && Map.put(intent, :graded, intent.approved or not require?)

    %{
      linked?: change_request.openspec_change != nil,
      intent: intent,
      diff: diff,
      runs: counted_runs(change_request, facts_document, policy, [intent, diff]),
      index: FeatureIndex.compiled(change_request.project_id)
    }
  end

  defp set(nil, _approved, _head), do: nil

  defp set(%Version{} = version, approved, head) do
    revision = version.front_matter["revision"]

    %{
      version: version.version,
      digest: version.digest,
      approved: ScenarioSets.approved?(version, approved),
      graded: version.source == "diff" and names_head?(revision, head),
      revision: revision,
      scenarios: Version.scenarios(version),
      coverage: version.front_matter["coverage"] || []
    }
  end

  @doc "Whether a diff set `revision` is `head` or a prefix of it."
  @spec names_head?(String.t() | nil, String.t() | nil) :: boolean()
  def names_head?(revision, head) when is_binary(revision) and is_binary(head),
    do: String.starts_with?(head, revision)

  def names_head?(_revision, _head), do: false

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

  defp final_clean_runs(project_id, shas, graded) do
    digest_match =
      Enum.reduce(graded, dynamic(false), fn {source, digest}, acc ->
        dynamic(
          [r],
          ^acc or (r.scenario_set_source == ^source and r.scenario_set_digest == ^digest)
        )
      end)

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
