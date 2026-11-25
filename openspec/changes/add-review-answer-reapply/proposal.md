# Proposal

## Why

Answers bind to the head, so every push resets every review item to unanswered, even when the item's `id` and content are unchanged. This is deliberate (`add-change-request-review` D2: "every push is reviewed in full"), and it stays. The cost is friction: on goodflows-test change request 1, both `open_item`s fell back to `0 of 2 cleared` after a push, and the reviewer re-typed each approval with a note naming the earlier one. The packet already knows the earlier answer and the server already stores each head's commits and changed files, but neither the packet nor the dashboard shows them. The dashboard spec even forbids showing an earlier head's answer.

Carrying answers across heads automatically was considered again and rejected. "The item's files did not change" is a weak signal that a risk is unchanged, because a config or caller change elsewhere can change it. A wrongly carried answer would also be silent, so a change request could become mergeable on approvals nobody gave for that code.

## What Changes

- Each packet item gains `earlier_answer`: the latest current answer to the same item `id` at another head. It holds the answer itself, whether it can be re-applied, and `changed_since`: the commits since that head and their changed files, with whether the paths the item points at were touched. `changed_since` is null when the earlier head is not an ancestor of the current head (rebase or rewrite). This is information only. It never counts toward the verdict.
- A new route, `POST .../review/reapply`, records a new answer at the current head for each named item. Each answer copies the earlier `approve` or `choose` answer and names it in `reapplied_from`. It is all-or-nothing, made by the caller's membership, and recomputes the verdict once. Items of kind `scenario_set_approval` and `diff_set_weakened`, earlier `reject` or `request_change` answers, a `choose` whose option is no longer offered, and items already answered at the head cannot be re-applied.
- Answers gain `reapplied_from`, and `answer_recorded` events gain `reapplied_from_head`, so the audit trail shows that a person re-applied an answer and which answer they re-applied.
- The dashboard shows each item's earlier answer and the changed-since summary. It offers a per-item re-apply action and a "Re-apply unchanged" action for re-applicable items whose paths were not touched, both behind a confirm dialog.

The full-review rule does not change: nothing counts at a new head until a person answers there, and re-applying is that answer.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `change-request-review`: items gain `earlier_answer`, answers gain `reapplied_from`, and a new reapply route is added.
- `change-request-dashboard`: the detail page shows earlier answers and offers re-apply actions.
- `project-events`: `answer_recorded` gains `reapplied_from_head`.

## Impact

- Migration: `review_answers.reapplied_from_answer_id` (nullable, references `review_answers`, `on_delete: :nilify_all`).
- `GoodFlows.Review` (packet build, new `reapply/4`), `GoodFlows.Review.Packet`, the review controller and JSON, OpenAPI schemas, and `ChangeRequestLive.Show`.
- Companion CLI change `add-review-answer-reapply` in agoodway/goodflows: `cr review` shows earlier answers, and new commands re-apply one item or all unchanged items.
- Additive API change only: existing clients ignore the new fields, and the answer route does not change.
