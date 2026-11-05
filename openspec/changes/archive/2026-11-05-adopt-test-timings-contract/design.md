# Design

## Context

See proposal.md for motivation, and `specs/test-timing-contract/spec.md` for the accepted document. Current state:

- `GoodFlows.TestReports.Validator` holds the `exunit-timings` spec as maps of `GoodFlows.TestReports.Shape` specs (`envelope_spec/0`, `event_spec/1`, private `event_fields/1`). `Shape.check/3` types values, requires every key of an `{:object, fields}` and rejects unknown keys with fixed messages on the enclosing path. `{:fun, fun, kind}` covers custom checks (`:counts`, `:relative_file`, `:timestamp`, `:records`).
- `GoodFlows.TestReports.Consistency` runs after the structural pass. It checks identity, order, partition agreement, pairing (one `used` set for tests and modules), the `duration_us`/outcome rule, and agreement of `counts`, `files` and `times_us` with the events.
- `GoodFlows.TestReports.Completion` reads `unfinished_modules`.
- `GoodFlows.TestReports.Document` already enforces the encoding rules: duplicate keys, U+0000, integer magnitude ≤ 2^53-1 (both signs) and depth. Floats pass `Document` and are rejected wherever a spec expects an integer. `Jason` decodes the token `-0` as the integer `0`, whereas goodflows' serde_json reads it as a float (D8).
- `GoodFlowsWeb.Schemas.TestReportParts` generates the OpenAPI schema from the validator's specs, so the docs follow the tables automatically once the Shape kinds are covered.
- goodflows' reference implementation is `src/reporting/contract.rs` (the per-event table, `check/2` and `valid_meta/1`) and `Validator::push` in `src/reporting/collect.rs` (order, identity, pairing and unfinished counts). Its `CONTRACT_VERSION` is `2026-11-04-generalize-test-timings`.
- `test_reports` stores the validated body in `payload` JSONB, so there is no `format` column. Every stored row today is `exunit-timings`.

## Goals / Non-Goals

**Goals:**
- The set of accepted documents equals goodflows collection's. The server keeps its own error rendering (paths, fixed messages, up to 50 errors), which is not part of that set.
- The validator reads like a transcription of `contract.rs`, so the next contract revision is a table diff on both sides.

**Non-Goals:**
- Error codes that match goodflows'. The server keeps its path-keyed `ValidationErrorResponse`.
- Changes to the envelope's own field rules (`workflow_run_id`, names, `source`, `job_status`), body handling, admission, idempotency or the table's columns, except where the accepted set must equal goodflows' (D8).

## Decisions

### D1. The validator is a mirror of `contract.rs`, pinned by name

`Validator` keeps its structure (spec maps per event) but its tables become the `test-timings/1` ones: `common_fields/0` (`event`, `suite_id`, `report_id`, `received_offset_us`, optional `meta`), and one field map per event matching `SUITE_STARTED`, `GROUP_STARTED` (+`GROUP_FINISHED_EXTRA`), `TEST_STARTED` (+`TEST_FINISHED_EXTRA`) and `SUITE_FINISHED`. `interrupted` and `max_failures_reached` have only the common fields. Field types map as follows:

| contract.rs | Shape spec |
|---|---|
| `Text` / `OptText` | `{:string, min: 1, max: 4096}` / `{:nullable, …}` |
| `Identifier` | existing `identifier()` |
| `UInt` / `OptUInt` | `{:int, 0}` / `{:nullable, {:int, 0}}` |
| `OptInt` | `{:nullable, {:int, nil}}` |
| `ExecutionId` / `Line` / `PartitionCount` | `{:int, 1}` / `{:nullable, {:int, 1}}` / `{:nullable, {:int, 1}}` |
| `Bool` / `Outcome` | `:boolean` / `{:enum, ~w(passed failed skipped errored)}` |
| `Partition` | existing `{:nullable, partition()}` |
| `Path` | `{:list, text(), max: 32}` |
| `Runner` | `{:object, %{"name" => identifier(), "version" => {:nullable, {:string, max: 128}}}}` |
| `Filters` | `{:nullable, {:object, %{"include" => filter, "exclude" => filter}}}` |
| `Counts` | existing `{:fun, …, :counts}` over the new outcomes |
| `Timestamp` | `{:fun, …, :timestamp}`, rewritten (D4) |
| `Format` | `{:enum, ["test-timings/1"]}` |
| `meta` | `{:optional, {:fun, …, :meta}}` (D2) |

