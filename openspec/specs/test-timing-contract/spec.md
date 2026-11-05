# test-timing-contract Specification

## Purpose

Define the runner-neutral `test-timings/1` document that the test report API accepts. It mirrors the goodflows `test-timing-contract` capability, so any report goodflows collection accepts is stored and any report it rejects is refused.

## Requirements

### Requirement: The server accepts exactly what goodflows collection accepts
The API SHALL accept a decoded document if and only if it satisfies this contract, which mirrors goodflows change `2026-11-04-generalize-test-timings`. The API MUST NOT reject a decoded document for a rule this contract does not state, including agreement between `counts` and test events, agreement between `duration_us` and `outcome`, or the form of a `file` path. A decoded document that fails this contract SHALL be rejected with 422. Authentication, project selection, body size, malformed JSON, idempotency conflicts, admission and storage failures are defined by the `test-report-storage` capability and are not contract rejections.

#### Scenario: Retried test counted once
- **WHEN** a report has two `test_started`/`test_finished` pairs with distinct `execution_id`s and the same `group`, `path` and `name`, the first `failed` and the second `passed`, and `suite_finished.counts` is `{"passed": 1}`
- **THEN** the report is accepted

#### Scenario: Counts that disagree with test events
- **WHEN** a complete report's `suite_finished.counts` differs from the tally of its `test_finished` outcomes
- **THEN** the report is accepted and stored unchanged

#### Scenario: Duration on a skipped test
- **WHEN** a `test_finished` with `outcome: "skipped"` has `duration_us: 0`
- **THEN** the report is accepted

#### Scenario: Passed test without a duration
- **WHEN** a `test_finished` with `outcome: "passed"` has `duration_us: null`
- **THEN** the report is accepted

#### Scenario: Absolute file path
- **WHEN** a `test_started` has `file: "/src/app/test/a_test.exs"` or `file: "../a.test.js"`
- **THEN** the report is accepted

### Requirement: The format names its contract version
A report SHALL declare `test-timings/1` both in the envelope's `format` and in its `suite_started` record's `format`. Any other value, including the retired `exunit-timings`, MUST be rejected.

#### Scenario: Current format
- **WHEN** a report's envelope and `suite_started` both declare `test-timings/1`
- **THEN** its format is accepted

#### Scenario: Retired format
- **WHEN** a report declares `exunit-timings` in its envelope or its `suite_started`
- **THEN** the API returns 422 and stores nothing

#### Scenario: Envelope and record disagree
- **WHEN** the envelope declares `test-timings/1` and `suite_started` declares `test-timings/2`
- **THEN** the report is rejected

### Requirement: The envelope has a fixed shape
A body SHALL have exactly `format`, `workflow_run_id`, `workflow`, `environment`, `job`, `job_status`, `source` and `report`. `source` SHALL have exactly `commit`, `branch` and `dirty`. `report` SHALL have exactly `suite_id`, `report_id`, `partition`, `partition_count`, `truncated` and `records`. `job_status` MUST be `passed`, `failed`, `timed_out`, `cancelled`, `skipped` or `unknown`. `workflow_run_id` MUST be a lowercase hyphenated hexadecimal UUID (`8-4-4-4-12`). `workflow` and `job` MUST be strings of 1 to 64 UTF-8 bytes with no Unicode control characters (U+0000–U+001F or U+007F–U+009F). `environment` MUST be null or that same kind of name. `source.commit` MUST be null or 40 or 64 hexadecimal digits. `source.branch` MUST be null or a string of 1 to 256 bytes with no Unicode control characters. `source.dirty` MUST be null or a boolean. `report.truncated` MUST be a boolean. `report.records` MUST be an array. `report.suite_id` and `report.report_id` MUST use the identifier grammar.

#### Scenario: Extra envelope key
- **WHEN** a body adds a `project` key
- **THEN** it is rejected

#### Scenario: Report identity agrees with records
- **WHEN** `report.suite_id`, `report.report_id`, `report.partition` or `report.partition_count` differs from the `suite_started` record's value
- **THEN** the report is rejected

#### Scenario: Workflow run id is not a lowercase UUID
- **WHEN** `workflow_run_id` is `67F7946D-136B-4608-AB01-E1F251A09754`
- **THEN** the report is rejected

