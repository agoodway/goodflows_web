# Proposal

## Why

Change requests are reachable only through the JSON API and the `goodflows` CLI. A reviewer who wants to know why change request 46 is `needs_review` has to read the change request and its review packet with the CLI, read raw reasons such as `path_match` with subject `["priv/repo/migrations/**"]`, and answer each item from a terminal with an `sk_` key. The dashboard, where account members already manage projects and API keys, shows nothing about change requests. Nobody can see at a glance which change requests are blocked, which wait on a person, or which were merged without a mergeable verdict.

## What Changes

The work ships in two slices. Slice 1 can ship on its own.

**Slice 1: read-only change request pages.**

- A change request list per project at `/dashboard/accounts/:account_id/projects/:slug/change-requests`. It shows the newest first, filters by Active (draft and open), Merged, Closed and All, and pages with Load more. Each row has the number, title, source and target branch, state, verdict (for a merged change request, the verdict at merge), review items cleared, the time it was last updated, and a mark when it was merged without a mergeable verdict.
- A detail page at `/dashboard/accounts/:account_id/projects/:slug/change-requests/:number`. It shows:
  - the verdict's reasons, with outcome, message, rule and subject
  - the review packet's items, with their current answers and open tasks
  - the evidence at the head: required workflows, scenario sets, counted verify runs and a claims summary
  - the merge status: the held lease, or the merge report with its warnings
  - the parent change request and the state history
- Both pages update when a project event for the project arrives.
- The project event feed records every change request change the pages show. Today four kinds record nothing, so the pages would miss them:
  - `verdict_changed` is written only when the verdict's state, head or policy version changes. It will also be written when the reasons, scenarios, coverage, counted runs or review counts change.
  - New event types: `cr_retargeted` for a target branch change, `cr_parent_changed` for a parent set, changed or cleared, and `task_completed` for a task marked done.
- Every account member can view them. The pages write nothing.
- The Projects page links each project to its change request list.

**Slice 2: answer review items in the dashboard.**

- On an active change request, each review item offers the answers its kind allows (Approve, Reject, Request change, Choose). Reject and Request change require a note. The answer is bound to the head the page showed.
- The same rules as the API decide who may answer. `scenario_set_approval` and `diff_set_weakened` follow the policy's `scenarios.approver`. A member who may not answer an item sees why instead of the actions.
- A dashboard answer is stored with the member's membership, no API key, and channel `dashboard`. Its scenario set decisions, tasks and project events are stored the same way.

## Capabilities

### New Capabilities

- `change-request-dashboard`: the dashboard's change request list and detail pages, and answering review items from the detail page.

### Modified Capabilities

- `change-request-review`: answers may come from the dashboard (channel `dashboard`, no key), and dashboard members follow the same rules on who may answer.
- `qa-scenario-sets`: a decision made through a dashboard answer has channel `dashboard` and no key.
- `project-events` (slice 1): new event types `cr_retargeted`, `cr_parent_changed` and `task_completed`, and `verdict_changed` is written whenever anything the verdict shows changes, not only its state, head or policy version.
- `project-events` (slice 2): an event caused by a dashboard action has an `actor` with `user_id` and `key_id` null.

## Impact

- New LiveViews `ChangeRequestLive.Index` and `ChangeRequestLive.Show` in the `:account_scoped` live session, plus the `ProjectLive.Index` link. No new sidebar item.
- Slice 1 reuses `ChangeRequests.list/2`, `ChangeRequests.load/1`, `Review.packet/1`, `Review.list_tasks/2`, `MergeLeases.held/2` and the `ProjectEvents` PubSub topic. `list` gains dashboard-only options for draft and open together and a verdict preload. No migration.
- Slice 1 also records the new events in `ChangeRequests.retarget/3`, `set_parent/3`, `clear_parent/2` and `Review.complete_task/3`, which gains the API key so the event can name it. It widens the no-change check in `record_verdict_changed`, and adds the three types to `ProjectEvents` `@types` and the OpenAPI `ProjectEvent` schema. No migration: `type` is a text column.
- Event feed readers will see three new types and more `verdict_changed` events whose `from` equals `to`. The goodflows CLI (agoodway/goodflows at `a0a8ab3`) needs no companion change:
  - `goodflows events` passes each event's `type` and `data` through without matching on type (`src/change_requests/mod.rs` `events/4`, `src/output/change_requests.rs`).
  - `goodflows cr wait` polls the verdict endpoint, not the feed.
- Slice 2 changes `Review.answer/5`, `ScenarioSets.record_decision/5`, `ProjectEvents.record/5` and task creation so they take an actor (membership, optional key, channel) instead of requiring an API key. The `api_key_id` columns are already nullable. No migration.
- API responses keep their shape. An answer or decision made in the dashboard reads through the API with `channel` `dashboard` and `key_id` null.
- Out of scope: opening, closing, merging or retargeting change requests from the dashboard; completing tasks; the full claims document, Git facts diffs and verify run artifact links; a cross-project change request list.