The moduledoc states that the module mirrors goodflows `src/reporting/contract.rs` at `2026-11-04-generalize-test-timings` and `openspec/specs/test-timing-contract/spec.md`. A `@contract_version` attribute holds that name so it appears in one place. Archive creates that spec file; do not add it under `openspec/specs/` while this change is open. `start_fields/1` becomes keyed by kind (`"test_finished"`, `"group_finished"`) and returns the started table's keys. That matches contract.rs's `base`, which excludes the common keys and `meta`.

`file` loses its relative-path check, and the `:relative_file` kind is deleted.

*Alternative:* a separate `TestTimings.V1` module beside the old validator. Rejected, because nothing else accepts the old format, so keeping it would leave dead code.

### D2. `meta` is an optional key with whole-object errors

`Shape` gains `{:optional, spec}`, which is valid only as a field of `{:object, fields}`. An absent key is accepted, and a present key (including `null`) is checked against `spec`. `TestReportParts` leaves optional keys out of `required`. Only `meta` uses it.

The `:meta` check reports every fault on the `meta` path itself, so a submitted key name never appears in an error path:

- not an object → `must be an object`
- more than 32 keys → `must not have more than 32 keys`
- a key outside the identifier grammar → `has an invalid key`
- a value that is an array, object, float or string over 256 bytes → `has an invalid value`

Integer magnitude, NUL characters and duplicate keys are enforced earlier by `Document.normalize/1`, which reports a value error on the value's own path. That path can run through submitted keys (an unknown key, or a `meta` key such as `{"db_password": 99999999999999999999}`), so `Validator` rewrites every `Document` error before rendering it:

- any path below a record's `meta` (`["report", "records", i, "meta", _ | _]`) becomes `has an invalid value` on that `meta`;
- any other path is cut back at the first key, or index, that the enclosing spec does not define (inside a record, any key of any event counts as defined), so the error lands on the enclosing object with its fixed message (`{"x": 99999999999999999999}` in `source` is `source`, `is out of range`).

No submitted key name can therefore reach an error path. Because the range is checked before `:meta` runs, the `:meta` check itself does not repeat it.

*Alternative:* report value errors at `meta.<key>`, the way `counts` does. Rejected, because `counts` keys come from a closed list, while `meta` keys are arbitrary submitted text.

### D3. Consistency keeps only the contract's cross-record rules

