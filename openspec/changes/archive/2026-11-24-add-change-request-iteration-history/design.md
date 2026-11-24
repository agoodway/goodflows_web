# Design

## Context

See proposal.md. Today `report_git_facts/3` stores a row per (change request, head, target branch) and moves `head`; `recompute/2` overwrites the single `change_request_verdicts` row and, through `record_verdict_changed/4`, writes a `verdict_changed` project event when state, head or policy version changed; `report_merge/3` copies the verdict onto the change request. Project events are swept after 90 days (`ProjectEvents.sweep/1`).

## Goals / Non-Goals

**Goals:**
- A merged change request carries a fix-iteration count that needs no joins and does not decay.
- The raw history behind the count (transitions, head kinds) is kept, so other definitions can be computed later.
- No CLI change and no change to existing fields.

**Non-Goals:**
- An API route listing transitions. The dashboard change can add one later.
- Backfilling from existing `verdict_changed` events.
- Detecting a rebase that also changed the code; it is classified `rewrite`.

## Decisions

### D1. Transitions are a table next to the event, not a longer retention

`change_request_verdict_transitions` (`id`, `change_request_id` on delete cascade, `from_state`, `to_state`, `from_head`, `to_head`, `policy_version`, `cause`, `head_kind`, `inserted_at`; index on `(change_request_id, inserted_at)`). It is written next to `record_verdict_changed/4`, in the same transaction and under the same condition as the event, so the two never disagree.

Alternative considered: exempt `verdict_changed` from the sweep. Rejected because the feed's retention is part of the `project-events` contract (`410` on a stale cursor), and events carry no `cause` or `head_kind`.

`add-change-request-dashboard` widens the event condition to reason-only changes. Transitions keep the narrower condition; if that change lands first, the transition next to `record_verdict_changed/4` is still written only when state, head or policy version changed.

### D2. `cause` is derived, `head_kind` is passed in

`cause` follows from comparing the previous and new verdict: no previous verdict is `created`; a different head is `head`; else a different policy version is `policy`; else `inputs` (workflow or verify runs, claims, answers, parent, lease). `recompute/2` gains an option `head_kind:` that only `report_git_facts_locked/3` passes, with the kind of the row it just created (nil for a retry). Splitting `inputs` further would need every caller to name itself; nothing here needs it.

### D3. Head classification uses stored facts only

In `report_git_facts_locked/3`, before `put_head/2`, the previous head is the locked change request's `head`. Its facts are loaded for the current `target_branch`, falling back to the newest row for that head. The rules in the spec delta are evaluated in order (`first`, `retarget`, `fast_forward`, `target_merged`, `rebase`, `rewrite`). Commit membership is `previous_head in Enum.map(commits, & &1["sha"])`. The `rebase` check compares per-commit `changed_files` path lists; it is cheap because both documents are already loaded and bounded (1,000 commits).

The kind is stored on the new `change_request_git_facts` row (`previous_head`, `head_kind`, both nullable for old rows), so it is fixed at report time and re-reporting an earlier head does not reclassify it.

### D4. The count is computed at merge and stored

`report_merge/3` computes, in its transaction:

```sql
SELECT count(*) FROM change_request_verdict_transitions t
WHERE t.change_request_id = $1 AND t.cause = 'head'
  AND t.head_kind IN ('fast_forward', 'rewrite')
  AND EXISTS (SELECT 1 FROM change_request_verdict_transitions g
              WHERE g.change_request_id = $1 AND g.to_head = t.from_head
                AND g.to_state IN ('blocked', 'needs_review')
                AND g.inserted_at < t.inserted_at)
```

and `head_count` as `count(DISTINCT head)` over its Git facts. `fix_iterations` is null when any Git facts row has a null `head_kind`. Both go in `merged_fix_iterations` and `merged_head_count`, written by `ChangeRequest.merge_changeset/2` with the other `merged_*` columns.

Counting a head as a fix when its predecessor was *ever* `blocked` or `needs_review` (not only at the moment it was replaced) covers the common case where the verdict at the old head went back to `pending` (a CI rerun) before the agent pushed its fix. `target_merged` and `rebase` are excluded because they bring in other people's work, not a fix.

### D5. Reason spans diff the new reasons against open spans

`change_request_reason_spans` (`id`, `change_request_id` on delete cascade, `rule`, `subject` text[], `outcome`, `opened_head`, `opened_policy_version`, `opened_at`, `inherited` boolean, `closed_head`, `closed_at`, `close_cause`, `close_head_kind`; an index on `(change_request_id, opened_at)` and a partial index on `change_request_id` where `closed_at IS NULL`). In `recompute/2`, after the verdict is stored, the new verdict's reasons are keyed by `{rule, subject, outcome}` and compared with the change request's open spans. A new key opens a span, and an open span whose key is gone is closed with the cause derived as in D2 (`head`, `policy` or `inputs`) and, for `head`, the head kind.

Spans are compared with the open spans, not with the previous verdict's reasons. A reopen therefore opens fresh spans after a close closed them all, and the comparison never depends on a verdict that was not tracked.

The `cause` of a recompute that changed only the reasons is `inputs`. Transitions do not fire in that case, so spans are the only record of it. This is intended: transitions follow the verdict state, and spans follow reasons.

`report_merge/3` closes every open span with `merged` and the merged head, and `transition/3` closes them with `closed` when it moves to `closed`. Spans still open at merge are the reasons a merge without a mergeable verdict went past. Calibration can use them later.

Decisions on the open points:

- **An answer does not close a span.** `Items.resolve/3` changes only the verdict state and the review counts; the reason stays in `verdict.reasons`. A span measures how long the reason was present, not when a person resolved it. Review wait time is derived from `review_answers`. An item's `id` is `<rule>:<sha256 of the subject>`, so an answer joins to the span with the same rule and subject. A `resolved_at` on the span is rejected for three reasons. Answers are bound to a head, so a new head would unresolve them. Answers can be superseded. One `open_items` reason splits into several items. A single timestamp would hide all three.
- **A change of outcome closes and reopens.** The key includes `outcome`. A policy that moves `path_match` from `needs_review` to `blocked` closes the `needs_review` span with `policy` and opens a `blocked` span, so each row has a single outcome and durations per outcome are a plain sum.
- **Reasons from before this change are inherited.** On the first recompute after deploy of a change request that has a stored verdict but no spans, the spans opened for keys already in the stored verdict get `inherited` true and `opened_at` that recompute's time, so their durations are lower bounds. Nothing is backfilled.
- **`fix_iterations` does not use spans.** It stays as D4 defines it.

Some subjects include the head, for example `claims_missing` with `[head]`. Such a reason closes and reopens on every head change, which is correct: it is a different missing file.

## Risks / Trade-offs

- A span row is written per reason appearance. A change request with many `spec_gap` or `unmapped_area` subjects that churn between heads writes many rows. They are small and bounded by the reasons each verdict already stores.

- A rebase that resolves conflicts changes per-commit files and is classified `rewrite`, so it counts as a fix. Accepted; the raw kind is kept for later refinement.
- A squash of fix commits into one is `rewrite` and counts once, which matches the intent.
- Rows grow by one per verdict change. That is bounded by the number of recomputes that change state, head or policy, which today already write an event.
- Change requests open when this ships have partial history; their `fix_iterations` is null rather than wrong.
