# Tasks

Depends on `add-change-request-core` being implemented (change requests, `git-facts/1`, `review-policy/1`, verdict and its recompute hook).

## 1. Scenario set storage

- [x] 1.1 Add a migration and schema for scenario set versions (change request, `source` intent|diff, `version`, `content`, `digest`, parsed front matter, `sections`, membership, key, time; unique on change request + source + version) and verify `mix ecto.migrate` and rollback run cleanly
- [x] 1.2 Add a migration and schema for scenario set decisions (change request, digest, `decision` approve|reject, `note`, membership, key, `channel`, time; indexed on change request + digest + time) and verify with a schema test
- [x] 1.3 Write the front matter extractor: split the first `---` block, parse YAML to a map, refuse a non-mapping; verify unit tests for no front matter, CRLF input, and a body that is never read
- [x] 1.4 Write the `qa-scenarios/2` validator with `Shape` field tables (`format` `qa-scenarios/2` only, `source`, optional `review`, scenarios with id/name/priority and intent-only `covers`, `change`, `specs` and `coverage` with optional row `reason` for intent, `branch`, `base`, short-or-full `revision` and `regressions` for diff, unknown keys refused, values never echoed); store scenario IDs in string form (positive integer or string, duplicates checked after conversion); refuse run-result keys (`run`, scenario `result`, `failed_step`, `evidence`, `reason`) with `422` on `content` and a message that results belong in a verify run; verify unit tests for each `422` scenario in the qa-scenario-sets spec
- [x] 1.5 Validate `sections` against the scenario IDs and coverage rows against scenarios (rows need `capability`, `requirement`, `scenario`, unique per set); verify unit tests for missing, extra, duplicate and uppercase entries and a row without `capability`
- [x] 1.6 Implement upload in a context module: SHA-256 over the raw `content` bytes, intent `change` must equal the linked OpenSpec change, next version or `200 duplicate` when the digest equals the current one, all under a per-change-request lock; verify context tests including the revert-to-older-file case
- [x] 1.7 Implement approve and reject decisions: change request `draft`/`open` (`409` otherwise, also for uploads), current-digest check (`409` otherwise), required `note` on reject, `scenarios.approver` from the current policy for both (`any`, `other_member` against the opener, `admin` via `AccountUser.admin?/1`), `200` with no row when equal (`decision` and `note`) to the digest's latest decision when that decision was made by the same membership, `channel` `cli`; verify tests for every approver value, the default policy, closed/merged `409` and reject without a note
- [x] 1.8 Implement `approved` per version as "the latest decision on this digest for this change request is `approve`"; verify tests for push-after-approval, edit-after-approval, revert, reject-after-approve and approve-after-reject
- [x] 1.9 Implement version comparison by scenario ID with `removed`/`demoted`/`changed`/`added`, `weakening`, and ordering weakening first, then removals, changed, added, each by id; verify unit tests from the spec scenarios

## 2. Scenario set API

- [x] 2.1 Add routes and a controller for upload, list, show version, approve (`intent/approvals`), reject (`intent/rejections`) and compare under `/api/v1/projects/:project/change-requests/:number/scenario-sets`, with `sk_`/`pk_`/`ck_` rules, `pk_` redaction of version `content` and `sections` (keeping `source`, `version`, `digest`, `approved`, scenario IDs and priorities) and of decision `note` and `decided_by.user_id`, 1 MiB body limit, `415`, and `404` for unknown change requests and for `diff/approvals` and `diff/rejections`; verify controller tests for each status code in the spec
- [x] 2.2 Add OpenAPI schemas for the request, version, list, approval and compare responses and register the operations in `GoodFlowsWeb.ApiSpec`; verify the OpenAPI test lists every route

## 3. Verify run storage

