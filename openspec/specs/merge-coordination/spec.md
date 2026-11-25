# merge-coordination Specification

## Purpose

Coordinates merges onto a target branch through one leased merge slot per project and target branch, and requires passing evidence for the merge result when the base moved since grading. The server never merges; clients hold the lease while they merge on their Git host.

## Requirements

### Requirement: One merge slot per project and target branch

Each project SHALL have at most one active merge lease per target branch. Two acquires for the same project and target branch MUST NOT both succeed, even when they arrive at the same time. Leases on different target branches, or on the same branch name in different projects, MUST NOT affect each other.

#### Scenario: Concurrent acquires on one branch

- **WHEN** two clients acquire a lease at the same time, one for CR 42 and one for CR 57, both targeting `main` in project `goodcases`
- **THEN** exactly one request responds `201` and the other responds `409`

#### Scenario: Different target branches

- **WHEN** CR 42 targeting `main` holds a lease and a client acquires a lease for CR 58 targeting `release/1.2` in the same project
- **THEN** the API responds `201` for CR 58

#### Scenario: Same branch in another project

- **WHEN** CR 42 of project `goodcases` holds a lease on `main` and a client acquires a lease for CR 3 targeting `main` in project `goodflows`
- **THEN** the API responds `201` for CR 3

### Requirement: Lease routes require a private key and a project

`POST /api/v1/projects/:project/change-requests/:number/merge-lease`, `POST /api/v1/projects/:project/merge-leases/:lease_id/heartbeat` and `DELETE /api/v1/projects/:project/merge-leases/:lease_id` SHALL require a valid `sk_` key of the project's account. Missing, expired or revoked keys MUST return `401`, `pk_` and `ck_` keys `403`, an unknown project or change request `404`. Any `sk_` key of the account that names a lease ID MAY heartbeat or release it.

#### Scenario: Public key cannot acquire

- **WHEN** a client with a `pk_` key posts to `/api/v1/projects/goodcases/change-requests/42/merge-lease`
- **THEN** the API responds `403` and no lease is created

#### Scenario: Cache key cannot heartbeat

- **WHEN** a client with a `ck_` key bound to project `goodcases` heartbeats an active lease of that project
- **THEN** the API responds `403` and the lease's `expires_at` is unchanged

#### Scenario: Unknown change request

- **WHEN** a client with an `sk_` key acquires a lease for CR 999 in a project whose highest number is 60
- **THEN** the API responds `404` and no lease is created

#### Scenario: Revoked key cannot heartbeat

- **WHEN** a client with a revoked key heartbeats an active lease
- **THEN** the API responds `401` and the lease's `expires_at` is unchanged

#### Scenario: Another member's key releases a lease

- **WHEN** CR 42 holds lease `L1` acquired with Ada's `sk_` key and a client with Ben's `sk_` key on the same account deletes `L1`
- **THEN** the API responds `204` and the slot is free

### Requirement: Acquiring a lease requires an open, mergeable change request at the named head

An acquire body SHALL carry `head` and `base`, each a SHA of 40 or 64 lowercase hex characters; `base` is the target branch commit the client will merge onto. A missing or malformed value MUST return `422` on that field. The change request MUST be `open` (else `409` `not_open`), `head` MUST equal its last reported head (else `409` `stale_head`), and its verdict MUST be `mergeable` (else `409` `not_mergeable` with the verdict `state`).

#### Scenario: Acquire succeeds

- **WHEN** CR 42 is `open`, its head is `a1b2c3d` with verdict `mergeable`, and a client posts `{"head": "a1b2c3d…", "base": "9f8e7d6…"}` to its merge-lease route while `main` has no active lease
- **THEN** the API responds `201` with `id`, `change_request: 42`, `target_branch: "main"`, `head`, `base`, `state: "active"`, `acquired_at`, and `expires_at` ten minutes after `acquired_at` under the default policy

#### Scenario: Draft change request

- **WHEN** CR 42 is `draft` with a `mergeable` verdict and a client acquires a lease for it
- **THEN** the API responds `409` with `error: "not_open"` and no lease is created

#### Scenario: Head moved

- **WHEN** CR 42's last reported head is `b2c3d4e` and a client acquires with `head` `a1b2c3d`
- **THEN** the API responds `409` with `error: "stale_head"` and the current `head` `b2c3d4e`

#### Scenario: Verdict needs review

- **WHEN** CR 42 is `open` at the named head with verdict `needs_review`
- **THEN** the API responds `409` with `error: "not_mergeable"` and `state: "needs_review"`

