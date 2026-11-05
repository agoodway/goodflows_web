# Proposal

## Why

goodflows v0.6.0 replaced the ExUnit-shaped `exunit-timings` report with the runner-neutral `test-timings/1` contract (goodflows change `2026-11-04-generalize-test-timings`), so ExUnit and Jest, and later other runners, publish through one format. goodflows now owns that contract and expects this server to mirror it. Until the server does, every upload from a v0.6.0 CLI is rejected with 422 and recorded by the client as a permanent `rejected_by_server`.

## What Changes

- **BREAKING** `POST /api/v1/projects/:project/test-reports` accepts only `test-timings/1`. `exunit-timings` is rejected as an unsupported format, with no compatibility window.
- The server accepts exactly what goodflows collection accepts. No server-only rule may reject a report that collection froze, because such a rejection cannot be retried or repaired on the client. This removes these current server rules:
  - `suite_finished.counts` must equal the tally of `test_finished` outcomes. Jest retries write one pair per attempt but count only the final attempt.
  - `duration_us` must be set exactly for passed and failed tests. It is now any nonnegative integer or null.
  - `file` must be relative and free of `..`. It is now text or null.
  - The `files` and `times_us` summary cross-checks. Those fields no longer exist.
- Record shapes follow the contract:
  - `run_id` becomes `suite_id`.
  - `module_*` events become `group_*`, and `describe` becomes `path[]`.
  - Outcomes are `passed`, `failed`, `skipped` and `errored`.
  - `suite_started` gains `runner {name, version}`, and `filters` becomes nullable.
  - `unfinished_modules` becomes `unfinished_groups`.
  - Every record may carry a flat, bounded `meta`. Runner-specific fields (`async`, `parameter_id`, `setup_all`, `max_cases`, `schedulers`, versions, ExUnit time buckets) move into it.
- Group and test `execution_id`s are separate namespaces.
- `started_at` is checked against the contract's exact timestamp grammar instead of `DateTime.from_iso8601/1`, which disagrees with the contract in both directions.
- Completion counts `unfinished_groups` in place of `unfinished_modules`. The rule is otherwise unchanged.
- **BREAKING** A migration deletes every stored `exunit-timings` report. Storage is greenfield and has no read API. Legacy rows would otherwise keep their projects undeletable and leave any future reader with two payload shapes.
- OpenAPI documentation, the request example and the API description describe `test-timings/1`, including `meta`.
- No new columns. `runner` and `meta` stay inside `payload`. The publisher's User-Agent is neither enforced nor stored.

Out of scope: real reporter output as fixtures (hand-written cases now; captured output later), read or query APIs, and changes to transport, limits, authentication, admission or idempotency.

## Capabilities

### New Capabilities
- `test-timing-contract`: The `test-timings/1` wire format as accepted by this server. It mirrors goodflows' `test-timing-contract` capability: envelope shape, event vocabulary and order, core field types, `meta`, filters, pairing, limits and the completion rule.

### Modified Capabilities
- `test-report-storage`: The format, field allowlist, filter-tag and completion requirements move out to `test-timing-contract`. Storage keeps authentication, project selection, idempotency, deletion blocking, limits and acknowledgements, and refers to the contract for what a valid document is. Its scenarios stop naming ExUnit-only fields.

## Impact

- Code: `GoodFlows.TestReports.Validator` (new spec tables), `Consistency` (rewritten to identity, order, pairing and unfinished counts), `Completion`, `Shape` (new `{:optional, spec}` field marker and a `:meta` check; `path` is a list of text and `runner` is an object; the existing `:timestamp` check is rewritten), module docs in `GoodFlows.TestReports` and the controller.
- API docs: `GoodFlowsWeb.Schemas.TestReportParts`, `TestReportRequest` (example), `TestReportEvent`, and the test-report section of `GoodFlowsWeb.ApiSpec`.
- Data: a new migration that deletes `exunit-timings` rows from `test_reports`. The table schema is unchanged.
- Tests: the JSON fixtures under `test/support/fixtures/test_reports/`, `GoodFlows.TestReportFixtures` (including `large_report/2`), `validator_test.exs` (rewritten around the contract's scenarios), and any controller, plug, limit, redaction or concurrency test that builds records by hand.
- Clients: requires goodflows ≥ v0.6.0. Older CLIs are rejected with 422.
