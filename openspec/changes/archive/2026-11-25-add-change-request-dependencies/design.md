# Design

## Context

See proposal.md. A stacked change request already has a CR-level link with the same lifecycle: `PUT .../parent` stores `parent_id`, records `cr_parent_changed`, and recomputes; `Rules` reads `inputs.parent` and adds `parent_not_merged` or `parent_closed`. When a parent changes state, `lock_children/1` locks its `draft` and `open` children after it, in `number` order, and recomputes them in the same transaction. That works because a child always has a higher number than its parent, and every multi-row lock in `GoodFlows.ChangeRequests` locks in `number` order.

A dependency has no such ordering: B can depend on a change whose change request has a higher number than B's, and several change requests may link the same change id (for example one closed and one reopened).

## Decisions

### D1. Storage: a text array on the change request

`change_requests.dependencies` is `text[] NOT NULL DEFAULT '{}'`, stored in the order the client sent. The ids are change ids, not change request numbers: the change request that will satisfy a dependency may not exist yet, and the one that exists may be closed and replaced. No index: the dependents query filters by `project_id` and active state first, and a project has few active change requests.

### D2. The route replaces the list

`PUT .../dependencies` takes exactly `{"change_ids": [...]}`: at most 50 distinct ids, each a 1 to 64 byte slug matching `[a-z0-9][a-z0-9-]*` (the `openspec_change` rule). An empty list clears it. A duplicate id, or the change request's own `openspec_change`, is `422` on `change_ids`: a change request that waits on its own change could never merge. The change request must be `draft` or `open` (else `409` `not_editable`), and the key `sk_`, like the parent route. A list equal to the stored one records no event; the verdict is recomputed either way.

### D3. The rule reads each id's linked change requests

`recompute/3` passes `dependencies: [%{change_id: id, change_requests: [%{number, state}]}]`, one entry per stored id in stored order, with the other change requests of the project whose `openspec_change` is that id, by `number`. `Rules` stays pure. For each entry with no `merged` change request it adds `dependency_not_merged`, `pending`, subject `[id]`:

- some are `draft` or `open`: "Change `a` is not merged: change request 41 links it. Merge it first, or rebase onto a commit where `a` is archived";
- all are `closed`: "Every change request linking change `a` is closed (41). Reopen and merge one, or rebase onto a commit where `a` is archived";
- none: "No change request links change `a`. Open and merge one, or rebase onto a commit where `a` is archived".

It runs whatever the facts, like the parent rules. `inputs.dependencies` is the stored id list.

### D4. Dependents are recomputed by a job, not under the merge's locks

When change request A, which links change id `a`, merges, the change requests depending on `a` may have lower numbers than A. Locking them after A would break the `number` order and could deadlock with a parent's state change or a bulk recompute. So the transaction that changes A's state (merge, close, reopen, ready, draft) or creates A enqueues `RecomputeJob` with `%{"project_id", "change_id"}` when at least one `draft` or `open` change request of the project depends on `a`. The job runs after the commit and calls `recompute_dependents/2`, which locks those change requests `FOR UPDATE` in `number` order in its own transaction and recomputes them. Recomputing is idempotent, so retries are safe. A move between `draft` and `open` changes nothing the rule shows, so its recompute writes no event; it is enqueued anyway to keep one condition.

Alternative considered: recompute inline after the merge commits, in a second transaction. Rejected because a crash between the two loses the recompute; the job is enqueued in the same transaction as the merge.

### D5. One advisory lock per (project, change id) serializes the race

Under READ COMMITTED, a dependencies `PUT` that recomputes while A's merge is uncommitted reads A as `open`, and the merge's dependents query cannot see the uncommitted list, so neither recomputes with both. Both paths, and every path that enqueues for `a`, take `pg_advisory_xact_lock` on `('change_request_change:' || project_id || ':' || id)` before any change request row lock: the merge, close, reopen and create for the change request's own `openspec_change`, and the `PUT` for each id of the new list in sorted order. The same pattern already serializes Git facts and workflow runs on a head (`lock_head/2`). No path takes both kinds of advisory lock, so the order cannot cycle.

### D6. The job is the existing `RecomputeJob`

`RecomputeJob` already recomputes a whole project after a policy write. With a `change_id` in its input it recomputes only that id's dependents. Reusing it needs no new queue or worker registration.

## Risks / Trade-offs

- A dependent's verdict lags its dependency's merge by the job latency. A merge gate reads the verdict right before acquiring a lease, so the lag only delays, never lets a change through early.
- The list belongs to the change request, not to a head: an older head's verdict is not recomputed with the list that head had (design R3.1).