#### Scenario: Job name too long
- **WHEN** `job` is 65 bytes
- **THEN** the report is rejected

#### Scenario: Empty environment
- **WHEN** `environment` is `""`
- **THEN** the report is rejected

#### Scenario: Empty branch
- **WHEN** `source.branch` is `""`
- **THEN** the report is rejected

#### Scenario: Branch with a control character
- **WHEN** `source.branch` contains U+0007, U+007F, U+0085 or a newline
- **THEN** the report is rejected

#### Scenario: Commit is not hex
- **WHEN** `source.commit` is 40 characters that are not hexadecimal
- **THEN** the report is rejected

#### Scenario: Truncated is not a boolean
- **WHEN** `report.truncated` is `"no"`
- **THEN** the report is rejected

### Requirement: Every record carries common keys
Every record SHALL be an object with `event`, `suite_id`, `report_id` and `received_offset_us`, and MAY have `meta`. `suite_id` and `report_id` SHALL be 1-128 bytes of `[A-Za-z0-9._-]` starting with a letter or digit (the identifier grammar) and MUST equal `report.suite_id` and `report.report_id` in every record. `received_offset_us` is integer microseconds since the suite started.

#### Scenario: Mixed identities
- **WHEN** one record of a report has a different `report_id` from the others
- **THEN** the report is rejected

#### Scenario: Record uses the retired run_id key
- **WHEN** a record carries `run_id` instead of `suite_id`
- **THEN** the report is rejected for an unknown key

### Requirement: The event vocabulary is closed and ordered
Events SHALL be `suite_started`, `group_started`, `group_finished`, `test_started`, `test_finished`, `suite_finished`, `interrupted` and `max_failures_reached`. The first record MUST be the only `suite_started`. A `suite_finished`, if present, MUST be the only one and the last record. Each event MUST carry all of its core keys, nullable ones as `null`, and no keys outside its core keys, the common keys and `meta`.

#### Scenario: Unknown event
- **WHEN** a record has `event: "module_started"`
- **THEN** the report is rejected

#### Scenario: Missing core key
- **WHEN** a `test_finished` record omits `duration_us`
- **THEN** the report is rejected, even though `duration_us` is nullable

#### Scenario: Interruption without finish
- **WHEN** a report ends with `interrupted` and has no `suite_finished`
- **THEN** it is accepted as an incomplete report

#### Scenario: Extra key on an interruption
- **WHEN** an `interrupted` record has a `reason` key
- **THEN** the report is rejected

#### Scenario: Retired test fields
- **WHEN** a `test_started` has a top-level `async` or `parameter_id` key, including a null value
- **THEN** the report is rejected for an unknown key

#### Scenario: Retired test fields in meta
- **WHEN** a `test_started` has `meta` `{"async": null, "parameter_id": null}`
- **THEN** the record is accepted

#### Scenario: Record after suite_finished
- **WHEN** a `test_finished` follows the `suite_finished`
- **THEN** the report is rejected

### Requirement: suite_started describes the run
`suite_started` SHALL have `format`, `started_at`, `runner`, `partition`, `partition_count`, `seed` and `filters`. `runner` SHALL be an object with exactly `name`, in the identifier grammar, and `version`, null or a string of at most 128 bytes. `seed` SHALL be null or an integer whose magnitude is at most 2^53-1. `filters` SHALL be null or a filter object.

#### Scenario: Jest run with a negative seed
- **WHEN** `suite_started` has `runner: {"name": "jest", "version": "30.0.0"}`, `seed: -1843` and `filters: null`
- **THEN** the record is accepted

#### Scenario: Runner name outside the grammar
- **WHEN** `runner.name` is `"jest runner"`
- **THEN** the report is rejected

#### Scenario: Unknown runner key
- **WHEN** `runner` is `{"name": "jest", "version": null, "url": "x"}`
- **THEN** the report is rejected

### Requirement: started_at uses the contract's UTC timestamp grammar
`started_at` SHALL be at most 64 bytes of `YYYY-MM-DD`, `T` or `t`, `HH:MM:SS`, an optional `.` and one or more digits, then `Z`, `z`, `+00:00` or `-00:00`. The date MUST exist in the Gregorian calendar, hours MUST be at most 23, minutes at most 59 and seconds at most 60.

