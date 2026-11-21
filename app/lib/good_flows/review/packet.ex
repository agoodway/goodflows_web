defmodule GoodFlows.Review.Packet do
  @moduledoc """
  Builds a change request's review packet from its stored verdict (design
  D1): the header (`number`, `head`, `base`, `policy_version`, `verdict`
  and `passed`), the `pending` and `blocked` reasons as context, and one
  item per reason that needs a person, each with its `data`, allowed
  `answers` and current `answer` at the head.

  Item data comes only from inputs stored for the head: the claims front
  matter (hunks come only from its `decisions`), the Git facts, the
  scenario set versions, the counted verify runs and the feature index
  version the verdict used. Artifact GET URLs are presigned on every build
  and expire after 15 minutes; an artifact whose object retention
  deleted has `expired` true and no URL, and without object storage `url`
  is nil.
  """
  import Ecto.Query

  alias GoodFlows.Caches.ObjectStore
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.{ChangeRequest, Verdict}
  alias GoodFlows.FeatureIndex
  alias GoodFlows.FeatureIndex.Version, as: IndexVersion
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.Review.{Answer, Items}
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ReviewPolicies.{Document, Glob}
  alias GoodFlows.ScenarioSets
  alias GoodFlows.ScenarioSets.Document, as: SetDocument
  alias GoodFlows.VerifyRuns.{Artifact, Run}

  @url_ttl_seconds 900

  @typedoc "A packet, ready to render."
  @type t :: map()

  @doc "The claims front matter at the change request's head, or nil."
  @spec claims(ChangeRequest.t()) :: map() | nil
  def claims(%ChangeRequest{head: nil}), do: nil

  def claims(%ChangeRequest{} = change_request) do
    case ChangeRequests.get_claims(change_request, change_request.head) do
      {:ok, claims} -> claims.front_matter
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Builds the packet of `change_request` from its stored `verdict` and the
  current answers at the head (`%{item_id => answer}`).
  """
  @spec build(ChangeRequest.t(), Verdict.t(), %{String.t() => Answer.t()}) :: t()
  def build(%ChangeRequest{} = change_request, %Verdict{} = verdict, answers) do
    facts = facts(change_request)
    claims = if facts, do: claims(change_request)
    {pending, blocked} = Items.context(verdict.reasons)

    inputs = %{
      change_request: change_request,
      verdict: verdict,
      facts: facts,
      claims: claims || %{},
      effective: effective_policy(change_request, verdict),
      now: DateTime.utc_now()
    }

    items =
      for item <- Items.build(verdict.reasons, claims) do
        Map.merge(item, %{data: data(item, inputs), answer: Map.get(answers, item.id)})
      end

    %{
      number: change_request.number,
      head: change_request.head,
      base:
        facts && %{branch: facts["target"]["branch"], merge_base: facts["target"]["merge_base"]},
      policy_version: verdict.policy_version,
      verdict: verdict.state,
      passed: passed(verdict),
      pending: Enum.map(pending, &context_entry/1),
      blocked: Enum.map(blocked, &context_entry/1),
      items: items
    }
  end

  defp facts(%ChangeRequest{head: nil}), do: nil

  defp facts(change_request) do
    case ChangeRequests.get_git_facts(change_request, change_request.head) do
      {:ok, facts} -> facts.document
      {:error, :not_found} -> nil
    end
  end

  defp effective_policy(change_request, verdict) do
    project = %Project{id: change_request.project_id}

    case ReviewPolicies.get_version(project, verdict.policy_version) do
      {:ok, version} -> Document.effective(version.document)
      {:error, :not_found} -> ReviewPolicies.compiled(change_request.project_id).effective
    end
  end

  defp context_entry(reason),
    do: %{rule: reason["rule"], subject: reason["subject"], message: reason["message"]}

  defp passed(verdict) do
    scenarios =
      for {_source, set} <- verdict.scenarios || %{},
          set != nil,
          scenario <- set["scenarios"],
          scenario["result"] == "passed",
          do: scenario["priority"]

    failing =
      for %{"rule" => rule, "subject" => [name]} <- verdict.reasons,
          rule in ~w(required_workflow_missing required_workflow_failed),
          into: MapSet.new(),
          do: name

    workflows =
      for {name, run_id} <- verdict.inputs["required_workflows"] || %{},
          run_id != nil,
          not MapSet.member?(failing, name),
          do: name

    %{
      must: Enum.count(scenarios, &(&1 == "must")),
      should: Enum.count(scenarios, &(&1 == "should")),
      workflows: Enum.sort(workflows)
    }
  end

  defp data(%{kind: "scenario_set_approval", subject: [digest]}, inputs) do
    change_request = inputs.change_request
    current = ScenarioSets.current(change_request, "intent")

    {approved, changes} =
      case ScenarioSets.compare(change_request, "intent", %{}) do
        {:ok, comparison} -> {comparison.from, comparison.changes}
        {:error, _reason} -> {nil, []}
      end

    %{
      digest: digest,
      version: current && current.version,
      approved_digest: approved && approved.digest,
      changes: changes
    }
  end

  defp data(%{kind: "diff_only_set"}, inputs) do
    set = inputs.verdict.scenarios["diff"] || %{}
    current = ScenarioSets.current(inputs.change_request, "diff")

    %{
      digest: set["digest"],
      revision: current && current.front_matter["revision"],
      scenarios: Enum.map(set["scenarios"] || [], &Map.take(&1, ~w(id priority result run_id)))
    }
  end

  defp data(%{kind: "failed_scenario", subject: [source, id]}, inputs) do
    {set, scenario, run} = scenario_run(inputs, source, id)
    result = run && result(run, id)

    %{
      id: id,
      priority: scenario["priority"],
      digest: set["digest"],
      run_id: run && run.run_id,
      commit: run && run.source_commit,
      failed_step: result && result["failed_step"],
      reason: result && result["reason"],
      artifacts: if(run, do: artifacts(run, result, inputs.now), else: [])
    }
  end

  defp data(%{kind: "not_run", subject: [source, id]}, inputs) do
    {set, scenario, run} = scenario_run(inputs, source, id)
    result = run && result(run, id)

    %{
      id: id,
      priority: scenario["priority"],
      digest: set["digest"],
      run_id: run && run.run_id,
      reason: result && result["reason"]
    }
  end

  defp data(%{kind: "spec_gap", subject: [capability, requirement, scenario]}, inputs) do
    row = %{"capability" => capability, "requirement" => requirement, "scenario" => scenario}
    intent = inputs.verdict.scenarios["intent"] || %{}

    %{
      capability: capability,
      requirement: requirement,
      scenario: scenario,
      digest: intent["digest"],
      version: intent["version"],
      covering_claims: covering_claims(inputs.claims, row)
    }
  end

  defp data(%{kind: "one_way_door"}, inputs) do
    %{
      door_reason: inputs.claims["door_reason"],
      reach: inputs.claims["reach"],
      decisions: decisions(inputs.claims, nil)
    }
  end

  defp data(%{kind: "unproven_claim"}, inputs) do
    minimum = inputs.effective["claims"]["min_proof_level"]
    floor = rank(minimum)

    %{
      min_proof_level: minimum,
      claims: unproven(inputs.claims, floor)
    }
  end

  defp data(%{kind: "open_item", subject: [index, _risk]}, inputs) do
    entry = Enum.at(inputs.claims["left_open"] || [], String.to_integer(index)) || %{}
    %{risk: entry["risk"], location: entry["location"], affected: entry["affected"]}
  end

  defp data(%{kind: "question", subject: [id]}, inputs) do
    question = Enum.find(inputs.claims["questions"] || [], &(&1["id"] == id)) || %{}

    %{
      id: id,
      text: question["text"],
      options: question["options"],
      recommendation: question["recommendation"]
    }
  end

  defp data(%{kind: "sensitive_path", subject: [glob | matched]}, inputs) do
    matched = MapSet.new(matched)

    files =
      for file <- diff_files(inputs),
          MapSet.member?(matched, file["path"]) or MapSet.member?(matched, file["old_path"]),
          do: %{
            path: file["path"],
            old_path: Map.get(file, "old_path"),
            additions: file["additions"],
            deletions: file["deletions"]
          }

    %{glob: glob, files: files, decisions: decisions(inputs.claims, matched)}
  end

  defp data(%{kind: "size", rule: rule}, inputs) do
    files = diff_files(inputs)
    size = inputs.effective["size"]

    %{
      limit: rule,
      changed_files: length(files),
      changed_lines: Enum.reduce(files, 0, &(&1["additions"] + &1["deletions"] + &2)),
      max_changed_files: size["max_changed_files"],
      max_changed_lines: size["max_changed_lines"]
    }
  end

  defp data(%{kind: "unmapped_area", subject: paths}, inputs) do
    %{paths: paths, feature_index_version: inputs.verdict.coverage["version"]}
  end

  defp data(%{kind: "undriven_feature", subject: [id]}, inputs) do
    feature =
      case index_version(inputs) do
        nil -> nil
        version -> Enum.find(version.features, &(&1["id"] == id))
      end

    paths =
      if feature do
        regexes = Enum.map(feature["paths"], &Glob.compile/1)

        for file <- diff_files(inputs),
            path <- Enum.filter([file["path"], file["old_path"]], &is_binary/1),
            Enum.any?(regexes, &Glob.match?(&1, path)),
            uniq: true,
            do: path
      else
        []
      end

    %{id: id, title: feature && feature["title"], paths: Enum.sort(paths)}
  end

  defp index_version(inputs) do
    case inputs.verdict.coverage["version"] do
      nil ->
        nil

      number ->
        case FeatureIndex.get_version(%Project{id: inputs.change_request.project_id}, number) do
          {:ok, %IndexVersion{} = version} -> version
          {:error, :not_found} -> nil
        end
    end
  end

  defp diff_files(%{facts: nil}), do: []
  defp diff_files(%{facts: facts}), do: facts["diff"]["files"]

  defp decisions(claims, paths) do
    for decision <- claims["decisions"] || [],
        paths == nil or MapSet.member?(paths, decision["path"]),
        do: %{
          id: decision["id"],
          path: decision["path"],
          hunk: decision["hunk"],
          note: decision["note"]
        }
  end

  defp covering_claims(claims, row) do
    for entry <- claims["safe_because"] || [],
        entry["covers"] == row,
        do: %{fact: entry["fact"], proof: entry["proof"], evidence: Map.get(entry, "evidence")}
  end

  defp unproven(claims, floor) do
    for entry <- claims["safe_because"] || [],
        rank(entry["proof"]) < floor,
        do: %{
          fact: entry["fact"],
          location: entry["location"],
          proof: entry["proof"],
          evidence: Map.get(entry, "evidence"),
          covers: Map.get(entry, "covers")
        }
  end

  defp rank(level), do: Enum.find_index(Document.proof_levels(), &(&1 == level))

  defp scenario_run(inputs, source, id) do
    set = inputs.verdict.scenarios[source] || %{}
    scenario = Enum.find(set["scenarios"] || [], &(&1["id"] == id)) || %{}

    run =
      case scenario["run_id"] do
        nil ->
          nil

        run_id ->
          Repo.one(
            from r in Run,
              where: r.project_id == ^inputs.change_request.project_id and r.run_id == ^run_id,
              preload: [artifacts: ^from(a in Artifact, order_by: a.artifact_id)]
          )
      end

    {set, scenario, run}
  end

  defp result(run, id),
    do: Enum.find(run.document["results"], &(SetDocument.id_string(&1["id"]) == id))

  defp artifacts(run, result, now) do
    evidence = MapSet.new((result && result["evidence"]) || [])

    for artifact <- run.artifacts,
        MapSet.member?(evidence, artifact.artifact_id),
        do: artifact(artifact, now)
  end

  defp artifact(%Artifact{expired: true} = artifact, _now),
    do: artifact_entry(artifact, nil, nil, true)

  defp artifact(%Artifact{} = artifact, now) do
    if ObjectStore.configured?() do
      url = ObjectStore.presign_get(artifact.object_key, %{expires_in: @url_ttl_seconds})
      artifact_entry(artifact, url, DateTime.add(now, @url_ttl_seconds, :second), false)
    else
      artifact_entry(artifact, nil, nil, false)
    end
  end

  defp artifact_entry(artifact, url, expires_at, expired) do
    %{
      id: artifact.artifact_id,
      content_type: artifact.content_type,
      size: artifact.size,
      url: url,
      expires_at: expires_at,
      expired: expired
    }
  end
end
