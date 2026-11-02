# Proposal

## Why

`suite_started` filters are how a stored report says which slice of a suite ran, but the accepted tag names are five GoodCases ExUnit categories (`chrome`, `goodaudit_integration`, `athena_preview`, `chromic_teardown`, `qpdf`). Any other project's boolean include or exclude is rejected with 422, so the project-scoped ingest API only describes one suite.

## What Changes

- Accept any suite filter tag that is an identifier, with a boolean value, on `include` and `exclude`. Keep the five existing names valid.
- Reject a tag that is not an identifier, reject a filter value that is not a boolean, and cap each of `include` and `exclude` at 256 entries.
- Keep per-test tags, parameter values, logs, exception payloads and assertion values out of the document.
- Publish the identifier rule and the list cap (`maxItems`) in the generated OpenAPI schema in place of the five-name enum.

## Capabilities

### Modified Capabilities

- `test-report-storage`: suite filter tags change from a closed GoodCases list to bounded identifiers with boolean values.

## Impact

- `GoodFlows.TestReports.Validator` (`@filter_tags` and `filter_tags/0`), `GoodFlows.TestReports.Shape` (new list length bound), `GoodFlowsWeb.Schemas.TestReportParts` (`maxItems`) and the generated `TestReportEvent` schema, `app/lib/good_flows_web/api_spec.ex` (the test-report description), and the tests `app/test/good_flows/test_reports/validator_test.exs`, `app/test/good_flows_web/controllers/api/v1/test_report_controller_test.exs` and `app/test/good_flows_web/controllers/api/v1/openapi_test.exs`.
- Previously accepted reports stay accepted. A tag outside the old list, such as `slow`, becomes valid when its value is boolean. A non-boolean value stays 422.
- This repo does not edit companions. `goodci` copies the tag vocabulary in `FILTER_TAGS` and rejects anything outside it before a snapshot is frozen (`src/reporting/contract.rs`). `goodcases` drops every filter outside `@categories` in `GC.TestTimingFormatter`. Both have to follow this contract or a new tag never gets uploaded. Deploy this server before a CLI that emits the wider set. The GoodCases formatter change belongs in its open `publish-test-timings` change so that work does not put the five names back.
- Follow-ups (tracked here; no issues are opened in other repos from this change):
  - `goodci`: drop `FILTER_TAGS` in `src/reporting/contract.rs`, check the identifier grammar instead, and bump `CONTRACT_VERSION`.
  - GoodCases: drop `@categories` from `GC.TestTimingFormatter` (in its `publish-test-timings` change) so every boolean identifier filter is recorded.
  - Rollback caveat: after a server rollback, an exact retry of an already-stored report that carries a tag outside the old five names gets `422`, not `200` with `duplicate: true`, because validation runs before the digest comparison.