#### Scenario: Malformed base

- **WHEN** a client acquires with `base` `main`
- **THEN** the API responds `422` with an error on `base` and no lease is created

### Requirement: A lease lasts the policy's lease TTL

A new lease SHALL expire `merge.lease_ttl` after it is acquired, using the policy version current at acquire time; the default is 10 minutes. The lease SHALL store the change request, head, base, target branch, the holder's membership and key, and `expires_at`.

#### Scenario: Custom TTL

- **WHEN** the project's current policy sets `merge.lease_ttl = "3m"` and a client acquires a lease at `12:00:00Z`
- **THEN** the lease's `expires_at` is `12:03:00Z`

### Requirement: A taken slot returns 409 with the holder and expiry

When the slot for the change request's project and target branch holds an active, unexpired lease, an acquire SHALL return `409` with `error: "slot_taken"`, `holder.change_request` (its number) and `holder.expires_at`. The response MUST NOT include the holder's lease ID. No request is queued. A retry by the same key for the change request that already holds the lease MUST return `200` with that lease.

#### Scenario: Slot held by another change request

- **WHEN** CR 42 holds an active lease on `main` until `12:10:00Z` and a client acquires a lease for CR 57 targeting `main`
- **THEN** the API responds `409` with `error: "slot_taken"`, `holder.change_request: 42`, `holder.expires_at: "…T12:10:00Z"`, and no `id`

#### Scenario: Retry by the holder

- **WHEN** CR 42 holds lease `L1` acquired with key K and a client with key K acquires again for CR 42 with the same `head`
- **THEN** the API responds `200` with lease `L1` and its `expires_at` is unchanged

#### Scenario: Retry with a different key

- **WHEN** CR 42 holds lease `L1` acquired with key K and a client with another key acquires for CR 42
- **THEN** the API responds `409` with `error: "slot_taken"` and `holder.change_request: 42`

### Requirement: An acquire that keeps losing races reports the current state

An acquire whose slot moves between reading the change request and locking it (a concurrent retarget, or a slot holder that changes) SHALL be retried. When every attempt loses such a race, the API SHALL re-read the change request and return `409` `not_open` or `stale_head` for its current state, else `slot_taken`.

#### Scenario: Retargeted on every attempt

- **WHEN** CR 57 is `open` at the named head and is retargeted concurrently with each attempt of an acquire, and its current target branch has no active lease
- **THEN** the API responds `409` with `error: "slot_taken"` and no `holder`

#### Scenario: Closed or moved head during the races

- **WHEN** CR 57 is retargeted concurrently with each attempt of an acquire and, by the last, is `closed` or has a new head
- **THEN** the API responds `409` with `error: "not_open"`, or `error: "stale_head"` with the current `head`

### Requirement: The holder after lost races is a live lease of another client

When an acquire answers from the re-read change request after losing every race, `holder` MUST be present only when its current slot has an active, unexpired lease. When that lease is the caller's own (same key, change request and head), the API MUST return `200` with it.

#### Scenario: Expired or own lease on the final branch

- **WHEN** CR 57 is retargeted concurrently with each attempt of an acquire onto a branch whose only active lease is past `expires_at`, or is its own lease taken with the same key at the same head
- **THEN** the API responds `409` with `error: "slot_taken"` and no `holder`, or `200` with that lease

### Requirement: A heartbeat extends a lease

`POST /api/v1/projects/:project/merge-leases/:lease_id/heartbeat` on an active, unexpired lease SHALL set `expires_at` to the time of the heartbeat plus the lease's TTL and respond `200` with the lease. There is no overall cap on how long heartbeats keep a lease. A heartbeat naming an unknown, released or expired lease ID MUST return `409` with `error: "lease_not_active"`.

#### Scenario: Heartbeat extends

- **WHEN** lease `L1` with a 10-minute TTL expires at `12:10:00Z` and a heartbeat arrives at `12:08:00Z`
- **THEN** the API responds `200` with `expires_at` `12:18:00Z`

#### Scenario: Heartbeats past the first hour

- **WHEN** a client has heartbeated lease `L1` every 5 minutes for 2 hours
- **THEN** the next heartbeat responds `200` and extends `expires_at` by the TTL

#### Scenario: Heartbeat after expiry

- **WHEN** lease `L1` expired at `12:10:00Z` and a heartbeat for `L1` arrives at `12:10:30Z`, before the expiry job ran
- **THEN** the API responds `409` with `error: "lease_not_active"` and `expires_at` is unchanged

