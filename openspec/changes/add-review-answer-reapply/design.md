# Design

## Context

See proposal.md. Today `GoodFlows.Review.packet/1` builds items with `Items.build/2`, attaches `data` through `Packet` and the current answer from `current_answers/1`, which keeps only answers where `head` is the current head and `superseded_at` is null (`review.ex` `current_query/1`). `answer/4` checks and stores one answer under the change request's row lock, supersedes the item's earlier answer at the same head, records `answer_recorded`, and recomputes. Git facts rows are immutable per (change request, head, target branch). Each holds `commits` (oldest first, ending at `head`) with per-commit `changed_files`.

## Goals / Non-Goals

**Goals:**
- A reviewer sees, on every item, what they or a colleague decided at an earlier head and whether the item's code moved since.
- Re-answering untouched items takes one action, and every answer still comes from a person at this head.
- The audit trail shows that an answer was re-applied, by whom, and from which answer.

**Non-Goals:**
- Counting an earlier answer automatically, under any condition. The `A new head starts a full review` requirement does not change.
- Re-applying `scenario_set_approval` or `diff_set_weakened` answers. Their decisions bind to a digest and already carry while the digest is unchanged.
- Re-applying `reject` or `request_change`. Those create tasks, and copying one would create a second task for the same request.
- A semantic diff of the item's content. Only path-level change is reported.

## Decisions

### D1. The earlier answer is the latest current answer at any other head

`earlier_answers/1` runs one query: answers of the change request with `superseded_at` null and `head` distinct from the current head (null-safe), then `DISTINCT ON (item_id) ... ORDER BY item_id, inserted_at DESC`. Items are matched by `id`, which is stable for the same rule and subject (spec: `Item IDs are rule plus subject digest`).

"Latest at any head" rather than "the previous head" covers a push that briefly removed an item and a re-report of an older head. Alternative considered: walk `previous_head` links back to the nearest head with an answer. Rejected because the links do not exist for older rows, and they say nothing the timestamps don't.

### D2. `changed_since` uses only the current head's stored facts

The current head's facts row is the one `Packet` already loads. With `shas = Enum.map(commits, & &1["sha"])`, the earlier head is an ancestor when it is in `shas`. The later commits are the ones after its index, and `files` is the union of their `changed_files` `path` and `old_path`. This is the same membership rule the diff-set revision check uses (`change-requests`: `A diff version names head H`), so a rebase or rewrite gives null rather than a guess. A merge of the target into the branch counts as one later commit whose changed files include the target's changes. That overstates the change, which is the safe direction for an informational flag.

`item_paths`: for `open_item`, the `location` from `Packet`'s data with `~r/:\d+(-\d+)?$/` stripped. For `sensitive_path`, the subject's matched files. Every other kind gets null: a one-way door, a question or a size limit has no single place to point at, and inventing one would make "Unchanged" mean less.

### D3. Reapply is its own route, not a flag on the answer route

`POST .../review/reapply` with `item_ids` lets the dashboard and the CLI re-apply a reviewed set in one transaction with one recompute and one `409` check. A flag on the per-item answer route would need N requests, N recomputes, and could leave half the set applied when the head moves mid-way. The answer route keeps its body and its unknown-key `422`.

`Review.reapply/4` takes the row lock (`ChangeRequests.lock_active/1`) and checks the head. It rebuilds the packet's items, current answers and earlier answers inside the lock, so eligibility is decided on the same state it writes. It then validates every id (collecting `item_ids[i]` errors) and only then inserts. The inserts reuse `answer_locked/4`'s internals (supersede is a no-op because eligibility requires no answer at the head, plus insert and event) through a private helper that takes a `reapplied_from` answer and skips `recompute/1`. A single `ChangeRequests.recompute/1` runs at the end.

### D4. `reapplied_from_answer_id` is a self-reference

The migration adds `review_answers.reapplied_from_answer_id` with `references(:review_answers, on_delete: :nilify_all)`. Answers are never deleted today, but nilify keeps a future cleanup from cascading into answers that still count. The JSON renders `reapplied_from` by preloading that answer and its `account_user`. The copied `note` stays on the new row so readers that ignore `reapplied_from` still see the reason.

### D5. Dashboard

`ChangeRequestLive.Show` renders `earlier_answer` under each item: one muted line for the answer, and one for `changed_since`. It adds a `Re-approve` / `Re-choose <option>` button when `reapplicable` is true and `may_answer?/3` allows. The panel's `actions` slot gets `Re-apply unchanged (n)`. Both open the existing answer dialog in a `reapply` mode that lists the covered items. Confirming calls `Review.reapply/4` with channel `dashboard` and the shown head, and handles `{:stale_head, _}` with the existing flash.

## Risks / Trade-offs

- **Rubber-stamping.** One button makes approval easy. Mitigations: the bulk action only offers items whose paths did not change, the dialog lists what is approved and from whom, and `reapplied_from` makes re-applied approvals countable for `review-calibration` later.
- **Path-level change misses indirect effects.** "Unchanged since" is labelled as path-level. Nothing counts automatically, so a wrong label still requires a person to confirm.
- **Kinds without paths never count as unchanged.** `question`, `one_way_door`, `size` and other kinds without paths always have `item_paths_changed` null, so "Re-apply unchanged" and the CLI's `cr reapply --untouched` never pick them. Reviewers name them one by one. This is intended: there is no path-level signal for them.
- **Packet cost.** One extra indexed query per packet read. Add an index on `review_answers (change_request_id, item_id, inserted_at DESC) WHERE superseded_at IS NULL` if the plan shows a sequential scan.

## Migration Plan

Additive: one nullable column and an optional partial index. Old answers render `reapplied_from: null`, and old events lack `reapplied_from_head`. Readers treat a missing key as null, and the spec requires the key only for events stored after this change. Rollback drops the column.

## Open Questions

None blocking. The CLI command names are decided in the companion change in agoodway/goodflows.
