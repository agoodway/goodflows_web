defmodule GoodFlows.ChangeRequests.Rules do
  @moduledoc """
  The pure verdict function (design D6).

  `evaluate/1` takes the change request's current head, the Git facts and
  claims stored for it, the newest clean run of each required workflow on
  the head, and the compiled effective policy, and returns the verdict
  `state`, its `reasons`, the `head`, the `policy_version` and the
  `inputs` digests. It reads nothing else, so the same inputs always give
  the same verdict.

  Each reason has a stable `rule`, the `outcome` it contributes, a
  `subject` (strings, sorted unless the rule defines an order) and a
  `message`. `rule` plus `subject` is unique within a verdict. Reasons are
  ordered by outcome precedence (`pending`, `blocked`, `needs_review`),
  then `rule`, then `subject`, and `state` is the first reason's outcome,
  or `mergeable` when none fired.

  Without a head, only `git_facts_missing` (`subject` `[]`) fires. With a
  head but no Git facts for it and the target branch, `git_facts_missing`
  (`[head]`) and the required-workflow rules fire. With facts but no
  claims, `claims_missing` replaces the claims rules.

  Grading (`add-change-request-grading`) reads `inputs.grading`
  (`GoodFlows.ChangeRequests.Grading`). `scenario_set_approval` and
  `scenario_set_missing` read no Git facts and always run; every other
  grading rule runs only once facts exist for the head, and `spec_gap`
  only once claims do too. Scenario reasons have `subject`
  `[source, scenario id]`; `spec_gap` has `[capability, requirement,
  scenario]`. The verdict also carries `scenarios`, `coverage` and the
  `counted_runs`.

  A change request with only a diff set, under `require_approved_intent`,
  follows `scenarios.diff_only`: `needs_review` adds `diff_only_set` on
  every head; `weakening` adds `diff_set_weakened` (`["diff", id]`) for
  each Must of the diff baseline that the graded current version removes
  or demotes, when no OpenSpec change is linked; `ignore` adds neither.

  Merge coordination (`add-change-request-merge`) reads `inputs.parent`
  (the parent's number and state, or nil) and `inputs.merge_result` (the
  held lease's `base` and its merge-result runs, or nil when the check
  does not apply). A `draft` or `open` parent adds `parent_not_merged` and
  a `closed` one `parent_closed` (both `pending`, `subject` `[<parent
  number>]`), whatever the facts. With facts, the merge-result check uses
  the newest merge-result run of each graded set (a run holds one result
  per scenario of its set, so this is the newest result per Must): each
  Must that is not `passed` adds `merge_result_failed` (`blocked`,
  `[source, id]`), a Must without a result counting as `not_run`, and a
  graded set without such a run, or no graded set, adds
  `merge_result_ungraded` (`pending`, `[<lease base>]`). Merge-result runs
  never grade the branch.
  """

  alias GoodFlows.ChangeRequests.Grading
  alias GoodFlows.FeatureIndex
  alias GoodFlows.ReviewPolicies.Document
  alias GoodFlows.ReviewPolicies.Glob

  @precedence ~w(pending blocked needs_review)
  @gated ~w(needs_review blocked)

  @typedoc """
  A compiled policy: its version, effective document, `paths` regexes and
  `evidence.ignore_paths` regexes.
  """
  @type policy :: %{
          required(:version) => non_neg_integer(),
          required(:effective) => map(),
          required(:globs) => [{String.t(), String.t(), Regex.t()}],
          optional(:ignore) => [Regex.t()]
        }

  @typedoc "The newest clean run of a required workflow on the head, or nil."
  @type workflow_result :: %{outcome: String.t(), run_id: String.t()} | nil

  @typedoc "Everything the verdict depends on."
  @type inputs :: %{
          required(:head) => String.t() | nil,
          required(:git_facts) => %{document: map(), digest: binary()} | nil,
          required(:claims) => %{front_matter: map(), digest: binary()} | nil,
          required(:workflows) => %{String.t() => workflow_result()},
          required(:policy) => policy(),
          optional(:grading) => Grading.t(),
          optional(:parent) => %{number: pos_integer(), state: String.t()} | nil,
          optional(:merge_result) => %{base: String.t(), runs: [Grading.run()]} | nil
        }

  @typedoc "One reason, as stored and rendered."
  @type reason :: %{String.t() => String.t() | [String.t()]}

  @typedoc "A computed verdict."
  @type verdict :: %{
          state: String.t(),
          head: String.t() | nil,
          policy_version: non_neg_integer(),
          reasons: [reason()],
          inputs: map(),
          scenarios: map(),
          coverage: map(),
          counted_runs: [String.t()]
        }

  @doc "Computes the verdict for `inputs`."
  @spec evaluate(inputs()) :: verdict()
  def evaluate(inputs) do
    inputs = Map.put_new(inputs, :grading, Grading.empty())
    reasons = inputs |> all_reasons() |> Enum.sort_by(&sort_key/1)

    %{
      state: state(reasons),
      head: inputs.head,
      policy_version: inputs.policy.version,
      reasons: reasons,
      inputs: digests(inputs),
      scenarios: scenarios_view(inputs),
      coverage: coverage_view(inputs),
      counted_runs: inputs.grading.runs |> Enum.map(& &1.run_id) |> Enum.sort()
    }
  end

  defp all_reasons(inputs) do
    facts? = inputs.head != nil and inputs.git_facts != nil

    reasons(inputs) ++
      set_presence_reasons(inputs) ++
      parent_reasons(inputs[:parent]) ++
      if(facts?, do: grading_reasons(inputs) ++ merge_result_reasons(inputs), else: [])
  end

  defp parent_reasons(%{number: number, state: state}) when state in ~w(draft open),
    do: [
      reason(
        "parent_not_merged",
        "pending",
        [Integer.to_string(number)],
        "The parent change request #{number} is not merged"
      )
    ]

  defp parent_reasons(%{number: number, state: "closed"}),
    do: [
      reason(
        "parent_closed",
        "pending",
        [Integer.to_string(number)],
        "The parent change request #{number} is closed"
      )
    ]

  defp parent_reasons(_parent), do: []

  defp merge_result_reasons(%{merge_result: %{base: base, runs: runs}, grading: grading}) do
    ungraded =
      reason(
        "merge_result_ungraded",
        "pending",
        [base],
        "No counted verify run grades the merge result on the lease's base"
      )

    case graded_sets(grading) do
      [] ->
        [ungraded]

      sets ->
        sets |> Enum.flat_map(&merge_result_set(&1, runs, ungraded)) |> Enum.uniq()
    end
  end

  defp merge_result_reasons(_inputs), do: []

  defp merge_result_set({source, set}, runs, ungraded) do
    case newest_run(runs, source, set.digest) do
      nil -> [ungraded]
      run -> merge_result_failures(source, set, run)
    end
  end

  defp merge_result_failures(source, set, run) do
    for %{id: id, priority: "must"} <- set.scenarios,
        result = Map.get(run.results, id) || "not_run",
        result != "passed",
        do:
          reason(
            "merge_result_failed",
            "blocked",
            [source, id],
            "Must scenario #{id} of the #{source} set is #{result} on the merge result"
          )
  end

  defp require?(policy), do: policy.effective["scenarios"]["require_approved_intent"]

  defp set_presence_reasons(%{grading: grading, policy: policy}) do
    cond do
      not require?(policy) ->
        []

      grading.linked? and (grading.intent == nil or not grading.intent.approved) ->
        subject = if grading.intent, do: [grading.intent.digest], else: []

        [
          reason(
            "scenario_set_approval",
            "pending",
            subject,
            "The intent scenario set has no approved current version"
          )
        ]

      not grading.linked? and grading.diff == nil ->
        [
          reason(
            "scenario_set_missing",
            "pending",
            [],
            "The change request has no linked OpenSpec change and no diff scenario set"
          )
        ]

      true ->
        []
    end
  end

  defp diff_only_reasons(%{diff: diff, intent: nil} = grading, policy) when diff != nil do
    case {require?(policy), policy.effective["scenarios"]["diff_only"]} do
      {true, "needs_review"} ->
        [reason("diff_only_set", "needs_review", [], "Only a diff scenario set grades this")]

      {true, "weakening"} when diff.graded and not grading.linked? ->
        Enum.map(Map.get(diff, :weakened, []), &weakened_reason(&1, diff))

      _other ->
        []
    end
  end

  defp diff_only_reasons(_grading, _policy), do: []

  defp grading_reasons(%{grading: grading, policy: policy} = inputs) do
    revision =
      if grading.diff != nil and not grading.diff.graded,
        do: [
          reason(
            "diff_set_revision",
            "pending",
            [grading.diff.revision],
            "The diff scenario set does not name the head"
          )
        ],
        else: []

    diff_only_reasons(grading, policy) ++
      revision ++
      Enum.flat_map(graded_sets(grading), &set_reasons(&1, grading.runs, policy)) ++
      spec_gap_reasons(inputs) ++ coverage_reasons(inputs)
  end

  defp weakened_reason(%{id: id, change: change}, diff) do
    reason(
      "diff_set_weakened",
      "needs_review",
      ["diff", id],
      "Diff scenario set version #{diff.version} #{change} Must scenario #{id} of " <>
        "baseline version #{diff.baseline.version}"
    )
  end

  defp graded_sets(grading) do
    for {source, set} <- [{"intent", grading.intent}, {"diff", grading.diff}],
        set != nil and set.graded,
        do: {source, set}
  end

  defp newest_run(runs, source, digest) do
    runs
    |> Enum.filter(&(&1.source == source and &1.digest == digest))
    |> Enum.max_by(&{DateTime.to_unix(&1.finished_at, :microsecond), &1.run_id}, fn -> nil end)
  end

  defp set_reasons({source, set}, runs, policy) do
    case newest_run(runs, source, set.digest) do
      nil ->
        [
          reason(
            "scenario_results_missing",
            "pending",
            [source],
            "No counted verify run grades the #{source} scenario set at the head"
          )
        ]

      run ->
        should = policy.effective["scenarios"]["should_failures"]

        for scenario <- set.scenarios,
            reason = scenario_reason(source, scenario, run.results[scenario.id], should),
            do: reason
    end
  end

  defp scenario_reason(source, %{id: id, priority: "must"}, result, _should)
       when result in ["failed", "not_run"],
       do:
         reason(
           "must_failed",
           "blocked",
           [source, id],
           "Must scenario #{id} of the #{source} set is #{result}"
         )

  defp scenario_reason(source, %{id: id, priority: "should"}, "failed", "needs_review"),
    do:
      reason(
        "should_failed",
        "needs_review",
        [source, id],
        "Should scenario #{id} of the #{source} set failed"
      )

  defp scenario_reason(source, %{id: id, priority: "should"}, "not_run", "needs_review"),
    do:
      reason(
        "should_not_run",
        "needs_review",
        [source, id],
        "Should scenario #{id} of the #{source} set was not run"
      )

  defp scenario_reason(_source, _scenario, _result, _should), do: nil

  defp spec_gap_reasons(%{grading: %{intent: %{graded: true} = intent}, claims: claims} = inputs)
       when claims != nil do
    outcome = inputs.policy.effective["scenarios"]["spec_gaps"]
    minimum = rank(inputs.policy.effective["claims"]["min_proof_level"])
    proven = proven_covers(claims.front_matter, minimum)

    for row <- intent.coverage,
        outcome != "ignore",
        row["status"] == "no_check",
        key = %{
          "capability" => row["capability"],
          "requirement" => row["requirement"],
          "scenario" => row["scenario"]
        },
        not MapSet.member?(proven, key),
        do:
          reason(
            "spec_gap",
            outcome,
            [row["capability"], row["requirement"], row["scenario"]],
            "An OpenSpec scenario has no QA check and no proven claim"
          )
  end

  defp spec_gap_reasons(_inputs), do: []

  defp proven_covers(%{"safe_because" => entries}, minimum) do
    for entry <- entries,
        is_map(entry["covers"]),
        rank(entry["proof"]) >= minimum,
        into: MapSet.new(),
        do: entry["covers"]
  end

  defp proven_covers(_claims, _minimum), do: MapSet.new()

  defp coverage_reasons(%{grading: grading, policy: policy, git_facts: %{document: document}}) do
    unmapped_outcome = policy.effective["coverage"]["unmapped_areas"]
    undriven_outcome = policy.effective["coverage"]["undriven_features"]

    cond do
      unmapped_outcome == "ignore" and undriven_outcome == "ignore" ->
        []

      grading.index == nil ->
        [
          reason(
            "feature_index_missing",
            "pending",
            [],
            "The project has no synced feature index"
          )
        ]

      true ->
        mapping = mapping(grading, policy, document)
        driven = driven_features(grading.runs)

        unmapped =
          for path <- mapping.unmapped,
              unmapped_outcome != "ignore",
              do:
                reason(
                  "unmapped_area",
                  unmapped_outcome,
                  [path],
                  "A changed file matches no feature"
                )

        undriven =
          for id <- mapping.features,
              undriven_outcome != "ignore",
              not MapSet.member?(driven, id),
              do:
                reason(
                  "undriven_feature",
                  undriven_outcome,
                  [id],
                  "No counted verify run drove a changed feature"
                )

        unmapped ++ undriven
    end
  end

  defp mapping(grading, policy, document) do
    FeatureIndex.map_files(
      document["diff"]["files"],
      grading.index.features,
      Map.get(policy, :ignore, [])
    )
  end

  defp driven_features(runs) do
    for run <- runs,
        feature <- run.features,
        feature["result"] == "passed",
        into: MapSet.new(),
        do: feature["id"]
  end

  defp scenarios_view(%{grading: grading}) do
    Map.new([{"intent", grading.intent}, {"diff", grading.diff}], fn
      {source, nil} ->
        {source, nil}

      {source, set} ->
        run = if set.graded, do: newest_run(grading.runs, source, set.digest)

        {source,
         %{
           "version" => set.version,
           "digest" => set.digest,
           "approved" => set.approved,
           "graded" => set.graded,
           "scenarios" =>
             Enum.map(set.scenarios, fn scenario ->
               %{
                 "id" => scenario.id,
                 "priority" => scenario.priority,
                 "result" => run && run.results[scenario.id],
                 "run_id" => run && run.run_id
               }
             end)
         }
         |> Map.merge(diff_view(source, set))}
    end)
  end

  defp diff_view("diff", set),
    do: %{
      "accepted" => Map.get(set, :accepted, false),
      "baseline_version" => set[:baseline][:version]
    }

  defp diff_view(_source, _set), do: %{}

  defp coverage_view(%{grading: %{index: nil}}),
    do: %{"version" => nil, "unmapped_areas" => [], "features" => []}

  defp coverage_view(%{git_facts: nil, grading: grading}),
    do: %{"version" => grading.index.version, "unmapped_areas" => [], "features" => []}

  defp coverage_view(
         %{grading: grading, policy: policy, git_facts: %{document: document}} = inputs
       ) do
    if inputs.head == nil do
      %{"version" => grading.index.version, "unmapped_areas" => [], "features" => []}
    else
      mapping = mapping(grading, policy, document)
      driven = driven_features(grading.runs)

      %{
        "version" => grading.index.version,
        "unmapped_areas" => mapping.unmapped,
        "features" =>
          Enum.map(mapping.features, &%{"id" => &1, "driven" => MapSet.member?(driven, &1)})
      }
    end
  end

  defp state([]), do: "mergeable"
  defp state([%{"outcome" => outcome} | _rest]), do: outcome

  defp sort_key(%{"outcome" => outcome, "rule" => rule, "subject" => subject}),
    do: {Enum.find_index(@precedence, &(&1 == outcome)), rule, subject}

  defp reasons(%{head: nil}),
    do: [reason("git_facts_missing", "pending", [], "No Git facts have been reported")]

  defp reasons(%{git_facts: nil, head: head} = inputs) do
    [
      reason(
        "git_facts_missing",
        "pending",
        [head],
        "No Git facts are reported for the head and target branch"
      )
      | workflow_reasons(inputs)
    ]
  end

  defp reasons(%{claims: nil, head: head} = inputs) do
    [
      reason("claims_missing", "pending", [head], "No claims are uploaded for the head")
      | workflow_reasons(inputs) ++ facts_reasons(inputs)
    ]
  end

  defp reasons(inputs),
    do: workflow_reasons(inputs) ++ facts_reasons(inputs) ++ claims_reasons(inputs)

  defp workflow_reasons(%{workflows: workflows, policy: policy}) do
    for name <- policy.effective["evidence"]["required_workflows"],
        reason = workflow_reason(name, Map.get(workflows, name)),
        do: reason
  end

  defp workflow_reason(_name, %{outcome: "passed"}), do: nil

  defp workflow_reason(name, %{outcome: "failed"}),
    do:
      reason(
        "required_workflow_failed",
        "blocked",
        [name],
        "Required workflow #{name} failed on the head"
      )

  defp workflow_reason(name, _missing_or_cancelled),
    do:
      reason(
        "required_workflow_missing",
        "pending",
        [name],
        "Required workflow #{name} has no clean, finished run on the head"
      )

  defp facts_reasons(%{git_facts: %{document: document}, policy: policy}) do
    files = document["diff"]["files"]
    path_reasons(files, policy.globs) ++ size_reasons(files, policy.effective["size"])
  end

  defp path_reasons(files, globs) do
    for {glob, outcome, regex} <- globs,
        outcome != "ignore",
        matched = matched_paths(files, regex),
        matched != [],
        do:
          reason(
            "path_match",
            outcome,
            [glob | matched],
            "The diff touches paths matching #{glob}"
          )
  end

  defp matched_paths(files, regex) do
    files
    |> Enum.flat_map(&[&1["path"], &1["old_path"]])
    |> Enum.filter(&(is_binary(&1) and Glob.match?(regex, &1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp size_reasons(files, size) do
    count = length(files)
    lines = Enum.reduce(files, 0, &(&1["additions"] + &1["deletions"] + &2))
    max_files = size["max_changed_files"]
    max_lines = size["max_changed_lines"]

    files_reason =
      if count > max_files,
        do: [
          reason(
            "max_changed_files",
            "needs_review",
            [],
            "The diff changes #{count} files, more than #{max_files}"
          )
        ],
        else: []

    lines_reason =
      if lines > max_lines,
        do: [
          reason(
            "max_changed_lines",
            "needs_review",
            [],
            "The diff changes #{lines} lines, more than #{max_lines}"
          )
        ],
        else: []

    files_reason ++ lines_reason
  end

  defp claims_reasons(%{claims: %{front_matter: claims}, policy: policy}) do
    settings = policy.effective["claims"]

    door_reason(claims, settings["one_way_door"]) ++
      proof_reason(claims, settings["min_proof_level"]) ++
      open_items_reason(claims, settings["open_items"])
  end

  defp door_reason(%{"door" => "one_way"}, outcome) when outcome in @gated,
    do: [reason("one_way_door", outcome, [], "The claims call this change a one-way door")]

  defp door_reason(_claims, _outcome), do: []

  defp proof_reason(%{"safe_because" => entries}, minimum) do
    floor = rank(minimum)

    case entries |> Enum.filter(&(rank(&1["proof"]) < floor)) |> Enum.map(& &1["fact"]) do
      [] ->
        []

      facts ->
        [
          reason(
            "proof_below_minimum",
            "needs_review",
            Enum.sort(facts),
            "#{length(facts)} safe-because claims are proven below #{minimum}"
          )
        ]
    end
  end

  defp rank(level), do: Enum.find_index(Document.proof_levels(), &(&1 == level))

  defp open_items_reason(%{"left_open" => left_open, "questions" => questions}, outcome)
       when outcome in @gated and (left_open != [] or questions != []) do
    subject = Enum.sort(Enum.map(left_open, & &1["risk"]) ++ Enum.map(questions, & &1["id"]))
    [reason("open_items", outcome, subject, "The claims leave risks or questions open")]
  end

  defp open_items_reason(_claims, _outcome), do: []

  defp reason(rule, outcome, subject, message),
    do: %{"rule" => rule, "outcome" => outcome, "subject" => subject, "message" => message}

  defp digests(%{grading: grading} = inputs) do
    %{
      "git_facts" => hex(inputs[:git_facts]),
      "claims" => hex(inputs[:claims]),
      "required_workflows" =>
        Map.new(inputs.workflows, fn {name, result} -> {name, result && result.run_id} end),
      "approved_intent_digest" =>
        if(grading.intent && grading.intent.approved, do: grading.intent.digest),
      "diff_baseline_digest" => grading.diff && grading.diff[:baseline][:digest],
      "counted_runs" => grading.runs |> Enum.map(& &1.run_id) |> Enum.sort(),
      "feature_index_version" => grading.index && grading.index.version
    }
  end

  defp hex(%{digest: digest}), do: Base.encode16(digest, case: :lower)
  defp hex(nil), do: nil
end