#### Scenario: Accepted spellings
- **WHEN** `started_at` is `2026-11-04T12:00:00Z`, `2026-11-04t12:00:00.123456789z`, `2026-11-04T12:00:00+00:00` or `2026-11-04T12:00:00-00:00`
- **THEN** the record is accepted

#### Scenario: Leap second
- **WHEN** `started_at` is `2026-12-31T23:59:60Z`
- **THEN** the record is accepted

#### Scenario: Rejected spellings
- **WHEN** `started_at` is `2026-11-04 12:00:00Z`, `2026-11-04T12:00:00+01:00`, `2026-11-04T12:00:00` or `2026-02-30T12:00:00Z`
- **THEN** the report is rejected

#### Scenario: Timestamp at the length limit
- **WHEN** `started_at` is 64 bytes and otherwise matches the grammar
- **THEN** the record is accepted

#### Scenario: Timestamp over the length limit
- **WHEN** `started_at` is 65 bytes
- **THEN** the report is rejected

#### Scenario: Fraction with no digits
- **WHEN** `started_at` is `2026-11-04T12:00:00.Z`
- **THEN** the report is rejected

### Requirement: Partition fields have a fixed grammar
`partition` SHALL be null or 1-64 bytes of ASCII letters, digits, `.`, `_` or `-`. `partition_count` SHALL be null or an integer from 1 to 2^53-1. Both rules apply in the envelope and in `suite_started`.

#### Scenario: Partition with a space
- **WHEN** `partition` is `"a b"`
- **THEN** the report is rejected

#### Scenario: Zero partition count
- **WHEN** `partition_count` is `0`
- **THEN** the report is rejected

### Requirement: Groups are the runner's scheduling unit
`group_started` SHALL have `group` (text), `file` (text or null), `execution_id` and `started_offset_us`. `group_finished` SHALL repeat those keys and add `duration_us`, `outcome` and `counts`. Text is a string of 1 to 4,096 bytes.

#### Scenario: Group that failed to load
- **WHEN** a Jest test file throws while loading and runs no tests
- **THEN** its `group_finished` is accepted with `outcome: "errored"` and empty `counts`

#### Scenario: Group name too long
- **WHEN** `group` is 4,097 bytes
- **THEN** the report is rejected

#### Scenario: Empty text
- **WHEN** `group` is `""`
- **THEN** the report is rejected

### Requirement: Tests are identified by group, path and name
`test_started` SHALL have `group` (text), `path` (an array of at most 32 text strings, outermost first), `name` (text), `file` (text or null), `line` (null or an integer from 1 to 2^53-1), `execution_id` and `started_offset_us`. `test_finished` SHALL repeat those keys and add `duration_us` and `outcome`.

#### Scenario: Nested describe blocks
- **WHEN** a Jest test `adds` sits inside `describe("math")` and `describe("sum")`
- **THEN** a record with `path: ["math", "sum"]` and `name: "adds"` is accepted

#### Scenario: Test outside any describe
- **WHEN** an ExUnit test has `path: []`
- **THEN** the record is accepted

#### Scenario: Path too deep
- **WHEN** `path` has 33 entries
- **THEN** the report is rejected

### Requirement: Finished events pair with started events
`execution_id` SHALL be an integer from 1 to 2^53-1, used at most once among a report's `group_started` events and separately at most once among its `test_started` events. Each `group_finished` or `test_finished` MUST follow an unfinished started event of its kind with the same `execution_id`, and MUST repeat that event's core keys with identical values. Common keys and `meta` may differ.

#### Scenario: Group and test share an id
- **WHEN** a `group_started` and a `test_started` both have `execution_id: 1`
- **THEN** the report is accepted

#### Scenario: Finish without start
- **WHEN** a `test_finished` names an `execution_id` with no earlier `test_started`
- **THEN** the report is rejected

#### Scenario: Finish of the wrong kind
- **WHEN** a `group_finished` names the `execution_id` of an open `test_started` and no open `group_started` has it
- **THEN** the report is rejected

#### Scenario: Finish changes identity
- **WHEN** a `test_finished` repeats an `execution_id` but changes `name`
- **THEN** the report is rejected

