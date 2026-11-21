defmodule GoodFlows.Review.ItemsTest do
  use ExUnit.Case, async: true

  alias GoodFlows.JsonDocument
  alias GoodFlows.Review.Items

  defp reason(rule, outcome, subject),
    do: %{"rule" => rule, "outcome" => outcome, "subject" => subject, "message" => rule}

  test "each needs_review rule gives the item kind of the table" do
    for {rule, kind} <- [
          {"diff_only_set", "diff_only_set"},
          {"spec_gap", "spec_gap"},
          {"one_way_door", "one_way_door"},
          {"unmapped_area", "unmapped_area"},
          {"undriven_feature", "undriven_feature"},
          {"should_failed", "failed_scenario"},
          {"should_not_run", "not_run"},
          {"proof_below_minimum", "unproven_claim"},
          {"path_match", "sensitive_path"},
          {"max_changed_files", "size"},
          {"max_changed_lines", "size"}
        ] do
      assert [%{kind: ^kind, rule: ^rule, answers: ["approve", "request_change"]}] =
               Items.build([reason(rule, "needs_review", ["x"])], nil)
    end
  end

  test "scenario_set_approval is an item only with a digest; other context is never one" do
    with_digest = reason("scenario_set_approval", "pending", ["5e1c"])
    without = reason("scenario_set_approval", "pending", [])
    missing = reason("required_workflow_missing", "pending", ["ci"])
    must = reason("must_failed", "blocked", ["intent", "S3"])
    door = reason("one_way_door", "blocked", [])

    assert [%{kind: "scenario_set_approval", answers: ["approve", "reject"], subject: ["5e1c"]}] =
             Items.build([with_digest, without, missing, must, door], nil)

    assert {[^without, ^missing], [^must, ^door]} =
             Items.context([with_digest, without, missing, must, door])
  end

  test "open_items splits into questions and open risks with indexed subjects" do
    claims = %{
      "questions" => [%{"id" => "q1"}, %{"id" => "q2"}],
      "left_open" => [%{"risk" => "slow"}, %{"risk" => "slow"}]
    }

    items =
      Items.build([reason("open_items", "needs_review", ["q1", "q2", "slow", "slow"])], claims)

    assert Enum.map(items, &{&1.kind, &1.subject}) == [
             {"question", ["q1"]},
             {"question", ["q2"]},
             {"open_item", ["0", "slow"]},
             {"open_item", ["1", "slow"]}
           ]

    assert hd(items).answers == ["choose", "request_change"]
    [_, _, a, b] = items
    assert a.id != b.id
  end

  test "ids are the rule and the subject's canonical JSON digest, the same at every head" do
    subject = ["app/priv/**", "app/priv/a.exs"]
    hex = Base.encode16(JsonDocument.digest(subject), case: :lower)
    assert Items.id("path_match", subject) == "path_match:" <> hex

    [at_a] = Items.build([reason("path_match", "needs_review", subject)], nil)
    [at_b] = Items.build([reason("path_match", "needs_review", subject)], %{"questions" => []})
    assert at_a.id == at_b.id
  end

  test "resolve clears needs_review only when every item is approved or chosen" do
    items =
      Items.build(
        [
          reason("one_way_door", "needs_review", []),
          reason("max_changed_files", "needs_review", [])
        ],
        nil
      )

    [door, size] = Enum.map(items, & &1.id)

    assert Items.resolve("needs_review", items, %{door => "approve", size => "approve"}) ==
             {"mergeable", %{"items" => 2, "cleared" => 2}}

    assert Items.resolve("needs_review", items, %{door => "approve", size => "request_change"}) ==
             {"needs_review", %{"items" => 2, "cleared" => 1}}

    assert {"blocked", _review} =
             Items.resolve("blocked", items, %{door => "approve", size => "approve"})

    assert {"pending", _review} =
             Items.resolve("pending", items, %{door => "approve", size => "approve"})
  end
end
