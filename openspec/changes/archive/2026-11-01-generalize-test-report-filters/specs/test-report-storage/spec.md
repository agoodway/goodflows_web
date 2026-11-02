# Spec Delta

## MODIFIED Requirements

### Requirement: Only structural report data is accepted
The API SHALL validate event types, allowlisted fields, identifiers, nullable metadata, nonnegative integer timings, outcomes and nested file aggregates. Unknown fields, duplicate object keys, strings containing U+0000, captured logs, exception payloads, assertion values, per-test tags (suite filter tags are governed by "Suite filters accept boolean identifier tags"), parameter values and unsupported formats MUST be rejected with 422. Objects and arrays MUST NOT nest more than 16 levels deep; a deeper body SHALL return 422 on `body` and SHALL be rejected before it is decoded. Error bodies SHALL use the existing validation error shape keyed by JSON path with fixed messages, without reflecting submitted values or submitted key names in errors or logs: an unknown or duplicate key SHALL be reported on its enclosing object. At most the first 50 errors, in document order, SHALL be returned.

#### Scenario: Raw failure payload
- **WHEN** an otherwise valid report includes an exception message or captured logs
- **THEN** the API returns a field-path error with a fixed message, persists nothing and does not log the submitted value

#### Scenario: Unknown key name is not echoed
- **WHEN** an otherwise valid report has an unknown key inside `source`
- **THEN** the API returns 422 with the error `has an unknown field` on `source`, and the response does not contain the submitted key name

#### Scenario: Excessive nesting
- **WHEN** a body nests arrays or objects 17 levels deep
- **THEN** the API returns 422 on `body` without decoding the body and stores nothing

#### Scenario: Unknown nonexecuted metadata
- **WHEN** skipped tests have null duration, async status or parameter identity
- **THEN** those nulls are accepted without fabricating execution cost

## ADDED Requirements

### Requirement: Suite filters accept boolean identifier tags
Each entry in `suite_started` `filters.include` and `filters.exclude` SHALL contain only `tag` and `value`; an extra key MUST return 422 `has an unknown field` on that entry. `tag` MUST be 1 to 128 bytes matching the whole of `[A-Za-z0-9][A-Za-z0-9._-]*` (a trailing newline does not match). Tags are case-sensitive and SHALL be stored without normalization. `value` MUST be a JSON boolean. Each of `include` and `exclude` MUST have at most 256 entries. Entries MUST be stored in the supplied order, including a repeated tag. A tag outside that grammar, a value that is not a boolean, or a list over 256 entries MUST return 422 on that field with a fixed message and store nothing. A list over 256 entries SHALL be reported only on the list itself; its entries are not checked.

#### Scenario: Boolean identifier tags from any project
- **WHEN** `filters.include` is `[{"tag": "slow", "value": true}]` and `filters.exclude` is `[{"tag": "chrome", "value": true}]`
- **THEN** the report is accepted and both entries are stored unchanged

#### Scenario: Repeated tags keep their order
- **WHEN** `filters.exclude` lists `{"tag": "slow", "value": true}` and then `{"tag": "slow", "value": false}`
- **THEN** the stored array has those two entries in that order

#### Scenario: Tag outside the identifier grammar
- **WHEN** a filter `tag` is `slow test`, `ok?`, `slow` followed by a newline, or longer than 128 bytes
- **THEN** the API returns 422 on that `tag` with a fixed message that does not include the submitted tag, and stores nothing

#### Scenario: Non-boolean filter value
- **WHEN** a filter entry has `tag` `qpdf` and `value` `on`
- **THEN** the API returns 422 on that `value` and stores nothing

#### Scenario: Case-sensitive tags
- **WHEN** `filters.include` lists `{"tag": "Chrome", "value": true}` and `{"tag": "chrome", "value": true}`
- **THEN** the report is accepted and both entries are stored as distinct, unnormalized tags

#### Scenario: Extra key in a filter entry
- **WHEN** a filter entry is `{"tag": "slow", "value": true, "note": "x"}`
- **THEN** the API returns 422 `has an unknown field` on that entry, without echoing `note`, and stores nothing

#### Scenario: Too many filter entries
- **WHEN** `filters.include` has 257 entries
- **THEN** the API returns 422 with the single error `must not have more than 256 entries` on that `suite_started` record's `filters.include` (e.g. `report.records[0].filters.include`) and stores nothing