#### Scenario: Finish changes meta
- **WHEN** a `test_finished` matches its start except for `meta` and `received_offset_us`
- **THEN** the report is accepted

#### Scenario: Finished twice
- **WHEN** two `test_finished` records share one `execution_id`
- **THEN** the report is rejected

#### Scenario: Started again after finishing
- **WHEN** a `test_started` reuses the `execution_id` of a test that already finished
- **THEN** the report is rejected

#### Scenario: Started twice
- **WHEN** two `test_started` records share one `execution_id`
- **THEN** the report is rejected

#### Scenario: Started but never finished
- **WHEN** a truncated report ends after a `test_started`
- **THEN** the report is accepted and that test counts as unfinished

### Requirement: Outcomes and counts are runner-neutral
`outcome` SHALL be `passed`, `failed`, `skipped` or `errored` for tests and groups. `counts` SHALL be an object whose keys are a subset of those outcomes and whose values are integers from 0 to 2^53-1. Runner-specific distinctions such as excluded, pending or todo belong in `meta`.

#### Scenario: Runner-specific outcome
- **WHEN** a `test_finished` has `outcome: "todo"` or `outcome: "excluded"`
- **THEN** the report is rejected

#### Scenario: Unknown count key
- **WHEN** `counts` has a key `excluded`
- **THEN** the report is rejected

### Requirement: Durations and offsets are nonnegative integer microseconds
`received_offset_us`, `started_offset_us` and every non-null `duration_us` SHALL be integers from 0 to 2^53-1. `duration_us` MAY be null for any outcome. Durations SHALL be stored as supplied and MUST NOT be checked against offsets.

#### Scenario: Millisecond runner
- **WHEN** a runner reports 12 milliseconds and the producer sends `duration_us: 12000`
- **THEN** the value is accepted unchanged

#### Scenario: Negative duration
- **WHEN** `duration_us` is `-5`
- **THEN** the report is rejected

### Requirement: suite_finished summarizes the run
`suite_finished` SHALL have `aborted` (boolean), `unfinished_tests` and `unfinished_groups` (integers from 0 to 2^53-1), `counts` and `duration_us` (null or an integer from 0 to 2^53-1). `unfinished_tests` and `unfinished_groups` MUST equal the number of started events of each kind that have no matching finished event before it.

#### Scenario: Unfinished count disagrees
- **WHEN** one `test_started` has no `test_finished` and `suite_finished` reports `unfinished_tests: 0`
- **THEN** the report is rejected

#### Scenario: Retired counter name
- **WHEN** `suite_finished` has `unfinished_modules` instead of `unfinished_groups`
- **THEN** the report is rejected

### Requirement: Runner metadata is flat and bounded
Any record MAY carry `meta`, an object of at most 32 keys in the identifier grammar. Each value SHALL be null, a boolean, an integer whose magnitude is at most 2^53-1, or a string of at most 256 bytes. Arrays, objects, longer strings and any other value MUST be rejected. `meta` is stored as supplied.

#### Scenario: ExUnit runner details
- **WHEN** `suite_started.meta` is `{"elixir_version": "1.20.0", "otp_release": "28", "max_cases": 16}`
- **THEN** the record is accepted and `meta` is stored unchanged

#### Scenario: Structured meta value
- **WHEN** a `meta` value is `["a", "b"]` or `{"x": 1}`
- **THEN** the report is rejected

#### Scenario: Too many meta keys
- **WHEN** `meta` has 33 keys
- **THEN** the report is rejected

#### Scenario: Long meta string
- **WHEN** a `meta` string is 257 bytes
- **THEN** the report is rejected

#### Scenario: Meta key outside the grammar
- **WHEN** a `meta` key is `skip reason` or `_private`
- **THEN** the report is rejected

#### Scenario: Meta is not an object
- **WHEN** `meta` is `null` or `"x"`
- **THEN** the report is rejected

#### Scenario: Null meta value
- **WHEN** a record's `meta` is `{"async": null}`
- **THEN** the record is accepted and `meta` is stored unchanged

#### Scenario: Float meta value
- **WHEN** a `meta` value is `1.5`
- **THEN** the report is rejected

