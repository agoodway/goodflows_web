# Proposal

## Why

We cannot reliably say how many rounds of fixes a change request took before it merged. Each change request keeps one verdict row, and every recompute overwrites it. The only history is the `verdict_changed` project events, and the retention sweep deletes them after 90 days. Every new head reported in Git facts looks the same, so a rebase or a merge of the target branch counts like a fix. The count matters for calibrating review policy and for seeing where agents struggle. It has to be recorded as work happens: once events age out, we can't reconstruct it.

## What Changes

- **Verdict transitions are kept permanently.** Each recompute that changes a draft or open change request's verdict state, head or policy version appends a row to a new `change_request_verdict_transitions` table. Each row holds `from_state`, `to_state`, `from_head`, `to_head`, `policy_version`, a derived `cause` (`created`, `head`, `policy` or `inputs`) and, for a head change, the new head's `head_kind`. The rows are written in the same transaction and under the same condition as the `verdict_changed` event, and the 90-day sweep does not touch them.
- **Reason spans are kept permanently.** A new `change_request_reason_spans` table holds one row for each time a reason is present in a change request's verdict. A reason is identified by its `rule`, `subject` and `outcome`. A span opens at the recompute where the reason first appears and closes at the one where it disappears. It records the cause of the close and, for a head change, the head kind. A merge or a close closes every open span with `merged` or `closed`. Spans answer which rules block most often and how long each takes to clear. Unlike transitions, they also change when only the reasons change.
- **New heads are classified.** A Git facts report that creates a row records `previous_head` (the change request's head before the report, or null) and `head_kind`. The kind is one of `first`, `fast_forward`, `target_merged`, `rebase`, `rewrite` or `retarget`. It is worked out from the stored Git facts of the previous head and the new document's `commits` and `target.merge_base`. The Git facts read returns both fields.
- **Merges save the count.** A merge report stores `fix_iterations` and `head_count` with the merge, and they never change afterwards. `fix_iterations` counts the head transitions where the verdict left an earlier head at `blocked` or `needs_review` and the new head's kind is `fast_forward` or `rewrite`. `head_count` counts the distinct heads with Git facts. Both are null when the merge was reported before this change. `fix_iterations` is also null when any of the change request's Git facts were reported before this change, because its history is then incomplete.
- No companion CLI change. `cr push`, `cr open` and `cr claims` already send everything the classification needs.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `change-requests`: Git facts reports record and return `previous_head` and `head_kind`. The merge record gains `fix_iterations` and `head_count`. Verdict transitions and reason spans are recorded permanently.

## Impact

- Migration: new `change_request_verdict_transitions` and `change_request_reason_spans` tables; nullable `previous_head` and `head_kind` on `change_request_git_facts`; nullable `merged_fix_iterations` and `merged_head_count` on `change_requests`. No backfill.
- `GoodFlows.ChangeRequests`: `report_git_facts/3` (classification), `recompute/2` (transitions, next to `record_verdict_changed`, and reason spans), `report_merge/3` (counts, closing spans), `transition/3` (closing spans on close).
- `ChangeRequestJSON`, `ChangeRequestMerge` schema and the Git facts OpenAPI schema gain the new fields. All fields are additive, so existing clients are unaffected.
- Coordination: `add-change-request-dashboard` (in progress in another thread) widens when `verdict_changed` fires, to include reason-only changes. Transitions keep today's narrower condition (state, head or policy version), so one change does not depend on the other. Both edit `record_verdict_changed`, so whichever lands second rebases.
- Out of scope: an API route that lists transitions or spans; backfilling from old `verdict_changed` events; changing event retention; telling a fix apart from a rebase that also adds fixes.
