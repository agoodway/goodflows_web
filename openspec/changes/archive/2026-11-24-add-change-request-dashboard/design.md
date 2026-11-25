# Design

## Context

See proposal.md. The dashboard is a set of LiveViews in the `:account_scoped` live session. `UserAuth` `:load_account_context` assigns `current_account`, and pages look up the membership with `Accounts.get_account_user/2` (`ProjectLive.Index.manager?/1`). Pages are built only from `GoodFlowsWeb.CoreComponents` (DESIGN.md "The rule"); `ProjectLive.Index` is the closest page to copy.

Everything the pages show is stored already:

- `ChangeRequests.list/2`: keyset pages by `number` descending, with exact `state` and `source_branch` filters.
- `ChangeRequests.load/1`: the opener, parent, description, verdict and history.
- `Review.packet/1`: the header, the `pending` and `blocked` context, and the items with their current answers, built under a `FOR SHARE` lock.
- `Review.list_tasks/2`, `MergeLeases.held/2` and the merge fields on `ChangeRequest`.
- `ProjectEvents.topic/1`: the PubSub topic that receives `{:project_event, project_id}` after each committed event. The message carries no change request number.

Some change request writes record no event, so a page listening on that topic would miss them:

- `record_verdict_changed/4` skips the event when the state, head and policy version are unchanged, even if the reasons, scenarios, counted runs or review counts changed.
- `retarget/3`, `set_parent/3` and `clear_parent/2` record nothing of their own.
- `Review.complete_task/3` records nothing.

Opening a change request is covered: its first recompute records `verdict_changed` with `from` null.

The answer path assumes an API key throughout. `Review.answer/5` and `answer_locked/5` write `api_key_id: api_key.id` and `channel: "cli"`. `ScenarioSets.record_decision/5` writes `api_key_id` and `channel: "cli"`. `ProjectEvents.record/5` derives `actor_membership_id` and `actor_key_id` from the key. `create_task/3` passes the key to `ProjectEvents.record/5`. Every `api_key_id` and `actor_key_id` column is nullable (`on_delete: :nilify_all`).

The approved mockup is at https://ampcode.com/artifacts/visuals/change-requests-dashboard-mockup-4603f768-c347-4834-b2bf-00b6c0edd4fc.

## Goals / Non-Goals

**Goals:**
- Any account member can see, from the dashboard, what a change request needs and why, from the same stored data the API returns.
- Slice 1 adds no write path and no migration, and ships on its own.
- Slice 2 stores dashboard answers with exactly the API's effects and rules. The only difference is how the actor is recorded.

**Non-Goals:**
- State changes (open, close, reopen, retarget, parent), merge leases and merge reports from the dashboard.
- Completing tasks from the dashboard.
- The full claims Markdown, Git facts diffs and verify run artifact links. The packet presigns artifact URLs on every build, so they are left out rather than shown with a 15-minute expiry.
- A list across all of an account's projects, and a sidebar item for it.
- Changing any API request or response shape. The event feed gains event types (D7), but no existing type changes shape.

## Decisions

### D1. Routes nest under the project slug

The routes are `/dashboard/accounts/:account_id/projects/:slug/change-requests` and `.../change-requests/:number`, matching the API's `/projects/:project/change-requests/:number`. Two LiveViews, `ChangeRequestLive.Index` and `ChangeRequestLive.Show`, go in the `:account_scoped` live session. The project is resolved with `Projects.get_project(current_account, slug)`, and the change request with `ChangeRequests.get/2`. A miss does `push_navigate` to the Projects page with an error flash, so an ID from another account reveals nothing.

Alternative considered: a sidebar item "Change requests" with a project switcher. Rejected for slice 1 because the API and CLI already think per project, and a switcher is extra UI that one link from the Projects page makes unnecessary.

### D2. The list reads verdicts in one query