### Requirement: Suite filters are boolean identifier tags
A non-null `filters` SHALL be an object with exactly `include` and `exclude`, each an array of at most 256 entries. Each entry SHALL have exactly `tag`, in the identifier grammar, and `value`, a boolean. Tags are case-sensitive and SHALL be stored in the supplied order without normalization, including a repeated tag.

#### Scenario: Runner without tags
- **WHEN** a Jest report sends `filters: null`
- **THEN** the record is accepted

#### Scenario: Tagged ExUnit run
- **WHEN** `filters` is `{"include": [{"tag": "slow", "value": true}], "exclude": []}`
- **THEN** the record is accepted with the entries unchanged

#### Scenario: Missing list
- **WHEN** `filters` is `{"include": []}`
- **THEN** the report is rejected

#### Scenario: Filters key omitted
- **WHEN** `suite_started` has no `filters` key
- **THEN** the report is rejected for a missing core key

#### Scenario: Repeated tags keep their order
- **WHEN** `filters.exclude` lists `{"tag": "slow", "value": true}` and then `{"tag": "slow", "value": false}`
- **THEN** the report is accepted with those two entries stored in that order

#### Scenario: Case-sensitive tags
- **WHEN** `filters.include` lists `{"tag": "Chrome", "value": true}` and `{"tag": "chrome", "value": true}`
- **THEN** the report is accepted with both entries stored unchanged

#### Scenario: Tag outside the identifier grammar
- **WHEN** a filter `tag` is `slow test`, `ok?`, `slow` followed by a newline, an empty string, or longer than 128 bytes
- **THEN** the report is rejected

#### Scenario: Non-boolean filter value
- **WHEN** a filter entry has `tag` `chrome` and `value` `yes`
- **THEN** the report is rejected

#### Scenario: Filter list over the cap
- **WHEN** `filters.include` has 257 entries
- **THEN** the report is rejected

#### Scenario: Unknown key in filters or an entry
- **WHEN** `filters` is `{"include": [], "exclude": [], "x": 1}` or an entry is `{"tag": "slow", "value": true, "note": "x"}`
- **THEN** the report is rejected

#### Scenario: Filters is not an object
- **WHEN** `filters` is an array or a string
- **THEN** the report is rejected

### Requirement: Documents are bounded and strictly encoded
A decoded body SHALL hold 1 to 100,000 records, with objects and arrays nested at most 16 levels. It MUST have no duplicate object keys, no fractional or exponent numbers, no integer whose magnitude exceeds 2^53-1, no `-0` number (goodflows reads it as a fraction, not an integer), and no U+0000 in any string or key. A body over 32 MiB is rejected with 413, and malformed or invalid UTF-8 JSON is rejected with 400, by the `test-report-storage` capability rather than as a contract failure.

#### Scenario: Duplicate key
- **WHEN** a record has two `name` keys
- **THEN** the report is rejected instead of keeping either value

#### Scenario: Fractional number
- **WHEN** `duration_us` is `12.5`
- **THEN** the report is rejected

#### Scenario: Negative zero
- **WHEN** a `received_offset_us`, a `seed` or a `meta` value is the number `-0`
- **THEN** the report is rejected

#### Scenario: Integer below the safe range
- **WHEN** `seed` is `-9007199254740992`
- **THEN** the report is rejected

#### Scenario: Empty records
- **WHEN** `report.records` is `[]`
- **THEN** the report is rejected

### Requirement: Completion is derived from core fields
A report SHALL be complete only when `truncated` is false, its last record is `suite_finished` with `aborted` false and `unfinished_tests` and `unfinished_groups` both zero, and it has no `interrupted` or `max_failures_reached` record. Every other accepted report SHALL be incomplete. Failed or errored tests and groups MUST NOT by themselves make a report incomplete.

#### Scenario: Failing but complete
- **WHEN** a report finishes normally with two failed tests and an errored group
- **THEN** it is stored as complete

#### Scenario: Bail
- **WHEN** a report contains `max_failures_reached` and ends with `suite_finished`
- **THEN** it is stored as incomplete

#### Scenario: Truncated report
- **WHEN** a report would otherwise be complete and has `truncated: true`
- **THEN** it is stored as incomplete
