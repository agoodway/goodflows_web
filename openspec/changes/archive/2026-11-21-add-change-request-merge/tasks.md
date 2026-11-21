# Tasks

## 1. Lease storage and context

- [x] 1.1 Add a migration for `merge_leases` (project, change request, target branch, head, base, holder membership and key, ttl, `state` active/released/expired, `release_reason`, `acquired_at`, `expires_at`) with a partial unique index on `(project_id, target_branch)` where `state = 'active'`; verify `mix ecto.migrate` and rollback succeed
- [x] 1.2 Add the lease schema and changeset (`head` and `base` of 40 or 64 lowercase hex) and verify changeset tests reject a malformed `base`
- [x] 1.3 Implement acquire in one transaction: lock the slot, treat a past-`expires_at` row as expired, check `open`, current head and `mergeable` verdict, return the lease, `slot_taken` with holder, or a same-key retry; verify context tests for every `409` reason and the retry cases
- [x] 1.4 Read `merge.lease_ttl` (`<n>s|<n>m|<n>h`, `1m`..`1h`) from the policy version current at acquire time (default 10 minutes) and verify a `3m` policy yields `expires_at` three minutes later
- [x] 1.5 Implement heartbeat (extend by TTL from now, no cap) and release (`release_reason: "released"`), both `lease_not_active` for unknown, released or expired IDs; verify context tests
- [x] 1.6 Add a concurrency test where two acquires for different change requests on the same branch race and exactly one wins, plus tests that other branches and other projects do not interact
- [x] 1.7 Add `merge.lease_ttl` and `merge.regrade_merge_result` to core's `active_settings` list; verify the policy read test lists both

## 2. Lease expiry job

- [x] 2.1 Add an expiry job that marks every active lease past `expires_at` as `expired` with `UPDATE ... WHERE state = 'active'`, so each lease expires once; verify a test that running it twice expires a lease once
- [x] 2.2 Add a scheduler built on `GoodFlows.Spry.ReaperScheduler` with its own `GoodFlows.Leadership` name, enqueuing the job at least every 60 seconds, and register it in `pgflow_children/1`; verify a scheduler test that only the leader enqueues
- [x] 2.3 Verify that expiry leaves the change request's state unchanged and recomputes its verdict without the merge-result check

## 3. Merge report, close, and `merged_without_lease`

- [x] 3.1 Add the `merged_without_lease` merge column to change requests (migration and schema), served as `merge.merged_without_lease`, and verify the column defaults to false
- [x] 3.2 Accept an optional `lease_id` on the merge report: a valid active lease means leased; anything else sets `merge.merged_without_lease` true; any held lease is released with `release_reason: "merged"` without recomputing the merged verdict; an idempotent retry never re-evaluates the flag; verify tests for leased, omitted, expired and never-leased merges, both flags together, and a retry naming a lease; a non-string `lease_id` gets `422` on `lease_id`
- [x] 3.3 Release a held lease with `release_reason: "closed"` in the close transaction and verify that a later acquire on the same branch responds `201`
- [x] 3.4 Verify that a verdict change away from `mergeable` leaves the lease active and heartbeats still succeed

## 4. Merge-result grading

- [x] 4.1 Add the merge-result check to verdict computation: it applies only with an active lease, `merge.regrade_merge_result = true`, and lease `base` different from the head's `git-facts` `merge_base`; verify tests for base moved, base unchanged and regrading off
- [x] 4.2 Count final, clean verify runs whose `merge_result.base` equals the lease base and whose digest is graded at the head; use the newest result per Must; map to clear, `merge_result_failed` (`blocked`, `subject` `[<source>, <id>]`) or `merge_result_ungraded` (`pending`, `subject` `[<lease base>]`); verify tests for passing, failing, `not_run`, dirty and older-base runs
- [x] 4.3 Recompute the verdict on lease acquire, release (except `release_reason: "merged"`, where the change request is already `merged` and its verdict is frozen), expiry and on upload of a merge-result run; verify a test that a merge-result run does not change the branch scenario rules and that a merge report's release leaves `merge.reasons` and the verdict unchanged

## 5. Parent links and retarget

