# Tasks

## 1. Event feed storage

- [x] 1.1 Add a migration for `project_events` (bigint identity `id`, `project_id` with `on_delete: :delete_all`, `change_request_number` nullable, `type`, `data` jsonb, `actor_membership_id`, `actor_key_id`, `inserted_at`), indexed on `(project_id, id)`; verify `mix ecto.migrate` and `mix ecto.rollback` both succeed
- [x] 1.2 Add an events context function that inserts an event inside a caller's `Ecto.Multi`/transaction and broadcasts on the per-project PubSub topic only after commit; verify with a test that a rolled-back transaction leaves no event and sends no broadcast
- [x] 1.3 Make event `id`s commit-ordered per project (for example a per-project advisory transaction lock or row lock taken before insert); verify with a concurrency test where two transactions commit out of `id` order and a reader using `next_cursor` still sees both events
- [x] 1.4 Add a test that deleting a project with events succeeds and removes the events

## 2. Emit events from earlier phases

- [x] 2.1 Emit `cr_state_changed` in the `transition/4` and `report_merge/4` transactions; verify with tests for `draft` -> `open`, `open` -> `closed`, a reopen and a merge report (`open` -> `merged`), and that a same-state `200` and an idempotent merge retry emit nothing
- [x] 2.2 Emit `verdict_changed` from verdict recomputation only when state, head or policy version changes; verify with tests for a change and for an unchanged recompute
- [x] 2.3 Emit `scenario_set_uploaded`, `scenario_set_approved` and `scenario_set_rejected` (with `digest` and `note`) in the phase 2 upload, approval and rejection transactions, including decisions recorded through answers; verify with tests
- [x] 2.4 Emit `policy_version_created` (with `number` null) in the policy write transaction; verify with a test

## 3. Event feed API

- [x] 3.1 Add `GET /api/v1/projects/:project/events` with `sk_`/`pk_` auth (`ck_` -> `403`), `after`, `limit` (1..200, default 100) and `wait` (0..30, default 0) validated through a changeset (`after` as a non-negative integer, errors on `after`); verify controller tests for `401`, `403`, `404`, `406`, `422` on `after`/`limit`/`wait`, paging and empty pages
- [x] 3.2 Implement long-poll: query, and if empty subscribe to the project topic without holding a DB connection, wait up to `wait` seconds, then query again; verify tests for an event arriving mid-wait and for a timeout
- [x] 3.3 Add a per-node, per-account waiter limit (configurable, default 20) that answers over-limit requests as `wait=0`; verify with a test that sets the limit to 1
- [x] 3.4 Render `actor` as `{user_id, key_id}` from the stored membership and key, and add the `pk_` redaction (`note` and `actor` null, absent fields never added); verify with tests reading `answer_recorded` and `scenario_set_rejected` events with a `pk_` key
- [x] 3.5 Add a 90-day retention sweep job and return `410` with `latest_cursor` when `after` precedes deleted events; verify sweep and `410` tests
- [x] 3.6 Describe the route, parameters, event types and `410` body in `GoodFlowsWeb.ApiSpec`; verify `openapi_test.exs` covers the route

## 4. Review packet

- [x] 4.1 Build packet items from the stored verdict at the current head: one item per `needs_review` reason by the rule-to-kind table (`proof_below_minimum` -> `unproven_claim`, `path_match` -> `sensitive_path`, each `max_changed_*` -> its own `size` item, `spec_gap` -> `spec_gap`, ...), plus `scenario_set_approval` only when its subject names a digest, split `open_items` into `question` and `open_item` items, and list other `pending`/`blocked` reasons as context; verify unit tests per item kind
- [x] 4.2 Compute item IDs as `<rule>:<sha256 of canonical subject JSON>` using `GoodFlows.JsonDocument.digest/1`, with split subjects `[<question id>]` and `[<index>, <risk>]`; verify the same subject gives the same ID at two heads and that two `left_open` entries with the same `risk` get different IDs
- [x] 4.3 Fill `data` per kind from stored claims, git facts, scenario sets, counted verify runs and the feature index, with hunks only from claims `decisions`, `unproven_claim` entries with `evidence` and `covers`, and `spec_gap` `covering_claims`; verify a test per kind matching the spec scenarios
- [x] 4.4 Presign artifact GET URLs on each read with a 15-minute expiry through the cache object store, returning `expired: true` for swept artifacts and null URLs without object storage; verify tests for expiry time and expired artifacts
- [x] 4.5 Add `GET /api/v1/projects/:project/change-requests/:number/review` (`sk_` only; `pk_`/`ck_` -> `403`); verify controller tests for `200`, `401`, `403`, `404`, `406`, and the no-facts, no-facts-with-unapproved-intent-set (one `scenario_set_approval` item) and mergeable packets
- [x] 4.6 Describe the packet schema and item kinds in `GoodFlowsWeb.ApiSpec`; verify `openapi_test.exs`