- [x] 3.1 Add a migration and schema for verify runs (project, `run_id`, `status` uploading|final, `document`, canonical digest, `source_commit`, `dirty`, `scenario_set_digest`, `scenario_set_source`, `merge_result` present flag, `finished_at`, uploading key, `expires_at`, `finalized_at`; unique on project + run_id; indexes on project + source_commit and project + digest) and verify migrate/rollback
- [x] 3.2 Add a migration and schema for verify run artifacts (run, artifact `id`, object key, size, sha256, content_type, `expired`) and a join table of change request ↔ counted run; verify schema tests
- [x] 3.3 Write the `verify-run/1` validator (required/optional keys, UUID, commits of 40 or 64 lowercase hex, RFC 3339 times and order, `source`, `scenario_set`, `results` entries, `features`, `drift`, `links` reusing the workflow-run links validator, `merge_result`, `workflow_run_id`, artifact entries with the 200 and 50 MB limits and `413`); verify unit tests for each validation scenario in the verify-runs spec
- [x] 3.4 Check `scenario_set.digest` against stored set versions of the same project and source, and that `results` holds exactly that set's scenario IDs, compared in string form, and `evidence` names declared artifacts; verify tests for unknown digest, other project, wrong source, missing and extra IDs
- [x] 3.5 Implement upload idempotency on (project, run_id) with `GoodFlows.JsonDocument.digest/1`: `201`, `200 duplicate`, `409` without revealing the stored run, one row under concurrency; verify tests including concurrent uploads

## 4. Verify run artifacts

- [x] 4.1 Reuse the cache object store to presign one PUT per artifact with `content-length`, `content-type` and `x-amz-checksum-sha256` signed in; return uploads and `expires_at` from the cache reservation TTL; a retry while `uploading` returns fresh URLs; verify tests that inspect the signed headers
- [x] 4.2 Store a run with empty `artifacts` as `final` immediately, and respond `503` for a run with artifacts when no bucket is configured; verify both cases
- [x] 4.3 Implement `POST …/verify-runs/:run_id/commit`: `404` for unknown, expired or other-key runs, HEAD each object, check length and SHA-256, `422` naming failing artifact IDs while staying `uploading`, `503` with `retry-after` when the store is down, `200` on retry of a final run; verify tests with the object store stub
- [x] 4.4 Make sure presigned URLs never reach logs, error bodies or Sentry; verify a test at `:debug` like the cache one

## 5. Verify run API

- [x] 5.1 Add routes and a controller for upload, commit, list (keyset paging with `GoodFlows.KeysetCursor` on `finished_at` desc, `run_id` desc; `commit`, `digest`, `status` filters; result counts) and show (artifact `expired`, download URLs for `sk_` on final unexpired artifacts); verify controller tests
- [x] 5.2 Implement `pk_` redaction on show and list: `reason` and `failed_step` null, `features[].entry_point` null (keeping `id` and `result`), `source.changed_files` null, `links.threads` null when present, no artifact URLs, absent fields never added; verify tests from the spec
- [x] 5.3 Add OpenAPI schemas and operations for every verify run route; verify the OpenAPI test

## 6. Feature index

- [x] 6.1 Add a migration and schema for feature index versions (project, `version`, `features` JSON, membership, key, time; unique on project + version) and verify migrate/rollback
- [x] 6.2 Write the sync validator (1 to 500 features, id/title/paths rules, globs compiled with the phase-1 policy glob compiler) and versioning with `200 duplicate` for an equal sync; verify unit and context tests
- [x] 6.3 Add routes, controller and OpenAPI entries for sync, show current (`404` before any sync), list versions and show version, with any `sk_` key syncing and `pk_` reading; verify controller and OpenAPI tests
- [x] 6.4 Implement file-to-feature mapping over the head's `git-facts` diff (`path` and `old_path`, skip `evidence.ignore_paths`) returning unmapped paths and mapped feature IDs; verify unit tests for multi-feature, unmapped, ignored and renamed files

## 7. Counting runs and verdict rules