`ChangeRequests.list/2` becomes `list/3` with an options keyword list that the API never sets: `states: [String.t()]` (the dashboard's Active filter passes `~w(draft open)`) and `preload: [:verdict]`. The API keeps calling it with params only, so its `state` filter still accepts exactly the four states.

`list` already preloads the opener and parent, so a page is a single query for the rows plus one for each preload. The review count is the stored verdict's `review` map (`items`, `cleared`) on every row, merged and closed rows included, because the merge report stores no review counts. The packet is not built per row.

A merged row shows `merged_verdict_state` and `merged_without_mergeable_verdict`, not the stored verdict. Recompute skips merged and closed change requests, but the stored verdict can still predate the merge report, and the merge-time verdict is the one that matters. A closed row shows no verdict, because nothing keeps it current.

### D3. The detail page builds from `load/1`, `packet/1`, tasks and the lease

`mount` and every refresh call `ChangeRequests.load/1`. For an active change request they also call `Review.packet/1`, `Review.list_tasks(cr, %{"state" => "open"})` and `MergeLeases.held/2`. The page renders sections with the shared components:

- `header/1`: number, title, state and verdict
- `panel/1` with `list/1`: Verdict reasons, Review items, Evidence at head, Details, Merge and History
- `notice kind="warning"`: merged without a mergeable verdict

The evidence rows come from the packet's `passed.workflows` plus the `required_workflow_failed` and `required_workflow_missing` reasons, the verdict's `scenarios` and `counted_runs`, and the claims front matter's `door`, `safe_because`, `questions` and `left_open` counts. Both the packet's `passed.workflows` and the page's workflow rows come from one function, `Review.Packet.workflows/1`, so they cannot drift apart. A merged or closed change request has no packet: its panel reads the same function on the stored verdict and is titled "Last computed evidence", with a line saying nothing updates it and a "Review count" row with the stored count (the same count the list row shows; no review items are listed), so it is not mistaken for the reasons kept with the merge report.

Item kinds and verdict states get readable names in one map in the page (`sensitive_path` → "Sensitive path", `needs_review` → "Needs review"). Verdict badges use the existing `status_badge` kinds: `mergeable` is `primary`, `blocked` is `error`, and `pending` and `needs_review` are `neutral` with a dot. They are told apart by their words, as DESIGN.md requires. No new badge kind is added.

If list and detail both need the verdict badge, it becomes a function in a new `ChangeRequestComponents` module, per DESIGN.md.

### D4. Refresh on any project event, debounced

Both pages subscribe to `ProjectEvents.topic(project.id)` when connected. The message has no change request number, and D7 makes every change the pages show record an event. On `{:project_event, _}` the page schedules one `:refresh` 500 ms later and ignores further events until it runs, so a recompute that records several events reloads once. The list refresh reloads the rows already shown: one `list/3` call with `limit` set to the number of rows loaded, capped at the API maximum, then paging as before. The detail refresh reruns D3. An open answer dialog keeps its assigns across a refresh.

Alternative considered: adding the number to the PubSub message. Rejected because the Listener only gets the project ID from `pg_notify`, and changing that payload touches long-poll readers for little gain.

### D5. An answer's actor is a membership, an optional key, and a channel

Slice 2 replaces the `api_key` argument on the answer path with an actor:

```elixir
%{account_user: %AccountUser{}, api_key: %ApiKey{} | nil, channel: "cli" | "dashboard"}
```

- `Review.answer/5` takes the actor in place of `(account_user, api_key)`. `ReviewController` builds it from the conn with `channel: "cli"`. The dashboard builds it from the signed-in user's membership with `api_key: nil, channel: "dashboard"`.
- `ScenarioSets.record_decision/5` takes the actor and writes `channel` and `api_key_id` from it. Its API caller in `scenario_sets.ex` (the approve and reject calls) builds a `cli` actor from the request's key.
- `ProjectEvents.record/5` takes the actor (or nil for server-made events) and writes `actor_membership_id` from `account_user` and `actor_key_id` from `api_key`. Today's callers that pass a key pass `%{account_user: key's membership, api_key: key}`.
- `create_task/3` passes the actor through.

The approver check already takes the membership (`ScenarioSets.check_approver/2`), so the dashboard gets the same rule with no new code. The page calls the same check up front to hide actions the member may not take, and the domain still refuses them (`:forbidden`) if the policy changes in between.

Alternative considered: mint a hidden per-user API key for dashboard writes. Rejected because the key would appear in key lists and events as if a client had used it, and revoking it would break the dashboard.

### D6. Answers post the head the page showed

The answer dialog stores the packet `head` the page rendered and passes it in the answer body. `{:stale_head, head}` sets the error flash and runs the D3 refresh. `:not_found` means the item is gone at the current head (a verify run, a diff version or a policy write cleared its reason without a new head), and gets the same refresh, with its own flash `This item no longer needs an answer at this head.` `{:invalid_body, errors}` is shown under the matching field (`note`, `option`). `:forbidden` gets the flash `You can't answer this item` plus a refresh. `:not_active` gets the flash `This change request is no longer open` plus a refresh. The confirm button uses `phx-disable-with`.

### D7. Every change the pages show records an event

Slice 1 closes the gaps listed in Context with real feed events rather than a page-only signal, so CLI and other feed readers see the same changes.

- `record_verdict_changed/4` compares what the verdict shows: `state`, `head`, `policy_version`, `reasons`, `scenarios`, `coverage`, `counted_runs` and `review`. It skips the event only when all of them are equal. `inputs` and `computed_at` are left out, so a recompute that reaches the same result stays silent. The data shape is unchanged, so a same-state event has `from` equal to `to`.
- `retarget_locked/2` records `cr_retargeted` (`from` and `to` branch), and `relink/2` records `cr_parent_changed` (`from` and `to` parent numbers, or null), each only when the value changed and before the recompute, in the same transaction. Both functions take the API key they currently ignore, as the actor.
- `Review.complete_task/3` becomes `complete_task/4` with the API key, and `complete_locked` records `task_completed` (`task_id`, `item_id`) only on the move to `done`. `ReviewController` passes `conn.assigns.current_api_key`.
- The three types go in `ProjectEvents` `@types` and in the `ProjectEvent` OpenAPI schema enum and description. None of them carries a note or ticket, so `pk_` redaction needs no change.

Alternative considered: a `pg_notify` on the events channel with no event row. Rejected because long-poll readers would wake up and find no new events, and feed readers would still miss these changes.

## Risks / Trade-offs

- **The packet locks the row `FOR SHARE` on every detail refresh.** A busy project could send many refreshes while a verify run writes. The 500 ms debounce bounds it to two reads per second per open page. Writers take `FOR UPDATE` only briefly.
- **The actor refactor touches every `ProjectEvents.record/5` caller.** That is a mechanical change across change requests, leases, scenario sets, policies and defects. The existing event and controller tests cover each caller's actor, and they must pass unchanged.
- **A member can approve their own one-way door from the dashboard.** The API already allows this for any `sk_` key, so the dashboard adds no new power. A stricter rule belongs in the review policy, not in the UI.
- **The list's verdict can lag a just-finished recompute.** It updates on the next project event refresh.
- **`verdict_changed` gets noisier.** A verify run that adds a counted run now writes an event even when the state holds. That is one row per real change, inside the 90-day retention, and it is the signal the pages need. Feed readers that treat every `verdict_changed` as a state change will see `from` equal to `to`. The goodflows CLI is not one of them. It prints events by type and data without matching on type, and `cr wait` polls the verdict instead of reading the feed.
