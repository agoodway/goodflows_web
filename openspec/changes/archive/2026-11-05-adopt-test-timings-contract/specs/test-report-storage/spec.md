# Spec Delta

## MODIFIED Requirements

### Requirement: The ingestion contract identifies execution and report provenance
The API SHALL accept on `POST /api/v1/projects/:project/test-reports` exactly the `test-timings/1` documents defined by the `test-timing-contract` capability, carrying workflow invocation, workflow/environment, job status, source context, and a report of suite identity, report identity, partition metadata, and event records. Identities, integer microsecond timings and `meta` MUST be stored exactly as supplied. The server MUST NOT derive, rewrite, or check per-test durations against receipt offsets.

#### Scenario: Independent partition reports
- **WHEN** three reports from one workflow job arrive
- **THEN** their shared workflow invocation and suite identities and their distinct report and partition identities are preserved

#### Scenario: Duration exceeds receipt interval
- **WHEN** a test's `duration_us` exceeds the gap between its started and finished `received_offset_us`
- **THEN** the report is accepted and the duration is stored unchanged

#### Scenario: Reports from different runners
- **WHEN** one project receives a report with `runner.name` `exunit` and another with `runner.name` `jest`
- **THEN** both are stored under the same rules, each with its `runner` and `meta` unchanged in the stored document

#### Scenario: Retired format
- **WHEN** a publisher sends an `exunit-timings` report
- **THEN** the API returns 422 and stores nothing

### Requirement: Retries are idempotent within the authenticated account
The tuple of account, project id, workflow invocation, job and report identity SHALL uniquely identify an immutable document. First insertion SHALL return 201. A retry whose validated body is the same JSON value (object key order ignored at every level; arrays compared in order; strings compared exactly; numbers, which validation limits to integers, compared by value) SHALL return 200 with the same server identity. Any difference SHALL return 409 without revealing the stored id or payload. Concurrent requests MUST follow the same rules without duplicate rows.

#### Scenario: Concurrent exact retries
- **WHEN** two identical requests race
- **THEN** one report is stored and both receive successful acknowledgements for it

#### Scenario: Concurrent conflicting bodies
- **WHEN** two different bodies under one identity race
- **THEN** exactly one is stored and acknowledged as new and the other receives 409

#### Scenario: Conflicting retry
- **WHEN** an existing report identity is reused with a different duration or provenance
- **THEN** the API returns 409 without changing the stored report

#### Scenario: Reordered object keys
- **WHEN** a stored report is retried with the keys of nested objects, such as `meta`, in a different order
- **THEN** the API returns 200 with the stored id and `duplicate` true

