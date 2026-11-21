# Proposal

## Why

With phases 1 to 3, a change request can reach `mergeable`, but two agents can still merge onto the same base at once, evidence for the branch may not hold for the merged result, small stacked changes have no home, and nobody can tell whether the policy lets defects through. This phase adds a merge slot lease per target branch, grading of the merge result, stacking through a parent link, defect records, and a read-only calibration report. The server still never merges: it coordinates, and clients act.

Depends on `add-change-request-core`, `add-change-request-grading` and `add-change-request-review`.

## What Changes

- Add one merge slot per project and target branch. A client acquires it for a change request that is `open` with a `mergeable` verdict at the head it names. The lease lasts `merge.lease_ttl` (default 10 minutes) and each heartbeat extends it with no overall cap. A taken slot returns `409` with the holder and expiry. No queue in v1. An expired lease frees the slot and leaves the change request `open`. Releasing, reporting a merge, or closing the change request frees it.
- A merge reported after the lease expired, or without one, is recorded and flagged `merge.merged_without_lease`.
- With `merge.regrade_merge_result = true` and a base that moved since grading, a lease holder must upload a passing verify run whose `merge_result` names the current base before the merge-result check passes. The merge result is built by the client as a merge commit or temporary ref and never pushed to the change request branch, so the head and its answers stay the same.
- A change request may name one parent change request. While the parent is not merged, the child's verdict is `pending` with reason `parent_not_merged`. Closing the parent makes it `pending` with `parent_closed`. After the parent merges, the client retargets the child to the parent's target (a record update, not a push) and reports new Git facts; answers at an unchanged head still count.
- Accept defect records that name a change request number or any commit SHA, with optional ticket and severity. A commit is mapped to the change request whose reported `git-facts` commits include it.
- Serve a read-only calibration report: merged change requests and defects by lane (auto-merged, human-reviewed, merged without a mergeable verdict or lease), by policy version, by rule that fired, and by path glob. The server never changes the policy.
- Add `lease_acquired`, `lease_renewed`, `lease_expired`, `lease_released` and `defect_recorded` events, with the phase 3 event shape (top-level `number` and `actor`).
- Make `merge.lease_ttl` (a duration from `1m` to `1h`) and `merge.regrade_merge_result` active policy settings.

## Capabilities

### New Capabilities

- `merge-coordination`: merge slot leases and merge-result grading.
- `review-calibration`: defect records and the calibration report.

### Modified Capabilities

- `change-requests`: parent links, retargeting, and the `parent_not_merged`, `parent_closed` reasons; `merged_without_lease`.
- `project-events`: lease and defect events.

## Impact

- New tables for leases and defects. Lease expiry runs in a periodic job that uses the existing `GoodFlows.Leadership` so only one node expires leases.
- Companion CLI change: `cr merge` (acquire, build merge result, grade if required, heartbeat, push to host, report merged, release), `cr retarget`, `cr defect`, `policy calibration`.
- The CLI should merge stacked parents with a merge commit by default, because a squash or rebase merge rewrites commits and forces a full re-review of the child.
