# Inspector Review-Update — add-workflow-run-storage

**Reviewed:** 2026-11-05
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Ready to implement

## Summary

The change adds authenticated upload, idempotent storage, and project-scoped list and show for goodci run-history documents, and it blocks deleting a project that still has those runs. Two specialists reviewed the artifacts against the canonical `projects` spec and the test-report ingestion code. Both critical findings were design mistakes that would have made a valid retry return 500 and would have rejected goodci's omitted optional keys. Those and the other findings are patched. `openspec validate add-workflow-run-storage --strict` passes. Task 7.3 records a purpose edit that can happen only after archive.

**Original counts:** Critical: 2 · Warning: 20 · Suggestion: 5
**Patches:** Auto-patched: 23 · User-guided: 0 · Model-recommended: 4 · Skipped: 0

## Scope inspected

- Proposal: `openspec/changes/add-workflow-run-storage/proposal.md`
- Design: `openspec/changes/add-workflow-run-storage/design.md`
- Tasks: `openspec/changes/add-workflow-run-storage/tasks.md`
- Deltas:
  - `openspec/changes/add-workflow-run-storage/specs/workflow-run-storage/spec.md`
  - `openspec/changes/add-workflow-run-storage/specs/projects/spec.md`
- Canonical specs consulted:
  - `openspec/specs/projects/spec.md`
  - `openspec/specs/test-report-storage/spec.md` (style and deletion language only)
- Other active changes consulted: none
- Code checked: `BodyParsers`, `TestReports`, `TestReports.Document`, `TestReports.Shape`, `TestReportParts`, `Spry.get_run/2`, `CreateProjectsMigrationTest`, `SentryScrubber`, `RequireParsedBody`, and goodci `history.rs` / `runner.rs` / `config.rs`

## Patches applied

23 findings were auto-patched. 0 were patched after user guidance. 4 were patched from model recommendations. 0 were skipped.

### Auto-patched

1. **Digest compare omitted `run_id`** — `design.md:88` → The conflict lookup is scoped to `(account_id, project_id, run_id)`. Task 3.3 retries the first run after a second run exists.
2. **Required-only object shape cannot store this document** — `design.md:118` → Optional keys may be absent and null is invalid. Nonempty lists need a minimum of 1. Names reject a whitespace-only string. OpenAPI `required` lists only required keys (task 6.1). Existing test-report specs do not use the new forms.
3. **Show promised byte equality for every key** — `specs/workflow-run-storage/spec.md:325` → JSON equality is for private keys. Public keys follow the redaction requirement, and a later `sk_` show still has `command` and `error`.
4. **Auth failures had no unread-body scenarios** — `specs/workflow-run-storage/spec.md:9` → Scenarios for 401 (including an exact retry), an invalid slug that does not read the body, and a `pk_` key on `GoodCases` (403). Task 4.3 names them.
5. **Malformed-body rules had three scenarios** — `specs/workflow-run-storage/spec.md:160` → Scenarios for streamed 413, non-JSON content type, malformed JSON, the read deadline, NUL, depth 9, JSON `1.0`, and an integer above 2^53-1. Task 4.2 attributes duplicate keys, NUL, and the integer cap to `normalize/1`.
6. **Idempotency scenarios skipped array order and concurrent conflicts** — `specs/workflow-run-storage/spec.md:222` → A reordered `results` array is 409. Concurrent uploads that differ in `duration_ms` yield one 201, one 409, and one row. Task 3.3 covers both.
7. **Task 3.3 disagreed with D3 on foreign keys** — `specs/workflow-run-storage/spec.md:249` → Project FK is 404. Any other FK is 503. A lost commit that left a row retries as 200. Task 3.3 matches that.
8. **Filter rules lacked scenarios** — `specs/workflow-run-storage/spec.md:306` → An unknown query parameter is ignored. An invalid `workflow` or `environment` is 422. Task 5.1 names both.
9. **List order did not require a keyset** — `specs/workflow-run-storage/spec.md:272` → Pages are a keyset on `started_at` DESC, `run_id` DESC, and a run uploaded after a page must not shift the next page. Scenarios cover equal `started_at` and an insert between pages.
10. **Test-report summaries had no order or field scenario** — `specs/workflow-run-storage/spec.md:343` → Two reports are ordered by `job` then `report_id`, with only the listed fields and no report contents.
11. **Canonical project purpose will drift after archive** — `tasks.md:42` → Task 7.3 edits the purpose after archive. The projects delta still has no Purpose section.
12. **A dropped connection became a 500** — `design.md:92` → `StorageErrors` rescues `DBConnection.ConnectionError` before the SQLSTATE clause. Task 1.2 keeps that as 503.
13. **A path-list raw-route match would skip GET query parsing** — `design.md:99` → Only a POST conn clause returns true, and it is defined before the conn-to-path delegation. The path-list form returns false for this route. Task 4.1 tests both forms.
14. **`CreateProjectsMigrationTest` would fail on `projects` down** — `tasks.md:17` → Roll the new migration down before `projects` and back up after it.
15. **`integer` columns overflow a spec-valid value** — `design.md:55` → `parallelism` and `max_in_flight` are `bigint`.
16. **Workflow and commit list indexes could not walk list order** — `design.md:67` → Added `(account_id, project_id, workflow, started_at DESC, run_id DESC)` and extended the commit index with `started_at DESC, run_id DESC`. `environment` and `outcome` stay unindexed.
17. **Show relied on index order for test reports** — `design.md:76` → The show query `ORDER BY job, report_id`. Task 5.2 asserts that order.
18. **Spry `get_run` was the wrong 404 analogy** — `design.md:132` → 404 unless the path matches the lowercase UUID. Do not downcase and look up. `Ecto.UUID.cast/1` accepts uppercase.
19. **`decode/1` does not reject duplicate keys** — `design.md:107` → The plug calls `normalize/1` after a successful decode. Non-integer numbers stay a validator check.
20. **Two outcome rejection rules had no scenario** — `specs/workflow-run-storage/spec.md:141` → `failed` with no failure, and `passed` with a cancelled result, are 422.
21. **Echo and error-cap rules had one scenario** — `specs/workflow-run-storage/spec.md:207` → A sentinel in `command` is absent from the body, logs, and error report. The 51st error is dropped.
22. **Empty lists and the 1,025-entry cap had no scenario** — `specs/workflow-run-storage/spec.md:58` → Empty `requested_jobs`, empty `commands`, and a 1,025-entry list are 422. Task 2.2 names the empty arrays.
23. **Extraction dropped `max_depth/0`** — `tasks.md:5` → `TestReports.Document.check_depth/1` and `max_depth/0` stay delegates to depth 16, and the plug test is in the unchanged-suite list.