#### Scenario: Reordered array elements
- **WHEN** a stored report is retried with the elements of an array (such as a test's `path`) in a different order
- **THEN** the API returns 409 without changing the stored report

#### Scenario: Different accounts
- **WHEN** two accounts publish the same external identity tuple
- **THEN** each stores its own document without exposing the other's report identity

### Requirement: Completion is derived for each report
The API SHALL derive each stored report's status with the completion rule of the `test-timing-contract` capability: complete only when `truncated` is false, the final record is `suite_finished` with `aborted` false and `unfinished_tests` and `unfinished_groups` both zero, and no `interrupted` or `max_failures_reached` record appears. Other accepted documents SHALL be incomplete. Test failures MUST remain distinct from report incompleteness. The server MUST NOT claim that receiving one partition completes an entire invocation.

#### Scenario: Complete failing test run
- **WHEN** a report has a valid complete ending and failed test outcomes
- **THEN** it is stored as complete with the failure outcomes and failed job status retained

#### Scenario: Interrupted worker
- **WHEN** a valid report ends after a test-started event
- **THEN** it is stored as incomplete with its available completed timings preserved

#### Scenario: Max failures reached
- **WHEN** a report contains a `max_failures_reached` event followed by a suite-finished event with `aborted` false and zero unfinished counts
- **THEN** it is stored as incomplete

### Requirement: Only structural report data is accepted
The API SHALL accept only documents valid under the `test-timing-contract` capability and SHALL reject every other decoded body with 422. Objects and arrays nesting more than 16 levels SHALL return 422 on `body` before decoding. Errors SHALL use the validation error shape keyed by JSON path with fixed messages, never echoing submitted values or key names; an unknown or duplicate key, or an invalid `meta` key, SHALL be reported on its enclosing object. A `meta` fault SHALL be reported only on that record's `meta` path, with one of `must be an object`, `must not have more than 32 keys`, `has an invalid key` or `has an invalid value`; a NUL string or out-of-range integer anywhere inside a `meta` SHALL be `has an invalid value` on that `meta`. A value fault (NUL, integer range) under any other key the contract does not define SHALL be reported on the nearest enclosing object the contract defines, so no error path contains a submitted key name. When the envelope `format` is present and is not `test-timings/1`, the API SHALL return exactly that one error (`format`, `is invalid`) and SHALL NOT check the rest of the document, including duplicate keys, NULs and integer range. When the first record's `event` is `suite_started` and its `format` is present and is not `test-timings/1`, the API SHALL return exactly that one error (`report.records[0].format`, `is invalid`), also when the envelope `format` is missing. Otherwise a missing `format` stays `is required`. A first record that is not `suite_started` stays an ordering error. At most the first 50 errors, in document order, SHALL be returned.

#### Scenario: Raw failure payload
- **WHEN** an otherwise valid report includes an exception message or captured logs as an unknown key or a structured `meta` value
- **THEN** the API returns a field-path error with a fixed message, persists nothing and does not log the submitted value

#### Scenario: Unknown key name is not echoed
- **WHEN** an otherwise valid report has an unknown key inside `source`
- **THEN** the API returns 422 with the error `has an unknown field` on `source`, and the response does not contain the submitted key name

#### Scenario: Invalid meta key is not echoed
- **WHEN** a record's `meta` has the key `stack trace`
- **THEN** the API returns 422 with `has an invalid key` on that record's `meta`, and the response does not contain the submitted key name

#### Scenario: Meta is not an object
- **WHEN** a record's `meta` is `null` or a string
- **THEN** the API returns 422 with `must be an object` on that record's `meta`

#### Scenario: Too many meta keys
- **WHEN** a record's `meta` has 33 keys
- **THEN** the API returns 422 with `must not have more than 32 keys` on that record's `meta`

#### Scenario: Invalid meta value
- **WHEN** a `meta` value is an array, an object or a float
- **THEN** the API returns 422 with `has an invalid value` on that record's `meta`, and the response does not contain a submitted meta key

#### Scenario: Out-of-range meta value is not echoed
- **WHEN** a record's `meta` is `{"db_password": 99999999999999999999}`, or a `meta` string contains U+0000
- **THEN** the API returns 422 with exactly `has an invalid value` on that record's `meta`, and the response does not contain `db_password`

#### Scenario: Bad value under an unknown key is not echoed
- **WHEN** `source` has an unknown key `db_password` whose value is `99999999999999999999`
- **THEN** the API returns 422 with exactly `is out of range` on `source`, and the response does not contain `db_password`

#### Scenario: Retired format beside encoding errors
- **WHEN** a body has `format` `exunit-timings`, a duplicate key and an integer beyond 2^53-1
- **THEN** the API returns 422 with exactly one error, `is invalid` on `format`

#### Scenario: No envelope format and a retired record format
- **WHEN** a body has no `format` and its `suite_started.format` is `exunit-timings`
- **THEN** the API returns 422 with exactly one error, `is invalid` on `report.records[0].format`

#### Scenario: Retired envelope format is the only error
- **WHEN** a publisher sends an `exunit-timings` report
- **THEN** the API returns 422 with exactly one error, `is invalid` on `format`, and does not report unknown fields

#### Scenario: Retired record format is the only error
- **WHEN** the envelope `format` is `test-timings/1` and `suite_started.format` is `test-timings/2`
- **THEN** the API returns 422 with exactly one error, `is invalid` on `report.records[0].format`

#### Scenario: Bad filter tag is not echoed
- **WHEN** a filter `tag` is `slow test`
- **THEN** the API returns 422 on that `tag` with a fixed message that does not include the submitted tag

#### Scenario: Non-boolean filter value
- **WHEN** a filter entry has `value` `on`
- **THEN** the API returns 422 on that `value`

#### Scenario: Extra key in a filter entry
- **WHEN** a filter entry is `{"tag": "slow", "value": true, "note": "x"}`
- **THEN** the API returns 422 with `has an unknown field` on that entry, and the response does not contain `note`

#### Scenario: Excessive nesting
- **WHEN** a body nests arrays or objects 17 levels deep
- **THEN** the API returns 422 on `body` without decoding the body and stores nothing

#### Scenario: Unknown nonexecuted metadata
- **WHEN** skipped tests have null duration and null file
- **THEN** those nulls are accepted without fabricating execution cost

#### Scenario: Filter list over the cap
- **WHEN** `filters.include` has 257 entries
- **THEN** the API returns 422 with the single error `must not have more than 256 entries` on that `suite_started` record's `filters.include` (e.g. `report.records[0].filters.include`) and its entries are not checked

## ADDED Requirements

### Requirement: Retired-format reports are purged
Deploying `test-timings/1` support SHALL delete every stored report whose document declares `exunit-timings`, together with its row. The delete SHALL run only after every node still accepting `exunit-timings` uploads has been stopped, so an old node cannot insert an `exunit-timings` row after the delete; the server does not enforce this, so the deploy procedure SHALL stop old nodes before running the migration. There is no second purge. The purge SHALL be irreversible: rolling the migration back SHALL fail rather than pretend to restore the rows. Reports in `test-timings/1` MUST NOT be affected. After the purge, a project whose only reports were `exunit-timings` SHALL be deletable.

#### Scenario: Legacy report removed
- **WHEN** an account had one `exunit-timings` report and one `test-timings/1` report stored before the deploy
- **THEN** afterwards only the `test-timings/1` report remains

#### Scenario: Project freed by the purge
- **WHEN** a project's only stored reports were `exunit-timings` and a client deletes it after the deploy
- **THEN** the project is deleted

#### Scenario: Rollback refused
- **WHEN** an operator rolls back the purge migration
- **THEN** the rollback fails with a migration error and the migration stays applied

#### Scenario: Old publishers drained first
- **WHEN** the deploy stops nodes that still accept `exunit-timings`, then runs the delete, then serves the new validator
- **THEN** no `exunit-timings` row remains

### Requirement: Format rejections are visible on the server
When a report is rejected only for its `format`, the server SHALL log one line naming the account and project ids, the rejected field, whether the declared format is the retired `exunit-timings` or another value, and the request `User-Agent` with control characters removed and cut to at most 200 bytes. The line MUST NOT contain the submitted format value or any other submitted payload value. The response SHALL be unchanged.

#### Scenario: Old CLI upload
- **WHEN** a publisher whose `User-Agent` is `goodflows/0.5.2` uploads an `exunit-timings` report
- **THEN** the API returns the single `format` error and the server logs one line saying the retired format was declared, with the account id, project id and that user agent

#### Scenario: Unsupported format value is not logged
- **WHEN** a report's `format` is an arbitrary string
- **THEN** the log line says an unsupported format was declared and does not contain the string

## REMOVED Requirements

### Requirement: Suite filters accept boolean identifier tags
**Reason**: Filter grammar is part of the wire format, now defined by the `test-timing-contract` requirement "Suite filters are boolean identifier tags", which also makes `filters` nullable. Where an over-cap list's error is reported, and the `tag`, `value` and unknown-key error paths, move to "Only structural report data is accepted".
**Migration**: None for publishers sending `test-timings/1`. The tag grammar, boolean values, 256-entry cap, order and case rules are unchanged.
