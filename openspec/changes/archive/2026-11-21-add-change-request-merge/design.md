# Design

## Context

See proposal.md for motivation. Builds on phases 1 to 3. The verdict already records head and policy version; verify runs already carry an optional `merge_result: { base, commit }` (phase 2) that is excluded from branch grading.

## Goals / Non-Goals

**Goals:**
- At most one client merges onto a target branch at a time, if clients cooperate.
- The merged result, not only the branch, has passing evidence when policy asks.
- Policy changes can be judged by defect rates.

**Non-Goals:**
- Merging, pushing, or enforcing that clients take the lease.
- A FIFO merge queue (the API leaves room for one later).
- Dependency graphs beyond a single parent chain.
- Automatic policy tuning or suggestions.

## Decisions

### D1. Lease

```
  client A                         server                       client B
  acquire(CR 42, main, head H) --> open? mergeable at H?
                               <-- lease L1, expires +10m, base reported by A
                                                         <----- acquire(CR 57, main)
                                   409 held by CR 42 until t --> retry later
  heartbeat(L1)                --> expires +10m
  report merged(L1, sha)       --> CR 42 merged, slot free
```

- One row per lease. Acquiring takes a transaction-level advisory lock on the slot `(project, target_branch)`, so two acquires for the same slot serialize and cannot both win; the partial unique index `merge_leases_active_slot_index` on `(project, target_branch)` where `state = 'active'` backs this up with at most one active lease per slot.
- `merge.lease_ttl` is `<n>s`, `<n>m` or `<n>h` from `1m` to `1h` (phase 1 validates it). This phase adds `merge.lease_ttl` and `merge.regrade_merge_result` to `active_settings`.
- The merge report's optional `lease_id` and the `merge.merged_without_lease` flag are defined in phase 1's merge record. Releasing a lease through a merge report does not recompute the verdict: the change request is `merged` and its verdict at merge is stored in `merge`.
- The lease stores the change request, head, base, holder membership and key, and expiry. Heartbeat, release and merge report must name the lease ID; a wrong or expired ID returns `409` for heartbeat and release.
- If the verdict changes away from `mergeable` while a lease is held, the lease stays but the merge-result check fails, and the client sees it in the verdict.

### D2. Merge-result grading

When `regrade_merge_result = true` and the lease's base differs from the `git-facts` merge base, the verdict for the lease holder gains reason `merge_result_ungraded` (`pending`) until a final, clean verify run with `merge_result.base` equal to the lease base, on the current approved set, has every Must passed. A failed Must is `blocked`. This is a requirement on top of the change request's verdict, not a replacement.

Alternative: rebase and push the change request branch. Rejected because answers bind to the head and every rebase would force a full re-review.

### D3. Stacking

```
  main <-- CR 41 (branch a) <-- CR 42 (branch b, parent 41, target a)
  41 open:     42 pending (parent_not_merged); still graded and reviewed
  41 merged:   client retargets 42 to main, reports git-facts vs main
               head unchanged -> answers count
```

- One parent; no cycles (a parent must have a lower number and the same project).
- Retarget is allowed only to the parent's target branch after the parent is merged, or to any branch when the change request has no parent. It recomputes the verdict, which is `pending` with `git_facts_missing` (`subject` `[<head>]`, head kept) until facts for the new target arrive.
- `parent_not_merged` and `parent_closed` use `subject` `[<parent number>]` as a string.
- If the parent was squash or rebase merged, the child's old base commits are no longer on the target; the client must rebase and push, which is a new head.

### D4. Defects and attribution

A defect names a change request number or a commit SHA (40 or 64 lowercase hex, like every SHA in these changes). A SHA is matched against every reported `git-facts` commit of the project's merged change requests; zero matches is stored unattributed, more than one picks the earliest merged. Bisecting to find the causing commit is the client's job. Defects record membership, key, ticket and severity (`low`, `medium`, `high`, `critical`).

### D5. Calibration report

Computed on read from stored data, for a time window:

- Lane: `auto` (merged `mergeable` with no answered items), `reviewed` (at least one answered item), `bypass` (`merge.merged_without_mergeable_verdict` or `merge.merged_without_lease`).
- Per policy version (`merge.policy_version`) and per lane: merged count, defect count, defect rate.
- Per rule (from `merge.reasons`): how often it fired on change requests that later had defects, and defects whose change request had no reasons (gaps).
- Per policy path glob: defects in matched versus unmatched files.

Read-only. Admins change the policy through the CLI.

## Risks / Trade-offs

- [Clients that skip the lease] -> Recorded and reported in the `bypass` lane.
- [409-and-retry is unfair under contention] -> Acceptable for v1; a queue can be added behind the same acquire call.
- [Lease holder dies] -> Expiry frees the slot within `lease_ttl`.

## Migration Plan

New tables and routes. Ship after phase 3 and before the CLI's `cr merge`.
