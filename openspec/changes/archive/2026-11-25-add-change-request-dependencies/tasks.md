# Tasks

## 1. Storage and route

- [x] 1.1 Add a migration with `dependencies text[] NOT NULL DEFAULT '{}'` on `change_requests` and the schema field
- [x] 1.2 Add `Params.dependencies/1` (design D2) and `ChangeRequests.set_dependencies/3`: editable check, advisory locks (design D5), row lock, store, `cr_dependencies_changed` when the list changed, recompute
- [x] 1.3 Add the `PUT .../dependencies` route, controller action and OpenAPI request schema; render `dependencies` in `ChangeRequestJSON` and the `ChangeRequest` schema; add `cr_dependencies_changed` to the event types and the `ProjectEvent` schema

## 2. Rule

- [x] 2.1 Pass a `dependencies` input from `recompute/3` (design D3) and add `dependency_not_merged` to `Rules` with its three messages and `inputs.dependencies`; add the rule to `VerdictReason`
- [x] 2.2 Test the rule's cases: open, all closed, none, merged alongside closed, another project's change request, two ids

## 3. Dependents

- [x] 3.1 Enqueue `RecomputeJob` with `change_id` from merge, state changes and create when dependents exist, under the advisory lock (design D4, D5); add `recompute_dependents/2` and the job's `change_id` input
- [x] 3.2 Test that a merge enqueues the job and the job clears the reason on a dependent with a lower number, and that a close changes the message

## 4. Finish

- [x] 4.1 Run `mix precommit` and `goodflows run ci --jobs test`
- [x] 4.2 Archive the change into `openspec/specs`
