# Inspector Review-Update — generalize-test-report-filters

**Reviewed:** 2026-11-01 (second pass, after commits through `9107a1e`)
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Ready to implement

## Summary

This second pass re-checked the change against the current code (HEAD `9107a1e`). Since the first pass, the only change to the code is a `RequireParsedBody` plug on the write pipeline, and it skips test report uploads. The validator, `Shape`, `TestReportParts`, `ApiSpec` and the test fixtures have not changed. Every code claim in the change still holds. The remaining gaps were all precision gaps:
- error paths were not the exact rendered keys the tests must assert;
- the new list bound was not wired through `Shape` and `TestReportParts` in enough detail;
- nothing said how the cap interacts with per-entry errors;
- the proposal's Impact list was incomplete.

**Original counts:** Critical: 0 · Warning: 2 · Suggestion: 3
**Patches:** Auto-patched: 4 · User-guided: 0 · Model-recommended: 1 · Skipped: 0

## Scope inspected

- Proposal, design, tasks, delta `specs/test-report-storage/spec.md`
- Canonical: `openspec/specs/test-report-storage/spec.md:131` (MODIFIED requirement text matches apart from the intended wording)
- Other active changes: `add-sprite-pools` (no `test-report-storage` delta; no conflict)
- Archived: `archive/2026-11-01-store-test-timings/design.md:63` (D1 tag enum, superseded as stated)

## Patches applied

### Auto-patched

1. **Error paths in tests are not the rendered keys** (Warning). `tasks.md:5,13` named `filters.include`, but `assert_error/3` (`validator_test.exs:21`) matches exact rendered keys such as `report.records[0].filters.include[0].tag`. Task 1.1 now names the target test (`suite_started fields are checked`, `validator_test.exs:539`) and the full paths.
2. **Controller 422 assertion is vague** (Suggestion). `tasks.md:17`: task 1.3 now asserts `body["errors"]["report.records[0].filters.include[0].tag"] == ["has invalid format"]` and an unchanged `report_count/0`, matching the existing controller-test style (`test_report_controller_test.exs:30,347`).
3. **The list bound is underspecified in `Shape` and `TestReportParts`** (Warning). `tasks.md:16`: task 1.2 now requires:
   - a new `to_schema({:list, spec, opts}, events)` clause, because `test_report_parts.ex:50` only matches `{:list, spec}`, and that clause stays for `files`;
   - an update to the `Shape` moduledoc (`shape.ex:11`).
4. **Impact list incomplete** (Suggestion). `proposal.md:22` now lists `Shape`, `TestReportParts`, the controller test and the OpenAPI test.

### Model-recommended patches

1. **How the 256 cap interacts with per-entry errors.** Affected: `specs/test-report-storage/spec.md:27,55`, `design.md:35`, `tasks.md:13,16`.
   - **Chose:** an over-cap list gets only `must not have more than 256 entries` on the list path, and its entries are not checked. The scenario now names the message and an example path. Task 1.1 asserts that 257 `ok?` entries give that single error.
   - **Rationale:** This mirrors the existing `records_errors/2` (`validator.ex:272-277`), which short-circuits the same way for `report.records`. It also keeps the cap error from being pushed out by the 50-error render limit, which would happen if 257 invalid entries were each reported first.

### Skipped

_None._

## Critical

_None._

## Warning

_None._

## Suggestion

_None._

## Alignment notes

- These code claims were verified at HEAD:
  - `@filter_tags` and `filter_tags/0` are at `validator.ex:25,47-49`, and nothing else calls them.
  - The filter spec is at `validator.ex:192,204`.
  - `identifier/0` (`validator.ex:92`) has the `\A...\z` regex at `:28`.
  - `string_error/2` checks size before format (`shape.ex:113-123`).
  - `pattern/1` publishes `^...$` (`test_report_parts.ex:94-96`).
  - The oneOf title `TestReport_SuiteStarted` is built at `test_report_parts.ex:25`.
  - In `api_spec.ex`, the `records` bullet ends at `:141` and "parameter values are not accepted" is at `:150`.
  - The fixtures use only `qpdf`, `athena_preview` and `chrome`.
  - The depth limit of 16 is in `document.ex:26`.
- Commit `9107a1e` (RequireParsedBody → 415) excludes test report uploads and does not affect this change.
- `openspec validate generalize-test-report-filters --strict` passes after the patches.

## What looks good

- It reuses the suite-id grammar, so there is no second string rule.
- It is fully backward compatible: the five old tags still match the grammar.
- The deploy order across the server, goodci and goodcases is explicit, and the companion work stays out of this repo.
- It needs no migration, and the rollback has a documented retry caveat.