- [x] 5.1 Add a nullable `parent_id` to change requests and the parent `PUT`/`DELETE` routes (same project, lower number, child `draft` or `open`, `sk_` only); verify controller tests for set, replace, clear, higher number, self, unknown number, merged child and `pk_`
- [x] 5.2 Add the `parent_not_merged` and `parent_closed` verdict rules with `subject` `[<parent number as a string>]`, and recompute every child's verdict when a parent changes state or the link changes; verify tests for parent open, closed, reopened, merged and cleared, with other reasons kept
- [x] 5.3 Add the retarget route: parent's target only after the parent merged, any branch without a parent, `lease_held` while a lease is active, no change to the head, verdict recomputed in the same transaction; verify controller tests for every outcome
- [x] 5.4 After a retarget, rely on core's head-plus-target-branch report identity so a report for the same head on the new target is accepted, and core's `git_facts_missing` (`subject` `[<head>]`, `head` kept) until it arrives; verify tests
- [x] 5.5 Verify that answers, approvals and counted runs at the head survive a retarget, and that an item new from the new facts needs its own answer

## 6. Defects

- [x] 6.1 Add a migration and schema for `defects` (project, nullable change request, commit, `attribution` change_request/commit/unattributed, `severity` enum, `ticket`, membership, key, `recorded_at`); verify migrate and rollback
- [x] 6.2 Validate the defect body (exactly one of `change_request` or `commit` of 40 or 64 lowercase hex, unknown keys rejected, severity values, ticket length) and verify a `422` test per rule
- [x] 6.3 Attribute a commit to the earliest-merged change request whose merged head's `git-facts` commits include it, or store it unattributed; verify tests for one match, several matches, no match and an open-only match
- [x] 6.4 Add `POST` and `GET /api/v1/projects/:project/defects` with keyset paging and `pk_` redaction of `ticket`; verify controller tests for auth, paging and redaction

## 7. Calibration report

- [x] 7.1 Compute lanes (`bypass` from the `merge` flags, then `reviewed`, then `auto`) and per-lane counts and `defect_rate` for the `from`/`to` window (default 90 days, `422` when reversed); verify tests including the 20/5/3 example
- [x] 7.2 Add the per-policy-version breakdown from `merge.policy_version` and verify a test with two versions
- [x] 7.3 Add the per-rule breakdown from `merge.reasons` with `fired_count`, `fired_with_defects_count` and `gaps`; verify tests
- [x] 7.4 Add the per-glob breakdown using the commit's `changed_files` for commit-attributed defects and the merged head's diff otherwise, plus `unmatched_defect_count`; verify tests
- [x] 7.5 Serve `GET /api/v1/projects/:project/calibration` to `sk_` and `pk_` keys and verify a test that reading it and recording defects create no policy version and recompute no verdict

## 8. Events

- [x] 8.1 Insert `lease_acquired`, `lease_renewed`, `lease_expired` and `lease_released` events in the transactions that make each change, with the change request as top-level `number`, the request as `actor` (null for expiry) and the listed `data` fields; verify tests that a rejected heartbeat records nothing and expiry records one event
- [x] 8.2 Insert `defect_recorded` in the defect transaction (top-level `number` the attributed change request or null) and verify that a `422` records nothing
- [x] 8.3 Redact `actor` and `ticket` for `pk_` feed reads and verify tests with both key kinds

## 9. Routes and OpenAPI

- [x] 9.1 Add lease, parent, retarget, defect and calibration routes to the router under the authenticated project pipeline and verify the `401`, `403` (including `ck_` on every new route), `404` and `406` cases in controller tests
- [x] 9.2 Add OpenAPI schemas and operations for every new route, the `409` error values and holder body, the merge report `lease_id`, the change request `parent` and `merge.merged_without_lease`, the defect enums, the report, and the new event types; verify `openapi_test.exs` covers them

## 10. Integration

- [x] 10.1 Add an end-to-end test: CR 41 and child CR 42, CR 41 acquires, grades the merge result, reports merged; CR 42 retargets, reports new facts at the same head, keeps its answers, acquires and merges; a defect by commit attributes to the right change request and shows in the report and feed
- [x] 10.2 Run `mix precommit` in `app/` and fix every failure

## Workflow follow-up

- Archive after `add-change-request-core`, `add-change-request-grading` and `add-change-request-review` are archived, so the `change-requests` and `project-events` main specs exist.
