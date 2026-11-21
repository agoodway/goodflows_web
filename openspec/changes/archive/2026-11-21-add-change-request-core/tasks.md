# Tasks

## 1. Migrations and schemas

- [x] 1.1 Add migration `change_requests` (account, project, `number`, title, source/target branch, `openspec_change`, `links` with indexed thread/ticket columns like `workflow_runs`, `state`, `closed_from_state`, `head`, opened-by membership and key, merge columns incl. `merged_verdict_state`, `merged_policy_version`, `merged_reasons` jsonb and `merged_without_mergeable_verdict`) with a unique index on (`project_id`, `number`); verify `mix ecto.migrate` and `mix ecto.rollback` both succeed
- [x] 1.2 Add a per-project number counter (column on `projects` or a counter table) incremented with a row lock so concurrent creates get distinct numbers and numbers are never reused; verify with a migration test in `test/good_flows/migrations`
- [x] 1.3 Add migration `change_request_events` (change request, from/to state, membership, key, inserted_at); verify migrate/rollback
- [x] 1.4 Add migration `change_request_git_facts` (change request, `head`, `target_branch`, document jsonb, digest, membership, key, inserted_at) unique on (`change_request_id`, `head`, `target_branch`); verify migrate/rollback
- [x] 1.5 Add migration `change_request_claims` (change request, `head`, raw document text, parsed front matter jsonb, digest, membership, key, inserted_at) unique on (`change_request_id`, `head`); verify migrate/rollback
- [x] 1.6 Add migration `review_policy_versions` (project, `version`, document jsonb, `previous_version`, `note`, membership, key, inserted_at) unique on (`project_id`, `version`), deleted on project delete; verify migrate/rollback
- [x] 1.7 Add migration `change_request_verdicts` (one row per change request: `state`, `head`, `policy_version`, `reasons` jsonb, `inputs` jsonb, `computed_at`); verify migrate/rollback
- [x] 1.8 Add an index on `workflow_runs` (`project_id`, `workflow`, `source_commit`, `started_at`, `run_id`) if the existing indexes don't cover the required-workflow query; verify with `EXPLAIN` in a test or iex
- [x] 1.9 Add Ecto schemas for the six tables with changesets that never rewrite submitted values; verify schema unit tests

## 2. Project deletion

- [x] 2.1 Add `has_many :change_requests` to `Project` and a `no_assoc_constraint` returning `{:error, :has_change_requests}` from `Projects.delete_project/2`; map it to `409` in the controller/fallback; verify `projects_test.exs` and the controller test cover "only a closed change request" (`409`)
- [x] 2.2 Verify a project with only review policy versions deletes with `204` and its versions are gone (controller test)

## 3. Review policy validator and defaults

