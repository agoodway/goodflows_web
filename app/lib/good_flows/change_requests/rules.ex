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
  """

  alias GoodFlows.ReviewPolicies.Document
  alias GoodFlows.ReviewPolicies.Glob

  @precedence ~w(pending blocked needs_review)
  @gated ~w(needs_review blocked)

  @typedoc "A compiled policy: its version, effective document and `paths` regexes."
  @type policy :: %{
          version: non_neg_integer(),
          effective: map(),
          globs: [{String.t(), String.t(), Regex.t()}]
        }

  @typedoc "The newest clean run of a required workflow on the head, or nil."
  @type workflow_result :: %{outcome: String.t(), run_id: String.t()} | nil

  @typedoc "Everything the verdict depends on."
  @type inputs :: %{
          head: String.t() | nil,
          git_facts: %{document: map(), digest: binary()} | nil,
          claims: %{front_matter: map(), digest: binary()} | nil,
          workflows: %{String.t() => workflow_result()},
          policy: policy()
        }

  @typedoc "One reason, as stored and rendered."
  @type reason :: %{String.t() => String.t() | [String.t()]}

  @typedoc "A computed verdict."
  @type verdict :: %{
          state: String.t(),
          head: String.t() | nil,
          policy_version: non_neg_integer(),
          reasons: [reason()],
          inputs: map()
        }

  @doc "Computes the verdict for `inputs`."
  @spec evaluate(inputs()) :: verdict()
  def evaluate(inputs) do
    reasons = inputs |> reasons() |> Enum.sort_by(&sort_key/1)

    %{
      state: state(reasons),
      head: inputs.head,
      policy_version: inputs.policy.version,
      reasons: reasons,
      inputs: digests(inputs)
    }
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

  defp digests(inputs) do
    %{
      "git_facts" => hex(inputs[:git_facts]),
      "claims" => hex(inputs[:claims]),
      "required_workflows" =>
        Map.new(inputs.workflows, fn {name, result} -> {name, result && result.run_id} end)
    }
  end

  defp hex(%{digest: digest}), do: Base.encode16(digest, case: :lower)
  defp hex(nil), do: nil
end