#### Scenario: Wrong lease ID

- **WHEN** a client heartbeats lease ID `7c0e5a1e-0000-4000-8000-000000000000`, which names no lease of the project
- **THEN** the API responds `409` with `error: "lease_not_active"`

### Requirement: Releasing a lease frees the slot

`DELETE /api/v1/projects/:project/merge-leases/:lease_id` on an active, unexpired lease SHALL mark it `released` with `release_reason: "released"`, free the slot, leave the change request in its state, and respond `204`. Releasing an unknown, released or expired lease ID MUST return `409` with `error: "lease_not_active"`.

#### Scenario: Release then acquire

- **WHEN** CR 42 releases lease `L1` on `main` and a client then acquires a lease for CR 57 targeting `main`
- **THEN** the release responds `204`, CR 42 stays `open`, and the acquire responds `201`

#### Scenario: Release twice

- **WHEN** a client releases lease `L1` a second time
- **THEN** the API responds `409` with `error: "lease_not_active"`

### Requirement: A merge report naming the lease frees the slot

A merge report for a change request SHALL accept an optional `lease_id`. When it names the change request's active, unexpired lease, the merge is recorded as leased and the lease becomes `released` with `release_reason: "merged"`. A merge report for a change request that holds an active lease MUST release that lease with `release_reason: "merged"` whether or not it names it.

#### Scenario: Leased merge

- **WHEN** CR 42 holds active lease `L1` and the client reports CR 42 merged with `lease_id` `L1` and merged commit `c3d4e5f`
- **THEN** CR 42 becomes `merged` with `merge.merged_without_lease` false, `L1` is `released` with `release_reason: "merged"`, and the slot on `main` is free

#### Scenario: Merge report omits the held lease

- **WHEN** CR 42 holds active lease `L1` and the client reports CR 42 merged without `lease_id`
- **THEN** CR 42 becomes `merged` with `merge.merged_without_lease` true and `L1` is `released` with `release_reason: "merged"`

#### Scenario: Merge release keeps the merged verdict

- **WHEN** CR 42's verdict at merge is `pending` with `merge_result_ungraded` and the merge report releases its lease
- **THEN** the verdict is not recomputed, and `merge.verdict_state` is `pending` with `merge_result_ungraded` in `merge.reasons`

### Requirement: Closing a change request frees its slot

When a change request that holds an active lease moves to `closed`, the lease SHALL become `released` with `release_reason: "closed"` in the same transaction, and the slot MUST be free.

#### Scenario: Close while holding the lease

- **WHEN** CR 42 holds active lease `L1` on `main` and a client closes CR 42
- **THEN** `L1` is `released` with `release_reason: "closed"` and an acquire for CR 57 targeting `main` responds `201`

### Requirement: Expired leases free the slot

A lease past its `expires_at` SHALL NOT hold the slot: an acquire on that slot MUST succeed as if it were free. A periodic job, run by one node of the cluster at a time at least every 60 seconds, SHALL mark every active lease past its `expires_at` as `expired`. Expiry MUST leave the change request's state unchanged, and each lease MUST expire exactly once.

#### Scenario: Holder stops heartbeating

- **WHEN** lease `L1` for CR 42 expires at `12:10:00Z` and no heartbeat arrives
- **THEN** by `12:11:00Z` `L1` is `expired` and CR 42 is still `open`

#### Scenario: Acquire before the job runs

- **WHEN** lease `L1` on `main` expired at `12:10:00Z`, the expiry job has not run, and a client acquires for CR 57 targeting `main` at `12:10:05Z`
- **THEN** the API responds `201` for CR 57 and `L1` is `expired`

#### Scenario: Two nodes running

- **WHEN** two application nodes are running and lease `L1` passes its `expires_at`
- **THEN** `L1` is marked `expired` once and exactly one `lease_expired` event is recorded for it

### Requirement: A held lease survives a verdict change

A verdict that changes away from `mergeable` while a lease is held SHALL NOT release or expire the lease. The lease stays active until heartbeats stop, it is released, the merge is reported, or the change request is closed; the client reads the changed verdict.

#### Scenario: Required workflow fails while leased

- **WHEN** CR 42 holds active lease `L1` and a failed run of a required workflow is uploaded for its head
- **THEN** `L1` is still `active`, a heartbeat on `L1` responds `200`, and CR 42's verdict is `blocked`

### Requirement: Merge-result grading is required when the base moved