- [x] 3.1 Add the version 0 default document (D5 sketch with `evidence.required_workflows = []`, `scenarios.require_approved_intent = false`, and `scenarios.spec_gaps`, `coverage.unmapped_areas`, `coverage.undriven_features` all `ignore`) as a module constant and a function that fills omitted sections/keys to produce `effective`; verify a unit test that `effective(%{"format" => "review-policy/1"})` equals the default
- [x] 3.2 Add a `Shape`-style validator for `review-policy/1`: fixed sections and keys, unknown key and null `422`, outcome enums, `min_proof_level` enum, `approver` enum, required-workflow name rule/32 max/distinct, distinct `paths` globs, positive size limits, `lease_ttl` as `<n>s|<n>m|<n>h` from `1m` to `1h`, `require_approved_intent` and `regrade_merge_result` booleans; verify validator tests for each scenario in `specs/review-policy`
- [x] 3.3 Add the glob compiler (`**` whole segment only, `*`, `?`, reject `[ ] { } \`, whole-path match) and match `path` and `old_path`; verify unit tests for each glob scenario
- [x] 3.4 Define `active_settings` for this server version (everything except `scenarios.*`, `evidence.ignore_paths`, `coverage.*`, `merge.*`) as one list later phases extend; verify a unit test

## 4. Review policy context and API

- [x] 4.1 Add `GoodFlows.ReviewPolicies` with `current/1` (version 0 when none), `get_version/2`, `list_versions/2` (keyset via `GoodFlows.KeysetCursor`, newest first) and `write/4` (owner/admin check, `previous_version` compare-and-set, idempotent retry returning `200`, `409` on stale or concurrent); verify context tests incl. a concurrency test that two writes on version `1` give one `201` and one `409`
- [x] 4.2 Add `ReviewPolicyController` and JSON view for `GET/PUT /review-policy`, `GET /review-policy/versions`, `GET /review-policy/versions/:version`; put reads in the project-scoped read scope and the write in the `sk_` write scope with an owner/admin check before the body is read (like `SpritesCredentialController`); verify controller tests for `sk_` admin `201`, member `403`, `pk_` read `200` with `note` and `written_by` null / write `403`, `ck_` `403`, missing key `401`, unknown project `404`, unknown version `404`
- [x] 4.3 Enforce strict JSON body rules with a 256 KiB default limit; verify `413`, `415`, `400`, duplicate-key `422` tests

## 5. Change request records and lifecycle

- [x] 5.1 Add `GoodFlows.ChangeRequests` with `create/3` (draft, next number, default target branch, records opener), `get/2` by number, `list/2` (keyset by `number` desc, `state` and `source_branch` filters); verify context tests incl. concurrent creates and per-project numbering
- [x] 5.2 Add the create-body validator (`title`, `source_branch`, `target_branch`, `openspec_change` single slug, `links` reusing the workflow-run links validator); verify each field scenario returns `422` on the right key
- [x] 5.3 Add `transition/4` for `ready`, `draft`, `close`, `reopen` (reopen restores `closed_from_state`, same-state `200` with no event, other transitions `409`) writing a `change_request_events` row with membership and key; verify a table-driven test over every (state, action) pair
- [x] 5.4 Add `report_merge/4`: accept from `draft`/`open`, validate `merged_commit` and `target_branch`, store head, the verdict's state (`pending` when no head), `policy_version` and `reasons` at head, and `merged_without_mergeable_verdict`; same report on `merged` is `200` without re-evaluating flags, different is `409`; verify tests for `mergeable`, `needs_review`, no facts, retry and conflict
- [x] 5.5 Add `ChangeRequestController` and JSON views for create, list, show (with `description`, `verdict`, `history`), `ready`, `draft`, `close`, `reopen`, `merged`; reads in the read scope, writes in the `sk_` write scope; add a `:number` plug that returns `422` for non-positive-integer and `404` for unknown before reading the body; verify controller tests for every auth scenario (`401`, `403` for `pk_` writes and all `ck_`, `404`, `406`, `422`)
- [x] 5.6 Add `pk_` redaction in the change request, claims, Git facts and verdict views (every `user_id` and `links.threads` null, `description` null, claims `document` null and `front_matter` cut to `format`/`cr`/`head`/`door`, `changed_files` and `diff.files` null, reason `subject`/`message` null in the verdict and `merge`), never adding absent fields; verify a controller test per redaction scenario and that a following `sk_` read is unredacted

## 6. Git facts

- [x] 6.1 Add the `git-facts/1` validator: allowed keys, SHA format, `target.branch` equals the change request's `target_branch`, commits oldest first ending at `head` (empty only when `head == merge_base`), file entry keys and statuses, `old_path` only for `renamed`/`copied`, path rules and uniqueness, limits 1,000 commits / 10,000 diff files / 10,000 changed files per commit; verify validator tests for each scenario, incl. at-limit `201`
- [x] 6.2 Add `report_git_facts/4`: only in `draft`/`open` (else `409`), `201` on new head, `200` on equal digest (making that head current), `409` on a different document for a stored head, sets `head` and recomputes the verdict in the same transaction; verify context tests incl. a concurrent same-head test
- [x] 6.3 Add `POST .../git-facts` and `GET .../git-facts/:head` routes and controller actions with a 16 MiB default body limit and strict JSON rules; store reports keyed by change request, head and target branch, select the current target's report by default, and add `totals` to the read; verify `201`/`200`/`409`/`413`/`422`/`404` controller tests, incl. a second report for the same head on a new target branch

## 7. Claims

- [x] 7.1 Add a YAML parser dependency to `mix.exs` that can report or be guarded against anchors, aliases and tags; verify `mix deps.get` and a unit test that `&a`/`*a`/`!tag` front matter is rejected
- [x] 7.2 Add the `change-claims/2` parser: split `---` front matter from the body, require a mapping with exactly the ten keys, `format` `change-claims/2` only, never parse the body; verify tests for missing front matter, unknown keys and an older `format` (`422` on `format`)
- [x] 7.3 Add the front matter validator: `cr` equals the number or null, `door` enum, nonempty `door_reason`/`reach`, list shapes and counts (`safe_because` 1..100, `left_open` 0..100, `questions` 0..50, `decisions` 0..3), unique ids, `recommendation` in `options`, and `safe_because` entries (`fact`/`location`/`proof`, optional `evidence` of at most 20 relative strings and `covers` with exactly `capability`/`requirement`/`scenario`, nonempty `evidence` when `proof` is `ran`, `422` on `safe_because[<i>].evidence`); verify a test per scenario
- [x] 7.4 Add the three server checks: `head` equals the current head (no facts is `422` on `head`), every `decisions[].path` is a `path` or `old_path` in that head's `diff.files`, every `proof` is a known level; do not check `location`; verify tests incl. "location not checked" `201`
- [x] 7.5 Add `upload_claims/4`: only in `draft`/`open` (else `409`), store raw bytes, `201` new, `200` identical bytes, `409` different file for the same head, recompute the verdict in the same transaction; verify context tests
- [x] 7.6 Add `POST .../claims` (`text/markdown` only, else `415`; 1 MiB default limit) and `GET .../claims/:head` returning `document` and `front_matter`; verify controller tests, incl. `description` on show is null after the head moves

## 8. Verdict engine

- [x] 8.1 Add a pure verdict function taking (head, git facts, claims, required-workflow results, effective policy, policy version) and returning `state`, sorted `reasons` (`rule`, `outcome`, `subject` as an array of strings sorted unless the rule defines an order, `message`; `rule` plus `subject` unique) and `inputs` digests; precedence `pending > blocked > needs_review > mergeable`; verify unit tests for precedence and determinism
- [x] 8.2 Implement `git_facts_missing` (no facts for the current head and `target_branch`: `subject` `[]` and verdict `head` null when never reported, else `[<head>]` with `head` kept) and `claims_missing` (claims rules skipped when claims are missing); verify unit tests incl. facts stored only for another target branch
- [x] 8.3 Implement the required-workflows query (same project, `workflow`, `source_commit == head`, `source.dirty` not true, newest by `started_at` then `run_id`) and the `required_workflow_missing` (none or cancelled) / `required_workflow_failed` rules; verify DB-backed tests for passed, failed-then-passed, passed-then-failed, dirty and earlier-head runs
- [x] 8.4 Implement `one_way_door`, `proof_below_minimum`, `open_items`; verify unit tests per setting value incl. `ignore`
- [x] 8.5 Implement `path_match` (one reason per policy entry, `subject` `[glob, sorted matched paths...]`, `ignore` adds none) and `max_changed_files` / `max_changed_lines`; verify unit tests incl. rename out of a sensitive directory and the at-limit case
- [x] 8.6 Add `recompute/2` that loads inputs for the current head and upserts the verdict row, skipping `closed` and `merged`; call it from facts, claims, state changes (incl. reopen) and merge (verdict read only); verify context tests
- [x] 8.7 Hook the workflow run store so an upload whose `source.commit` is the head of a `draft`/`open` change request of the same project recomputes that verdict in the upload transaction; verify a test that a show right after the upload has no `required_workflow_missing` reason
- [x] 8.8 On a new policy version, recompute every `draft`/`open` change request of the project in the write transaction up to a configured count (default 100), otherwise enqueue a `PgFlow` job; verify tests for both paths and that inactive-setting changes leave `state`/`reasons` unchanged
- [x] 8.9 Add `GET .../verdict`; verify controller test with a `pk_` key returning `head` and `policy_version` and reasons with `subject` and `message` null

## 9. OpenAPI

- [x] 9.1 Add OpenAPI schemas for change request, list, create/merge request bodies, history entry, merge, verdict, reason, git facts document, claims read response (claims upload as `text/markdown`), policy version, policy write request and version list; verify `mix openapi.spec.json` (or the existing spec test) builds
- [x] 9.2 Annotate every new controller operation with its success and error responses (`400`, `401`, `403`, `404`, `406`, `409`, `413`, `415`, `422` where they apply, `403` and `409` on policy write); verify a test that fetches `/api/v1/openapi` and finds each new path and status

## 10. Integration checks

- [x] 10.1 Add an end-to-end controller test: create, report facts, upload claims, upload a passing `ci` run, admin writes a policy, ready, read verdict `mergeable`, report merge with `merged_without_mergeable_verdict` false
- [x] 10.2 Run `mix precommit` from `app/` and fix every failure
- [x] 10.3 Run `openspec validate add-change-request-core --strict` and confirm it is valid

## Workflow follow-up

- Share the `git-facts/1`, `change-claims/2` and `review-policy/1` contracts with the goodflows CLI change, with its decisions: `goodflows cr open --claims <file>` (opens a draft, reports Git facts, uploads claims, writes the number into the file's `cr`) and `goodflows cr claims <file>`, both defaulting `<file>` to `.goodflows/change-requests/<branch>/cr.md` (`.detached/<short SHA>/cr.md` on a detached HEAD); the server accepts only `change-claims/2`.
- Archive the change after review; `add-change-request-grading` then modifies the same capabilities.