- [x] 7.1 Implement "runs that count" for a change request at head H (final, clean, no `merge_result`, digest is the graded intent or current diff digest, commit is H or in `git-facts.commits` with every later commit matching `ignore_paths`); verify tests for each D7 scenario including rebase and docs-only commits
- [x] 7.2 Pick the newest counted run per scenario by `finished_at`, then `run_id`; verify the retry-after-failure and newer-not_run tests
- [x] 7.3 Add verdict rules `scenario_set_approval`, `scenario_set_missing`, `diff_only_set`, `diff_set_revision` (fires when the diff `revision` is not the head or a prefix of it), `scenario_results_missing`, `must_failed`, `should_failed`, `should_not_run`, `spec_gap`, `unmapped_area`, `undriven_feature` and `feature_index_missing`, each using its policy setting and the array `subject` the spec gives (`[<source>, <id>]` for scenario rules); verify a rule-table test per rule, a test with the same scenario ID in both sets, a precedence test combining `pending` and `blocked`, and that policy version 0 with no scenario set and no feature index adds no grading reason
- [x] 7.3a Skip `spec_gap` for a `no_check` row when the claims at the head have a `safe_because` entry whose `covers` equals the row's `{capability, requirement, scenario}` and whose `proof` is at or above `claims.min_proof_level`; use `subject` `[capability, requirement, scenario]`; verify tests for covered at the minimum (no reason), covered below it (`spec_gap` and `proof_below_minimum`), covers naming another scenario (`spec_gap`), and that a claims upload recomputes the verdict
- [x] 7.3b Run `scenario_set_approval` and `scenario_set_missing` while `git_facts_missing` fires (head null), and no other grading rule; verify tests for an unapproved intent set before facts (two reasons) and an approved one (only `git_facts_missing`)
- [x] 7.4 Add `scenarios`, `coverage` and `counted_runs` to the verdict response and the approved digest, counted run IDs and index version to the stored input digests, with `pk_` redaction (incl. `coverage.unmapped_areas` null and each mapped feature's `id` null, keeping `driven`); verify controller tests for `sk_` and `pk_`
- [x] 7.5 Record counted runs per change request whenever a verdict is computed; verify a test where a run counted at an earlier head stays recorded
- [x] 7.6 Recompute affected `draft` and `open` verdicts in the transactions for set upload, approval, rejection, run commit or no-artifact upload, and feature index sync (inline up to the configured count, default 100, otherwise in a background job); verify one test per trigger
- [x] 7.7 Mark `scenarios`, `evidence.ignore_paths` and `coverage` as active settings in the policy response; verify the policy read test and the review-policy delta's `Active settings grow by phase` scenarios

## 8. Retention and project deletion

- [x] 8.1 Add a sweep job like `GoodFlows.Caches.Sweep` that deletes expired `uploading` runs and queues their objects, deletes artifact objects 30 days after every counting change request is `merged` or `closed` or 14 days after `finalized_at` when none counted, and marks rows `expired`; verify sweep tests for each retention scenario, a reopened change request, and a store failure retried later
- [x] 8.2 Extend `GoodFlows.Projects.delete_project/2` so verify runs return `{:error, :has_verify_runs}` (`409`) and feature index versions are deleted with the project; verify the projects deletion scenarios, including the feature-index-only `204`
- [x] 8.3 Update the project delete operation's OpenAPI `409` description to name change requests and verify runs; verify the OpenAPI test

## 9. Integration

- [x] 9.1 Add an end-to-end controller test: open a change request, report facts, upload and approve an intent set, sync a feature index, upload a run with an artifact, PUT, commit, and read a `mergeable`-or-`needs_review` verdict whose `counted_runs` names the run
- [x] 9.2 Run `mix precommit` from `app/` and fix every failure

## Follow-up

- Share design D3a with the goodflows CLI change: `cr open` reuses the branch's one `draft`/`open` change request or creates a draft with `--openspec-change`, and needs no claims file; `cr claims` reports Git facts for HEAD first. It replaces the `cr open` and `cr claims` lines in `add-change-request-core`'s design D1 and D4 and its Workflow follow-up.
- Archive after `add-change-request-core`. This change's `projects` delta modifies the same requirement as core's and already includes core's change-request blocker, so archiving it second keeps both.
