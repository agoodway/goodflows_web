defmodule GoodFlows.Review.Items do
  @moduledoc """
  Turns a stored verdict's reasons into review packet items (design D1),
  and resolves a `needs_review` verdict with the answers at the head
  (design D2). Pure: it reads only its arguments.

  Every `needs_review` reason gives one item, of the kind fixed by its
  rule (`@kinds`), except `open_items`, which is split into one `question`
  item per claims question (subject `[question id]`) and one `open_item`
  per `left_open` entry (subject `[index, risk]`, the index as a decimal
  string). A `scenario_set_approval` reason (outcome `pending`) is an item
  only when its subject names a digest. Every other `pending` and
  `blocked` reason is context only.

  An item's `id` is `<rule>:<digest>`, the digest being the lowercase hex
  SHA-256 of the canonical JSON of its subject
  (`GoodFlows.JsonDocument.digest/1`), so the same rule and subject give
  the same `id` at every head.
  """

  alias GoodFlows.JsonDocument

  @kinds %{
    "diff_only_set" => "diff_only_set",
    "diff_set_weakened" => "diff_set_weakened",
    "spec_gap" => "spec_gap",
    "one_way_door" => "one_way_door",
    "unmapped_area" => "unmapped_area",
    "undriven_feature" => "undriven_feature",
    "should_failed" => "failed_scenario",
    "should_not_run" => "not_run",
    "proof_below_minimum" => "unproven_claim",
    "path_match" => "sensitive_path",
    "max_changed_files" => "size",
    "max_changed_lines" => "size"
  }

  @item_kinds ~w(scenario_set_approval diff_only_set diff_set_weakened failed_scenario not_run
                 spec_gap one_way_door unproven_claim open_item question sensitive_path size
                 unmapped_area undriven_feature)

  @clearing ~w(approve choose)

  @typedoc "One packet item, before its data and answer are attached."
  @type item :: %{
          id: String.t(),
          kind: String.t(),
          rule: String.t(),
          subject: [String.t()],
          message: String.t(),
          answers: [String.t()]
        }

  @doc "Every item kind."
  @spec kinds() :: [String.t()]
  def kinds, do: @item_kinds

  @doc "The answer kinds an item of `kind` allows."
  @spec answers(String.t()) :: [String.t()]
  def answers("scenario_set_approval"), do: ["approve", "reject"]
  def answers("diff_set_weakened"), do: ["approve", "reject"]
  def answers("question"), do: ["choose", "request_change"]
  def answers(_kind), do: ["approve", "request_change"]

  @doc """
  The items of `reasons` (in reason order), with the claims front matter
  at the head (or nil) to split `open_items`.
  """
  @spec build([map()], map() | nil) :: [item()]
  def build(reasons, claims), do: Enum.flat_map(reasons, &items(&1, claims || %{}))

  defp items(%{"rule" => "scenario_set_approval", "subject" => [_digest]} = reason, _claims),
    do: [item(reason, "scenario_set_approval", reason["subject"])]

  defp items(%{"outcome" => "needs_review", "rule" => "open_items"} = reason, claims) do
    questions = for q <- claims["questions"] || [], do: item(reason, "question", [q["id"]])

    open =
      for {entry, index} <- Enum.with_index(claims["left_open"] || []),
          do: item(reason, "open_item", [Integer.to_string(index), entry["risk"]])

    questions ++ open
  end

  defp items(%{"outcome" => "needs_review", "rule" => rule} = reason, _claims) do
    case Map.fetch(@kinds, rule) do
      {:ok, kind} -> [item(reason, kind, reason["subject"])]
      :error -> []
    end
  end

  defp items(_reason, _claims), do: []

  defp item(reason, kind, subject) do
    %{
      id: id(reason["rule"], subject),
      kind: kind,
      rule: reason["rule"],
      subject: subject,
      message: reason["message"],
      answers: answers(kind)
    }
  end

  @doc "The item id of `rule` and `subject`."
  @spec id(String.t(), list()) :: String.t()
  def id(rule, subject),
    do: rule <> ":" <> Base.encode16(JsonDocument.digest(subject), case: :lower)

  @doc """
  The `pending` and `blocked` reasons that are not items, as
  `{pending, blocked}`.
  """
  @spec context([map()]) :: {[map()], [map()]}
  def context(reasons) do
    reasons
    |> Enum.reject(&match?(%{"rule" => "scenario_set_approval", "subject" => [_digest]}, &1))
    |> Enum.filter(&(&1["outcome"] in ~w(pending blocked)))
    |> Enum.split_with(&(&1["outcome"] == "pending"))
  end

  @doc """
  Resolves the computed verdict `state` with the current answers at the
  head (`%{item_id => answer}`): a `needs_review` verdict whose every item
  has `approve` or `choose` is `mergeable`; any other state is kept.
  Returns the state and `%{"items" => n, "cleared" => n}`. A
  `scenario_set_approval` answer clears no item itself.
  """
  @spec resolve(String.t(), [item()], %{String.t() => String.t()}) :: {String.t(), map()}
  def resolve(state, items, answers) do
    reviewable = Enum.reject(items, &(&1.kind == "scenario_set_approval"))
    cleared = Enum.count(reviewable, &(Map.get(answers, &1.id) in @clearing))

    state =
      if state == "needs_review" and cleared == length(reviewable),
        do: "mergeable",
        else: state

    {state, %{"items" => length(items), "cleared" => cleared}}
  end
end
