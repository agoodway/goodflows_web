# Tasks

## 1. Slice 1: list page

- [ ] 1.1 Add `states:` and `preload:` options to `ChangeRequests.list` (design D2), leaving the API's params unchanged. Verify with a context test: a project with draft, open, merged and closed change requests returns only the draft and open ones for `states: ~w(draft open)`, each with its verdict loaded. Also verify that an API list call with `state=active` still returns `422`.
- [ ] 1.2 Add `ChangeRequestLive.Index` at `/dashboard/accounts/:account_id/projects/:slug/change-requests` in the `:account_scoped` live session. Give it breadcrumbs, `active_nav: :projects`, the Active, Merged, Closed and All filter in `?state=`, 50 rows per page with Load more, and an empty state per filter. Build it with `header/1`, `table/1`, `status_badge/1`, `tag/1` and `empty_state/1` only. Verify with LiveView tests for:
  - the default filter's rows and their order
  - `?state=closed`
  - Load more with 51 change requests
  - the empty state
  - a slug from another account redirecting with `Project not found`
- [ ] 1.3 Render each row's verdict per design D2: the stored verdict for active rows, `merged_verdict_state` and the `Merged without a mergeable verdict` mark for merged rows, nothing for closed rows, and `Pending` with `0 of 0` without a verdict. Verify with a test for a merged-while-blocked change request whose stored verdict was later recomputed.
- [ ] 1.4 Link each slug on the Projects page to its change request list. Verify with the existing `ProjectLive.Index` test file.

## 2. Slice 1: detail page

- [ ] 2.1 Add `ChangeRequestLive.Show` at `.../change-requests/:number`, loading per design D3. Render the header, Verdict reasons, Details, Merge and History panels, and the merged-without-mergeable-verdict notice. Verify with LiveView tests:
  - a `needs_review` verdict with `one_way_door` and `path_match` shows each message, rule and subject, with no subject for `[]`
  - a `mergeable` verdict says no rule fired
  - a change request with no head says `No head yet`
  - an unknown number redirects with `Change request not found`
- [ ] 2.2 Render the Review items panel from `Review.packet/1` and open tasks from `Review.list_tasks/2` for active change requests only. Verify that answers given at an earlier head do not show, and that a merged change request shows no items.
- [ ] 2.3 Render the Evidence at head panel: required workflows as passed, failed or missing; scenario sets; counted runs; and the claims summary. Verify a test with a `required_workflow_missing` reason for `ci` showing `ci` as missing.
- [ ] 2.4 Render the merge status: a held lease from `MergeLeases.held/2` with key name and expiry, `No lease held`, or the merge report with `Merged without a lease`. Verify one test for each case.
- [ ] 2.5 If both pages render the verdict badge, move it into a new `ChangeRequestComponents` module with a `@moduledoc` naming both pages.

## 3. Slice 1: change request events

- [ ] 3.1 Widen `record_verdict_changed/4` to compare `state`, `head`, `policy_version`, `reasons`, `scenarios`, `coverage`, `counted_runs` and `review` (design D7). Verify with context tests:
  - a verify run that clears `should_not_run` while a `one_way_door` reason remains writes one `verdict_changed` with `from` and `to` both `needs_review`
  - recomputing with unchanged inputs writes none
  - replace the existing "same state" event test rather than adding beside it
- [ ] 3.2 Record `cr_retargeted` in `retarget_locked/2` and `cr_parent_changed` in `relink/2`, with the API key as actor, only when the value changes. Verify with context tests: retarget `main` to `release/2` writes one event with that data and the key as actor; retarget to the current target writes none; set parent 41, change it to 40, then clear it writes the three events in the spec; a retarget refused with `lease_held` writes none.
- [ ] 3.3 Change `Review.complete_task/3` to take the API key, pass it from `ReviewController`, and record `task_completed` only on the move to `done`. Verify a controller test that completing a task writes one event with `task_id`, `item_id` and the key as actor, and completing it again writes none.
- [ ] 3.4 Add the three types to `ProjectEvents` `@types` and to the `ProjectEvent` OpenAPI schema enum and description. Verify `openapi_test.exs`, and a feed test that a `pk_` key reads the three types with `actor` null and `data` as stored.

## 4. Slice 1: live refresh and finish

- [ ] 4.1 Subscribe both pages to `ProjectEvents.topic/1` when connected, with the 500 ms debounced refresh from design D4. Keep the filter and the loaded rows on the list. Verify with LiveView tests that the open detail page updates when a verify run changes the verdict, when a verify run changes the reasons but not the state, on a retarget, and on a completed task. Also verify that the list keeps 51 loaded rows after a refresh.
- [ ] 4.2 Inspect both pages in the browser in light and dark, at desktop width and at 400px: a long title, the empty state, and the merged-without-mergeable-verdict notice. Check keyboard focus on rows and filters.
- [ ] 4.3 Run `mix precommit`, including the design guards in `test/good_flows_web/design/`.

## 5. Slice 2: actor on the answer path

- [ ] 5.1 Change `ProjectEvents.record/5` to take an actor (`account_user`, `api_key` or nil) or nil, and update every caller in `change_requests.ex`, `merge_leases.ex`, `scenario_sets.ex`, `review.ex`, `review_policies.ex` and `calibration.ex`. Verify that the existing event and controller tests pass unchanged.
- [ ] 5.2 Change `ScenarioSets.record_decision/5` to take the actor and write its `channel` and `api_key_id`. The API approve and reject path passes a `cli` actor. Verify the existing decision tests pass, and add a context test that a `dashboard` actor stores `channel` `dashboard` with `api_key_id` nil.
- [ ] 5.3 Change `Review.answer/5`, `answer_locked`, the diff decision and `create_task` to take the actor per design D5. `ReviewController` builds a `cli` actor. Verify the existing review tests pass, and add one context test that a `dashboard` actor's answer has `channel` `dashboard`, no key, counts in the verdict, and its `answer_recorded` event has the membership and no key.
- [ ] 5.4 Verify through the API that a dashboard answer reads in the packet with `channel` `dashboard` and `key_id` null, and in the event feed with `actor.key_id` null.

## 6. Slice 2: answering on the detail page

- [ ] 6.1 Add the answer actions and `editor_dialog/1` to each review item of an active change request: Approve, Reject, Request change, and Choose with a `select` of the options. The note is required for Reject and Request change, and the dialog posts the head the page showed. Use `phx-disable-with` on the confirm button. Verify LiveView tests for approve, choose `drop`, and a request change with an empty note showing the field error and storing nothing.
- [ ] 6.2 Hide actions the member may not take using `ScenarioSets.check_approver/2`, and show who may answer. Verify the author under `other_member` sees no actions on a `scenario_set_approval` item, and a plain member under `admin` sees none either.
- [ ] 6.3 Handle `{:stale_head, _}`, `:not_found`, `:forbidden` and `:not_active` per design D6. Verify a test that reports a new head between opening the dialog and confirming: nothing is stored, the flash shows, and the packet is at the new head.
- [ ] 6.4 Inspect the dialogs in the browser in light and dark at 400px, including focus moving into the dialog and returning on close.
- [ ] 6.5 Run `mix precommit` and `goodflows run ci --jobs test`.