## 5. Answers

- [x] 5.1 Add a migration for `review_answers` (change request, item `id`, `kind`, `rule`, `head` (null before any `git-facts` report), `answer`, `option`, `note`, membership, key, channel, `superseded_at`, timestamps) with a partial unique index on current answers per `(change_request, item_id, head)` declared `NULLS NOT DISTINCT`, so two current answers with a null `head` conflict; verify migrate and rollback
- [x] 5.2 Validate the answer body (unknown keys, `note` 1..10,000 bytes required for `reject`/`request_change`, `option` only and always for `choose`) and check the answer against the item's allowed answers and question options; verify `422` tests
- [x] 5.3 Store an answer in one transaction: check state is `draft`/`open` (`409`, before body validation, the head check, the item lookup and the approver check), check `head` is current, or null when no `git-facts` report exists (`409` with current head), check the item exists at the head (`404`), supersede the earlier answer, stale its open task, recompute the verdict, and emit `answer_recorded`; verify tests for each path
- [x] 5.4 Enforce who may answer: any `sk_` key, except `scenario_set_approval`, which follows `scenarios.approver`; verify `403` for the author under `other_member` and `201` for a non-admin on `one_way_door` under `admin`
- [x] 5.5 Route `scenario_set_approval` `approve` through the phase 2 approve-decision function and `reject` through the phase 2 reject-decision function (with the answer's note), plus a task, in the answer transaction; a repeat decision (same `decision` and `note` as the digest's latest, same membership) adds no decision row and no set event but still stores the answer; verify the set stays approved on a new head, a rejected digest reads `approved` false until approved again, and a repeated reject stores one decision row
- [x] 5.6 Add `POST .../review/items/:item_id/answers` and describe it in `GoodFlowsWeb.ApiSpec`; verify controller and `openapi_test.exs` tests

## 6. Verdict integration

- [x] 6.1 Extend verdict computation so `needs_review` becomes `mergeable` when every item has a current `approve` or `choose` at the head (an `open_items` reason clears only when all its split items do; answers at an earlier head count again when that head is current again), never overriding `pending` or `blocked`, and keep the reasons in the verdict; verify tests for all approved, one `request_change`, blocked with all approved, and pending that clears at the same head
- [x] 6.2 Add `review` `{items, cleared}` to the verdict response and its OpenAPI schema; verify tests including a reset to `cleared: 0` on a new head

## 7. Tasks

- [x] 7.1 Add a migration for `review_tasks` (change request, answer, item `id`, `kind`, `answer`, `note`, `head`, `state` `open|stale|done`, created and done memberships and times); verify migrate and rollback
- [x] 7.2 Create a task and emit `task_created` in the answer transaction for `request_change` and `reject`; verify a test
- [x] 7.3 Mark every `open` task `stale` in the `git-facts` transaction that sets a new head; verify a test that the head on the task is kept
- [x] 7.4 Add `GET .../tasks` (`state` filter, default `open` and `stale`) and `POST .../tasks/:task_id/done` (idempotent), `sk_` only, and describe both in `GoodFlowsWeb.ApiSpec`; verify controller tests for `200`, `403`, `404`, `422` and `openapi_test.exs`

## 8. Integration

- [x] 8.1 Add an end-to-end test: open a change request, report facts and claims that give `needs_review`, read the packet, answer `request_change`, list the task, push a new head, see the task `stale` and answers cleared, approve every item, and see `verdict_changed` to `mergeable` in the event feed
- [x] 8.2 Run `mix precommit` from `app/` and fix every warning, format, Credo and test failure

## Follow-up

- Archive after `add-change-request-core` and `add-change-request-grading`, so the `change-requests` main spec exists.
