# Inspector Review-Update — adopt-test-timings-contract

**Reviewed:** 2026-11-05
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Ready to implement

## Summary

The change replaces `exunit-timings` with the runner-neutral `test-timings/1` contract and purges stored legacy rows. After the patches, the contract states the envelope rules the server and the `workflow_run_id` uuid column already enforce, limits 422 to decoded contract failures, and the timestamp design matches Elixir's byte-sized binary match. `openspec validate adopt-test-timings-contract --strict` passes. Nothing is left unpatched.

**Original counts:** Critical: 3 · Warning: 19 · Suggestion: 3
**Patches:** Auto-patched: 21 · User-guided: 0 · Model-recommended: 4 · Skipped: 0

## Scope inspected

- Proposal: `openspec/changes/adopt-test-timings-contract/proposal.md`
- Design: `openspec/changes/adopt-test-timings-contract/design.md`
- Tasks: `openspec/changes/adopt-test-timings-contract/tasks.md`
- Deltas:
  - `openspec/changes/adopt-test-timings-contract/specs/test-timing-contract/spec.md`
  - `openspec/changes/adopt-test-timings-contract/specs/test-report-storage/spec.md`
- Canonical specs consulted:
  - `openspec/specs/test-report-storage/spec.md`
  - goodflows `openspec/specs/test-timing-contract/spec.md` (repo path `goodci`)
- Other active changes consulted: none

## Patches applied

21 findings were auto-patched. 0 were patched after user guidance. 4 were patched from model recommendations. 0 were skipped.

### Auto-patched

1. **Timestamp match used bit sizes** — `design.md:92` → D4 now matches `binary-size` segments, parses ASCII digits to integers, and keeps `must be a string` for a non-binary. `::4` is four bits and would have rejected every `started_at`.
2. **Wrong format was not a single specified error** — `specs/test-report-storage/spec.md:67` → a present non-`test-timings/1` format is exactly one `is invalid`. A missing `format` stays `is required`. A first record that is not `suite_started` stays an ordering error. Design D5 and task 2.4 match.
3. **Meta faults had no required messages** — `specs/test-report-storage/spec.md:67` → the four D2 messages are required on the `meta` path only, with one scenario each. Task 2.2 names them.
4. **Null and float meta values had no scenarios** — `specs/test-timing-contract/spec.md` → `{"async": null}` is accepted; `1.5` is rejected. `meta: null` stays a separate "not an object" case.
5. **Timestamp bounds were prose only** — `specs/test-timing-contract/spec.md` → scenarios for 64 bytes, 65 bytes, and `2026-11-04T12:00:00.Z`.
6. **Proposal invented Shape kinds** — `proposal.md:41` → Impact now says `{:optional, spec}` and `:meta` are new, `path` and `runner` are composed, and `:timestamp` is rewritten.
7. **Filter error paths were dropped with the old requirement** — `specs/test-report-storage/spec.md` → a bad tag is 422 on `tag` without echoing it, a non-boolean is 422 on `value`, and an extra key is `has an unknown field` on the entry. The REMOVED reason points at those paths. Task 2.5 names them.
8. **Top-level `async` and `parameter_id` were not called out** — `specs/test-timing-contract/spec.md` → a top-level key, including null, is an unknown key; the same keys inside `meta` are accepted. Task 3.2 names the storage "Unknown nonexecuted metadata" scenario.
9. **Task 4.2 banned strings the negative tests must send** — `tasks.md:25` → `run_id`, `module_started`, `unfinished_modules`, and `exunit-timings` are allowed only in the four negative scenarios and the purge test.
10. **Interruption-without-finish was not tasked** — `tasks.md:19` → task 3.3 verifies that scenario on a report whose only incompleteness is ending on `interrupted`.
11. **Bounded-document scenarios were not named** — `tasks.md:25` → task 4.2 verifies "Documents are bounded and strictly encoded".
12. **`suite_finished.duration_us` looked required** — `specs/test-timing-contract/spec.md:269` → it is null or an integer from 0 to 2^53-1, matching `OptUInt`.
13. **Retry scenario contradicted pairing** — `specs/test-timing-contract/spec.md` → the two pairs use distinct `execution_id`s and the same group, path, and name. Design D7's `failed.json` says the same.
14. **Task 1.2 dropped `:relative_file` too early** — `tasks.md:6` → the OpenAPI clause stays until task 2.1 stops the validator emitting that kind. Design D7 says the same.
15. **OpenAPI timestamp text was not tasked** — `tasks.md:6` → task 1.2 sets the `:timestamp` description to the contract grammar.
16. **Example test was pointed at the wrong file** — `tasks.md:26` → "the OpenAPI request example is a valid report" is in `validator_test.exs`.
17. **Redaction sentinel used `describe`** — `tasks.md:27` → the sentinel moves to `name` or a string `meta` value. Meta key `stack trace` stays a 422 that does not echo the key.
18. **Purge test could no-op** — `tasks.md:31` → insert both formats with `Repo.insert_all`, run the DELETE SQL, and do not treat `Ecto.Migrator.up` as proof.
19. **`grep exunit` was the wrong check** — `tasks.md:26` → from `app/`, `grep -rn exunit-timings lib`. That still allows the runner name `exunit`.
20. **Double-start scenario was dropped** — `specs/test-timing-contract/spec.md:238` → "Started twice" is restored beside "Started again after finishing".
21. **Non-object `filters` had no scenario** — `specs/test-timing-contract/spec.md` → an array or string `filters` is rejected. Task 2.5 includes it.

