# Proposal

## Why

A goodflows change can say in `change.md` that it depends on other changes (`depends_on: [A]`): it is written against the specs as A leaves them and must not land before A. The CLI's `change validate` and `change archive` will enforce that locally, but nothing stops change B's change request from reaching `mergeable` and merging while A's change request is still open. The server knows a change only by the id a change request links (`openspec_change`), so it needs to store B's dependencies and hold B's verdict until a change request linking A merges.

Design: [goodflows change dependencies](https://ampcode.com/artifacts/goodflows-change-dependencies-design-b7e4a71f-4fcd-4aee-a656-1763a2bc1645), "The verdict (goodflows_web)" (decisions R1.4, R2.2, R2.3, R3.1).

## What Changes

- **A change request stores a `dependencies` list of change ids.** `PUT /api/v1/projects/:project/change-requests/:number/dependencies` with `{"change_ids": [...]}` replaces the list of a `draft` or `open` change request and recomputes its verdict, the same way setting a parent does. Each id follows the slug rule of `openspec_change`. The list appears as `dependencies` in every change request response.
- **A `cr_dependencies_changed` project event** (`from`, `to`: the old and new lists) is recorded when the list changes.
- **A new verdict rule, `dependency_not_merged`** (`pending`, subject `[<change id>]`), fires for each stored id until a change request of the same project that links that id is `merged`. Its message says which case holds: a change request linking the id is not merged, every one linking it is closed, or none links it. Each names the way out that needs no change request: rebase onto a commit where the change is archived. The verdict's `inputs` record the ids.
- **Dependents are recomputed without a push.** When a change request that links a change id merges, closes, reopens, changes between `draft` and `open`, or is created, the `draft` and `open` change requests that depend on that id are recomputed by a background job.
- `git-facts/1` does not change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `change-requests`: the `dependencies` list, its route, the `dependency_not_merged` rule and the recompute of dependents.
- `project-events`: the `cr_dependencies_changed` event.

## Impact

- Migration: `dependencies text[] NOT NULL DEFAULT '{}'` on `change_requests`. No backfill: existing change requests have no dependencies, so their verdicts do not change.
- `GoodFlows.ChangeRequests`: `set_dependencies/3`, `recompute/3` (a `dependencies` input), `report_merge/3`, `transition/3` and `create/4` (enqueue the dependents' recompute), `recompute_dependents/2`.
- `GoodFlows.ChangeRequests.Rules`: the rule and its input; `GoodFlows.ChangeRequests.RecomputeJob` accepts an optional `change_id`.
- API: the new route, `dependencies` on `ChangeRequest`, the rule in `VerdictReason`, the event in `ProjectEvent`. All additive.
- Companion CLI change (separate repository): `cr open --change` sets the list from `change.md` at the head and `cr push` resyncs it when it differs. Until it ships, every list is empty and the rule never fires.
- Out of scope: setting dependencies at create time, showing them on the dashboard page, and renaming `openspec_change` to `change_id`.