`Consistency.check/1` keeps these rules:
- identity (record `suite_id` and `report_id` equal the envelope's)
- position (the first record is the only `suite_started`, and a `suite_finished` is the only one and last)
- partition agreement

Pairing changes:
- State is `%{groups: %{open: %{}, used: MapSet}, tests: %{…}}`, chosen by event kind.
- A started event whose id was already used by its kind is `is already used`.
- A finish with no open start of its kind is `has no matching start event`.
- A finish whose start fields differ is `does not match its start event`.

The only summary rule left is that `unfinished_tests` and `unfinished_groups` equal the sizes of the open maps.

These are deleted: the duration/outcome rule, `tally/1`, `files_match?/2`, `times/3` and the aggregation helpers.

One case is equivalent but not obvious. goodflows stops at the first bad record and rejects anything after `suite_finished` with `invalid_order`. The server reports a `suite_finished` that is not last. Both reject exactly the same documents.

### D4. Timestamp is a transcription of `valid_timestamp`

`started_at_errors/2` pattern-matches the binary. In Elixir `::4` is four bits, so the match uses byte sizes:

- `<<y::binary-size(4), "-", m::binary-size(2), "-", d::binary-size(2), t, h::binary-size(2), ":", mi::binary-size(2), ":", s::binary-size(2), rest::binary>>`, where `y`, `m`, `d`, `h`, `mi` and `s` are ASCII digits parsed to integers, and `t` is `T` or `t`
- an optional `.` plus one or more digits
- then exactly `Z`, `z`, `+00:00` or `-00:00`

Ranges: `Calendar.ISO.valid_date?/3` on those integers, hour ≤ 23, minute ≤ 59, second ≤ 60. A non-binary is `must be a string`. A value over 64 bytes is `is too long`. Other messages are unchanged.

*Alternative:* keep `DateTime.from_iso8601/1` and pre-normalize. Rejected. It accepts a space separator and rejects `-00:00`, lowercase `t`/`z` and second 60. Working around each one is less clear than a direct transcription.

### D5. A wrong format gets one error

When the envelope `format` is present and is not the string `test-timings/1`, `validate/1` returns only that error (`format`, `is invalid`) and skips the rest of the structural and consistency passes. When the first record's `event` is `suite_started` and its `format` is present and is not that string, it returns only `report.records[0].format`, `is invalid`. A missing `format` stays `is required`. A first record whose `event` is not `suite_started` stays the ordering error; its `format` is not read. The record rule applies whether the envelope `format` is correct or missing: a body with no envelope `format` and an `exunit-timings` `suite_started` gets only `report.records[0].format`, and the missing envelope `format` is not reported (it would be, as `is required`, once the record format is fixed).

`Validator.format_rejection/1` reads both formats from the decoded document before `Document.normalize/1` (from `Jason.OrderedObject`s or plain maps, taking the first value of a duplicate key), so a retired body that also has duplicate keys, NULs or out-of-range integers still gets only the format error. An `exunit-timings` body would otherwise list up to 50 unknown-field errors that only obscure the cause. goodflows checks the format of a `suite_started` before any other key of that record, and rejects a first record that is not `suite_started` before reading `format`. The accepted set is unchanged, because the document is rejected either way.

### D6. A data migration purges `exunit-timings` rows

The new migration runs `DELETE FROM test_reports WHERE payload->>'format' = 'exunit-timings'`. Its `down` raises `Ecto.MigrationError`, because the rows cannot be restored: rolling back past it means restoring a backup. It filters on the format instead of truncating, so a `test-timings/1` row stored by a node already running the new code is safe.

Nothing in the server enforces a drain. Old nodes (any node still running a release that accepts `exunit-timings`) MUST be stopped before, or at the latest when, the migration runs; in a rolling deploy that means stopping the old nodes first rather than replacing them one by one while the new release migrates. There is no second purge: an old node that inserted a row after the DELETE would leave an `exunit-timings` report in place, and that row would still block its project's deletion until removed by hand. A `CHECK` constraint on `payload->>'format'` was considered and rejected: it changes the table's schema (a non-goal) and would also have to be relaxed for `test-timings/2`.

*Alternative:* a release task run by hand. Rejected, because the purge belongs with the schema history: any environment that applies the migrations applies the purge, in order. Note that the repository has no release migration task (no `Release` module, and the `deploy` recipe in `app/justfile` is empty); migrations run only through `mix ecto.migrate` (`mix setup`, `ecto.setup` and the `test` alias). Whoever deploys must run the migrations as part of the deploy, after stopping old nodes.

### D7. Docs and fixtures

- **OpenAPI:**
  - `TestReportParts` handles `{:optional, _}` and `:meta` (an object with `maxProperties: 32` and scalar `additionalProperties`, described in words) and drops `:relative_file` in the same change that stops the validator emitting that kind.
  - The timestamp description names the grammar.
  - The `TestReportRequest` example becomes a small `test-timings/1` report with `runner`, `filters: null`, one group and one test.
  - The test-report section of `ApiSpec` is rewritten: `suite_id`, the event names, `meta`, and the rule that the server accepts exactly what goodflows collection accepts.
- **Fixtures (hand-written):**
  - Still hand-written (no captured reporter output yet), but shaped like what goodflows' reporters emit (`reporters/exunit/lib/goodflows/ex_unit_reporter.ex`, `reporters/jest/index.js`, `openspec/specs/test-reporters/spec.md` in goodflows): every `suite_started.meta` has `reporter`, `reporter_version` and `filtered`.
  - `complete.json`: ExUnit-shaped, with filters, ExUnit's `meta` (`elixir_version`, `otp_release`, `max_cases`, `schedulers` on `suite_started`; `async`, `setup_all`, `parameter_id` on groups; `async`, `parameter_id` and `skip_reason` on tests; time buckets on `suite_finished`), names without the `test ` prefix, a one-entry describe `path`, and skipped and excluded tests with null duration.
  - `failed.json`: Jest-shaped, with `filters: null`, Jest's `suite_started.meta` (`node_version`, `max_workers`, `duration_resolution_us: 1000`), null `line` with `meta.line` on `test_finished`, a nested `path`, a retried test written as two pairs with distinct `execution_id`s (only the second has `meta.invocations: 2`) and counted once, an errored group, and a failed job. Jest numbers groups and tests from one counter, so the fixture no longer has a group and a test sharing an `execution_id`; that case is a validator test.
  - `incomplete.json`: ExUnit-shaped, with `max_failures_reached`, an unmatched `test_started`, `interrupted` (neither marker has `meta`, as in both reporters) and no `suite_finished`.
  - `TestReportFixtures.large_report/2` pads each test's `name` instead of the old nullable `describe`.

### D8. The envelope and number decoding match goodflows exactly

Two pre-existing rules accepted documents goodflows collection rejects, so they change with this contract:

- **`source.branch` rejects control characters.** goodflows `valid_branch` (`src/reporting/source.rs`) rejects any `char::is_control`, which is Unicode category Cc (U+0000–U+001F, U+007F–U+009F), the same set as `Shape`'s `no_control`. The branch spec becomes `{:nullable, {:string, min: 1, max: 256, no_control: true}}`. `workflow`, `job` and `environment` already match `config::valid_report_name`, `commit` matches `valid_commit` and `workflow_run_id` matches `canonical_uuid`.
- **`-0` is not an integer.** serde_json parses `-0` as an f64 and goodflows' strict decoder rejects every f64 (`non_integer_number`). `Document.decode/1` appends `.0` to each `-0` token found outside strings (one not already followed by `.`, `e`/`E` or a digit, and not an exponent sign) before calling `Jason`, so it decodes as the float `-0.0`. The existing structural pass then rejects it like any other fraction: `must be an integer` on that value's path, or `has an invalid value` on a `meta`. The byte scan runs only when some `-0` in the body is not preceded by an ASCII letter or digit (a number token never is, in valid JSON), so the dates and UUIDs that almost every body contains do not trigger it; `-0` inside strings is left alone by the scan itself.

*Alternative:* a fixed `422` on `body` from a pre-decode scan. Rejected, because rewriting the token keeps the per-path error at the same cost and reuses the float rule.

### D9. Format rejections are logged

A report rejected only for its `format` (D5) is otherwise invisible on the server: the response is a plain 422 and the request log has no body. `TestReportController` therefore logs one `info` line per such rejection, built only from server-side values and fixed text: the account and project ids, the rejected field (`format` or `report.records[0].format`), whether the declared value was the retired `exunit-timings` or something else (from `Validator.format_rejection/1`; the submitted value itself is never logged), and the request `User-Agent` with invalid UTF-8 and Unicode control characters removed, cut to 200 bytes on a character boundary. Other validation errors are not logged. The response is unchanged; there is no machine-readable error code (a non-goal).

## Risks / Trade-offs

- [The server's copy drifts from contract.rs at the next revision.] → D1 keeps the tables one-to-one and names the pinned change. The validator tests port the goodflows scenarios one-for-one. Captured reporter output can be added as fixtures later.
- [Hand-written fixtures miss shapes real reporters produce.] → The fixtures include the known traps: retries, a shared execution id, null filters and null durations. Real output is a planned follow-up.
- [Dropping the counts, duration and file checks lets inconsistent reports in.] → This is intended. Those rules were never in the contract. The server stores producer data as supplied and makes no attestation claims, and completion depends only on core fields.
- [An old CLI is still running when the server switches formats.] → Its uploads get 422, which goodflows treats as final: the report is marked `rejected_by_server` and `goodflows replay` never resends it, even after upgrading. Uploads from pre-0.6.0 CLIs during the switch are therefore permanently lost. Accepted, because this is greenfield and there is no stored history to protect; upgrade every publisher to goodflows ≥ v0.6.0 at deploy time. Each such rejection is logged on the server (D9) so remaining old publishers can be found.
- [The purge loses all stored timing history.] → Accepted (greenfield, no read API). The migration is irreversible by design.
- [A rolling deploy lets an old node insert `exunit-timings` after the purge.] → Stop those nodes before the migration (D6); nothing enforces it. There is no second delete, and such a row would block its project's deletion until removed by hand.

## Migration Plan

1. Stop every node that still accepts `exunit-timings` (not a rolling replacement), so none of them can insert during or after the migration.
2. Deploy: run the migrations explicitly (the repository has no automatic release migration step), which purges `exunit-timings` rows, then start the new release, whose validator accepts only `test-timings/1`.
3. At the same time, upgrade every publisher to goodflows ≥ v0.6.0 with `reports = ["test-timings"]`. Uploads from pre-0.6.0 CLIs after step 2 are rejected with 422 and permanently lost (goodflows never replays a `rejected_by_server` report); this is accepted because the deployment is greenfield. The server logs each format rejection (D9) to show which publishers still need upgrading.

Rollback: the purge migration is irreversible (`down` raises), so rolling the database back past it means restoring a backup taken before the deploy. Redeploying the previous release without rolling back the database restores `exunit-timings` validation and leaves the table schema untouched; purged rows are not restored, and `test-timings/1` rows stored in the meantime stay, but the old code never reads them.
