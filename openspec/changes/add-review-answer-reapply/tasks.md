# Tasks

## 1. Storage

- [ ] 1.1 Add a migration for `review_answers.reapplied_from_answer_id` (nullable, `references(:review_answers, on_delete: :nilify_all)`) and the field and `belongs_to` on `GoodFlows.Review.Answer`; verify `mix ecto.migrate` and `mix ecto.rollback` both succeed

## 2. Earlier answers in the packet

- [ ] 2.1 Add `earlier_answers/1` to `GoodFlows.Review` (latest current answer per `item_id` at heads other than the current head, null-safe) and attach `earlier_answer` to each packet item; verify tests for the spec scenarios `Approved at the previous head`, `Two earlier heads`, `Never answered` and `Shown but not counted`
- [ ] 2.2 Compute `reapplicable` and `not_reapplicable_reason` in check order (`kind`, `answer`, `option_removed`, `answered_at_head`); verify one test per reason and one re-applicable case
- [ ] 2.3 Compute `changed_since` from the current head's `git-facts.commits` (ancestor check, later commits, union of `path` and `old_path`, `item_paths` for `open_item` with the line suffix stripped and for `sensitive_path`); verify the `One later commit`, `After a rebase`, `Untouched open item`, `Touched open item` and `Kind without paths` scenarios, plus a rename where only `old_path` matches

## 3. Reapply

- [ ] 3.1 Add `Review.reapply/4` (row lock, `409` checks, rebuild items and answers inside the lock, collect `item_ids[i]` errors, insert all, one `answer_recorded` per answer with `reapplied_from_head`, one recompute); verify all-or-nothing with one bad id, a stale head, a closed change request, and that two answers produce two events and one `verdict_changed` at most
- [ ] 3.2 Add `reapplied_from_head` (null for direct answers) to `answer_recorded` from `answer/4`; verify the `Direct answer event` scenario
- [ ] 3.3 Add the `POST .../review/reapply` route, controller action and body validation (`head`, `item_ids` 1..200 unique, no other keys; `pk_`/`ck_` -> `403`), and render `reapplied_from` on every answer; verify controller tests for `201`, `401`, `403`, `404`, `409` (stale head and inactive) and `422` (unknown key, empty, duplicate and over-limit `item_ids`, a non-item id, a non-re-applicable id)
- [ ] 3.4 Describe the route, `earlier_answer`, `changed_since` and `reapplied_from` in `GoodFlowsWeb.ApiSpec` and the review schemas; verify `openapi_test.exs` covers the route

## 4. Dashboard

- [ ] 4.1 Show each item's earlier answer and changed-since line in the Review items panel, and show `reapplied_from` on a re-applied current answer; verify LiveView tests for `Answer at an earlier head`, `Earlier approval on an untouched item` and `After a rebase` and a screenshot of the panel on a seeded change request
- [ ] 4.2 Add the per-item `Re-approve` / `Re-choose <option>` action and the panel's `Re-apply unchanged (n)` action with a confirm dialog listing the items, calling `Review.reapply/4` with channel `dashboard`; verify LiveView tests for `Re-apply unchanged items`, `Changed item is left out`, `Head moved before confirm`, and that a member barred by `may_answer?/3` sees no re-apply action

## 5. Wrap-up

- [ ] 5.1 Run `mix precommit` and fix any findings
- [ ] 5.2 Check the API contract against the companion CLI change in agoodway/goodflows and reconcile any mismatch before archiving