While a change request holds an active lease, the current policy sets `merge.regrade_merge_result = true`, the lease's `base` differs from the `merge_base` of the head's `git-facts` report, and the verdict grades at least one scenario set at the head, the verdict SHALL include the merge-result check. Otherwise the check MUST NOT apply, so a change request graded without scenario sets, such as one under policy version 0 with no set uploaded, is never held for a merge-result run it cannot have. The check adds to the verdict's other rules and never replaces them.

#### Scenario: Base moved

- **WHEN** CR 42's verdict grades an intent set, its `git-facts` names `merge_base` `9f8e7d6`, regrading is on, and CR 42 acquires a lease with `base` `0a1b2c3`
- **THEN** CR 42's verdict becomes `pending` with a reason whose `rule` is `merge_result_ungraded`

#### Scenario: Base moved without a scenario set

- **WHEN** CR 42 is `mergeable` under policy version 0 with no scenario set, its `git-facts` names `merge_base` `9f8e7d6`, and CR 42 acquires a lease with `base` `0a1b2c3`
- **THEN** CR 42's verdict stays `mergeable` with no reasons

#### Scenario: Base unchanged

- **WHEN** CR 42's `git-facts` names `merge_base` `9f8e7d6` and CR 42 acquires a lease with `base` `9f8e7d6`
- **THEN** CR 42's verdict stays `mergeable`

#### Scenario: Regrading off

- **WHEN** the current policy sets `merge.regrade_merge_result = false` and CR 42 acquires a lease with a base different from its `merge_base`
- **THEN** CR 42's verdict stays `mergeable`

#### Scenario: Lease ends

- **WHEN** CR 42's verdict is `pending` with `merge_result_ungraded` and its lease is released through the release route or expires
- **THEN** the verdict is recomputed without the merge-result check

### Requirement: Merge-result verify runs decide the merge-result check

A verify run SHALL count for the check when it is final and clean, its `merge_result.base` equals the lease's `base`, and its scenario set digest is one the verdict grades at the head. Per Must scenario of each such set, the newest counted run's result is used. All `passed` clears the check; each `failed` or `not_run` Must adds a `blocked` reason `merge_result_failed` (`subject` `[<source>, <id>]`); no counted run keeps it `pending` with `merge_result_ungraded`.

#### Scenario: Passing merge-result run

- **WHEN** CR 42's lease has `base` `0a1b2c3` and a final, clean run with `merge_result.base` `0a1b2c3` on its approved intent set passes every Must
- **THEN** the merge-result check passes and, with no other reasons, CR 42's verdict is `mergeable`

#### Scenario: Failing Must on the merge result

- **WHEN** a final, clean run with `merge_result.base` `0a1b2c3` on CR 42's approved intent set reports Must scenario `S2` as `failed`
- **THEN** CR 42's verdict is `blocked` with a reason whose `rule` is `merge_result_failed` and whose `subject` is `["intent", "S2"]`

#### Scenario: Run against an older base

- **WHEN** CR 42's lease has `base` `0a1b2c3` and the only merge-result run names `merge_result.base` `9f8e7d6`
- **THEN** CR 42's verdict stays `pending` with a `merge_result_ungraded` reason whose `subject` is `["0a1b2c3…"]`

#### Scenario: Dirty merge-result run

- **WHEN** a merge-result run with `merge_result.base` equal to the lease's base has `source.dirty: true`
- **THEN** it does not count and the verdict stays `pending` with `merge_result_ungraded`

#### Scenario: Merge-result run does not grade the branch

- **WHEN** a merge-result run passes every Must for CR 42 and no branch run counts at the head
- **THEN** the branch scenario rules of CR 42's verdict are unaffected by that run

### Requirement: Merge policy settings take effect

From this phase `merge.lease_ttl` and `merge.regrade_merge_result` SHALL take effect, and the policy's `active_settings` MUST include both, as the review-policy capability requires.

#### Scenario: Merge settings reported active

- **WHEN** a client reads the project's review policy
- **THEN** `active_settings` includes `merge.lease_ttl` and `merge.regrade_merge_result`

### Requirement: Merge lease routes are in the OpenAPI document

The OpenAPI document SHALL describe the acquire, heartbeat and release routes with their request bodies, the lease response, the `409` bodies with their `error` values (`not_open`, `stale_head`, `not_mergeable`, `slot_taken`, `lease_not_active`), and the `401`, `403`, `404` and `422` responses.

#### Scenario: OpenAPI lists the acquire conflict

- **WHEN** a client fetches the OpenAPI document
- **THEN** the acquire operation lists a `409` response whose schema includes `error` and `holder` with `change_request` and `expires_at`