### Model-recommended patches

1. **Contract 422 swallowed transport and auth** — `specs/test-timing-contract/spec.md:10` → a decoded contract failure is 422. Auth, project selection, body size, malformed JSON, idempotency, admission, and storage stay on `test-report-storage`. The 32 MiB cap is 413 and bad UTF-8 is 400, not contract failures.
   - **Chose:** Narrow "every rejection is 422" to decoded documents, and point the other statuses at `test-report-storage`.
   - **Rationale:** The proposal leaves transport, limits, authentication, and idempotency unchanged. Calling every failure a 422 would have contradicted the storage spec's 400, 401, 403, 404, 409, 413, and 503.
2. **Envelope value rules were unstated** — `specs/test-timing-contract/spec.md` → `workflow_run_id` is a lowercase hyphenated UUID; names are 1–64 bytes without Unicode controls; `environment` is null or that name; `commit` is null or 40 or 64 hex digits; `branch` is null or 1–256 bytes; `dirty` and `truncated` are null-or-boolean and boolean; `records` is an array; report ids use the identifier grammar. Scenarios cover the cases collection and the controller already reject. Task 4.2 keeps those tests, and task 4.3 keeps the ApiSpec bullets.
   - **Chose:** Restate the current server rules, including a branch that does not ban control characters beyond U+0000.
   - **Rationale:** Design says those rules do not change, and `test_reports.workflow_run_id` is a uuid column, so a bad id would 500 instead of 422. goodflows `valid_branch` also rejects other controls, but this server does not, and collection never freezes those branches. Copying the stricter rule would be a new rejection.
   - **Superseded:** design D8 later adopted goodflows' rule: `source.branch` now rejects every Unicode control character (Cc), because the server must accept exactly what collection accepts. The branch clause of this patch no longer holds.
3. **Purge could race an old node** — `design.md:134` and the storage purge requirement → drain nodes that still accept `exunit-timings`, then delete, then serve the new validator. There is no second purge.
   - **Chose:** Require drain-then-migrate rather than weaken "the project is then deletable".
   - **Rationale:** The proposal says the deploy deletes every legacy row so a project with only those reports becomes deletable. A rolling window would leave a row that still blocks delete. Drain makes that sentence true.
4. **Moduledoc cites a spec that archive creates** — `design.md` and task 2.1 → the citation stays `openspec/specs/test-timing-contract/spec.md`, and the file is not created early.
   - **Chose:** Keep the canonical path and say archive creates it.
   - **Rationale:** The current validator already cites the canonical spec path. Creating the file under `openspec/specs/` before archive would put an unpublished spec in the main tree.

### Skipped

_None._

## Critical

_None._

## Warning

_None._

## Suggestion

_None._

## Alignment notes

- **Other active changes:** none. No conflict.
- **Canonical specs:** `test-report-storage` is modified on purpose (format, completion counters, filter requirement removed, purge added). The new contract delta follows goodflows' `test-timing-contract` and adds the server-only acceptance and error-rendering scenarios.
- **Codebase assumptions verified:** `Validator` envelope types and `@uuid`; `Shape` `no_control` on names and not on `branch`; `test_reports.workflow_run_id` is `:uuid`; `TestReportParts` timestamp description is "UTC ISO 8601 timestamp"; the OpenAPI example test is in `validator_test.exs`; the redaction sentinel is written to `describe`; migration tests pass an explicit version list to `Ecto.Migrator.run`. goodflows `contract.rs` is at `CONTRACT_VERSION` `2026-11-04-generalize-test-timings` (`SUITE_FINISHED` duration is `OptUInt`; `valid_timestamp` accepts `t`/`z`, `-00:00`, and second 60).

## What looks good

- The acceptance set is defined as goodflows collection's, and the dropped server rules (counts tally, duration versus outcome, relative `file`, `files`, `times_us`) are named.
- Design D1 maps each `contract.rs` field type onto an existing Shape spec, and pairing uses separate group and test id spaces.
- `meta` errors stay on the `meta` path so a submitted key is never echoed.
- The purge deletes by `payload->>'format'` rather than emptying the table, and `down` is a no-op because the rows cannot be restored. (Superseded by task 7.1: `down` now raises `Ecto.MigrationError`.)
- Completion still depends only on `truncated`, `suite_finished`, the unfinished counters, and the bail events.