### Model-recommended patches

1. **Command-cost fields were optional by grammar** — `specs/workflow-run-storage/spec.md:118`
   - **Chose:** Require `kind` and nonnegative `wall_ms`. Allow `step`, `cpu_user_ms`, `cpu_system_ms`, and positive `peak_rss_bytes`. Null is invalid. The step-cost scenario still omits `peak_rss_bytes`.
   - **Rationale:** goodci `CommandCost` always sends `kind` and `wall_ms` and skips the other fields with `skip_serializing_if`. A peak of 0 is omitted (`runner.rs`). Treating every field as required would reject real history files.
2. **`exit_code` range was unspecified** — `specs/workflow-run-storage/spec.md:104`
   - **Chose:** Null or a signed integer from -2147483648 through 2147483647. Out of range is 422. Design D5 and task 2.2 use the same bound.
   - **Rationale:** goodci stores `Option<i32>` (`history.rs`). `Shape`'s `{:int, nil}` would accept up to 2^53-1, so the bound has to be its own check. A nonnegative range would reject real exit codes.
3. **List `source` was not reconstructable from copied columns** — `specs/workflow-run-storage/spec.md:295`
   - **Chose:** `source` is null when `source_commit` is null. Otherwise include `commit`, and include `dirty` only when `source_dirty` is not null. `host` is the stored jsonb object.
   - **Rationale:** The list never reads `payload` (D6). goodci omits `dirty` when it is none and omits `source` without a commit. Emitting `"dirty": null` would make the summary differ from `data.document.source`.
4. **`406` was only in the design** — `specs/workflow-run-storage/spec.md:36`
   - **Chose:** One requirement: an `Accept` that does not allow JSON returns 406 from the API pipeline before the body is read. Keep 406 in D7. Do not add a 429 requirement. D7 notes that this route does not emit 429, while D8 may still retry a proxy 429.
   - **Rationale:** The `:api` pipeline already returns 406 (`router.ex`). Test-report OpenAPI lists it and the test-report spec does not, which is the drift this sentence avoids. There is no admission cap, so a 429 requirement would invent behavior.

### Skipped

_None._

## Critical

_None._

## Warning

_None._

## Suggestion

_None._

## Alignment notes

- **Other active changes:** No other unarchived change touches `projects` or `workflow-run-storage`.
- **Canonical specs:** The projects delta `FROM` heading matches `openspec/specs/projects/spec.md` line 59, and every existing deletion scenario is kept. The canonical purpose sentence still omits workflow runs. Task 7.3 updates it after archive, because a MODIFIED delta cannot change Purpose.
- **Codebase assumptions verified:** Workflow-run storage is not implemented. Test-report digest compare filters the full identity (`test_reports.ex`). `decode/1` only reports malformed JSON; `normalize/1` reports duplicate keys, NUL, and integers above 2^53-1. `Shape` objects require every key. `raw_body_route?/1` on a conn delegates to the path list, and both scrubber and `RequireParsedBody` pass the conn. `Spry.get_run/2` accepts uppercase UUIDs via `Ecto.UUID.cast/1`. `CreateProjectsMigrationTest` rolls `pools` and `test_reports` down before `projects`. goodci `schema_version` 1, the `results` key, partition bounds, name rule, 1,024-byte command and error text, and outcome derivation match the spec.

## What looks good

- Route, table, foreign-key name, `:has_workflow_runs`, and the `WorkflowRuns` module names agree across the proposal, design, and tasks.
- Idempotent 201, exact-retry 200, and conflicting 409 agree, including under concurrency. The body limit is 4 MiB and the depth limit is 8.
- Test reports stay a soft link on `(account_id, project_id, workflow_run_id)` with no foreign key, which matches reports that arrive before the run.
- Public-key redaction is limited to each result's `command` and `error`. List summaries exclude `results`.
- Helper extraction is required to leave test-report responses unchanged, and each task names the tests that check it.
