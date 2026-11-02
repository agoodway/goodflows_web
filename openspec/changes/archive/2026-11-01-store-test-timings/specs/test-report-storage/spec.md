# Spec Delta

## Purpose

Retain externally generated test reports for authenticated accounts with reliable identity, completion metadata and retry semantics.

## ADDED Requirements

### Requirement: Test report ingestion uses existing account authentication
`POST /api/v1/projects/:project/test-reports` SHALL require a valid private API key and derive account ownership from authentication. Missing, expired or revoked keys MUST return 401, public keys MUST return 403, and client-supplied account identifiers MUST be rejected as unknown fields with 422. Authentication and project resolution SHALL both finish before the request body is read.

#### Scenario: Valid private key
- **WHEN** an authenticated publisher sends a valid test report
- **THEN** the report is stored under the key's account

#### Scenario: Public key
- **WHEN** a publisher uses a public key
- **THEN** the API returns 403 and stores nothing

#### Scenario: Missing or revoked key
- **WHEN** a request has no key, an expired key or a revoked key
- **THEN** the API returns 401 and stores nothing, including for an exact retry of a stored report

#### Scenario: Unauthenticated oversized upload
- **WHEN** a request with no API key declares or streams more than 32 MiB
- **THEN** the API returns 401 without reading the body

#### Scenario: Missing project does not read the body
- **WHEN** a private key posts more than 32 MiB to a path slug the account does not have
- **THEN** the API returns 404 without reading the body

#### Scenario: Invalid project slug does not read the body
- **WHEN** a private key posts to path slug `GoodCases`
- **THEN** the API returns 422 on `project` without reading the body

#### Scenario: Client-supplied account id
- **WHEN** an otherwise valid report includes `account_id` at any level
- **THEN** the API returns 422 for the unknown field and stores nothing

### Requirement: The ingestion contract identifies execution and report provenance
The API SHALL accept format `exunit-timings` on `POST /api/v1/projects/:project/test-reports`, with workflow invocation, workflow/environment, job status, source context, and a report of suite identity, report identity, partition metadata, and event records. Identities and integer microsecond timings MUST be stored exactly as supplied. The server MUST NOT derive, rewrite, or check per-test durations against receipt offsets.

#### Scenario: Independent partition reports
- **WHEN** three reports from one workflow job arrive
- **THEN** their shared workflow invocation and suite identities and their distinct report and partition identities are preserved

#### Scenario: Duration exceeds receipt interval
- **WHEN** a test's `duration_us` exceeds the gap between its started and finished `received_offset_us`
- **THEN** the report is accepted and the duration is stored unchanged

### Requirement: The path selects the project
The path slug MUST name an existing project of the authenticated account, using the same slug rule as other project routes. The row MUST store that project's id. The stored document MUST be the validated body and MUST NOT add a project slug. A body key `project` MUST return 422. An invalid path slug MUST return 422 on `project`. A slug the account does not have, including another account's slug, MUST return 404 and store nothing.

#### Scenario: Unknown project
- **WHEN** the path slug matches the grammar and the account has no such project
- **THEN** the API returns 404 and stores nothing

#### Scenario: Other account's project slug
- **WHEN** the slug exists only on another account
- **THEN** the API returns 404 and stores nothing

#### Scenario: Invalid project slug
- **WHEN** the path slug is `GoodCases` or `-app`
- **THEN** the API returns 422 on `project` and stores nothing

#### Scenario: Body supplies project
- **WHEN** an otherwise valid report includes `project`
- **THEN** the API returns 422 for the unknown field and stores nothing

#### Scenario: Project stored by id
- **WHEN** the account has a project with the path slug
- **THEN** the report row stores that project's id and the stored document has no project slug

#### Scenario: Same report under two projects
- **WHEN** one account posts the same external report identity to two of its projects
- **THEN** each project stores its own document

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
- **WHEN** a stored report is retried with the keys of nested objects in a different order
- **THEN** the API returns 200 with the stored id and `duplicate` true

#### Scenario: Reordered array elements
- **WHEN** a stored report is retried with the elements of an array (such as `files`) in a different order
- **THEN** the API returns 409 without changing the stored report

#### Scenario: Different accounts
- **WHEN** two accounts publish the same external identity tuple
- **THEN** each stores its own document without exposing the other's report identity

### Requirement: A test report blocks project deletion
Deleting a project that has a test report MUST return 409 and MUST keep the project and the report, including when that project has no recipes.

#### Scenario: Project delete keeps reports
- **WHEN** a project has a stored test report and a client deletes that project
- **THEN** the API returns 409 and both the project and the report remain

#### Scenario: Test report blocks delete of a project with no recipes
- **WHEN** a project has a stored test report and no recipes, and a client deletes that project
- **THEN** the API returns 409 and both the project and the report remain

### Requirement: Completion is derived for each report
The API SHALL mark a report complete only when its final record is a suite-finished event with `aborted` false, `unfinished_tests` and `unfinished_modules` both zero, no `interrupted` or `max_failures_reached` event anywhere in the report, and `truncated` false. Other accepted documents SHALL be incomplete. Test failures MUST remain distinct from report incompleteness. The server MUST NOT claim that receiving one partition completes an entire invocation.

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
The API SHALL validate event types, allowlisted fields, identifiers, nullable metadata, nonnegative integer timings, outcomes and nested file aggregates. Unknown fields, duplicate object keys, strings containing U+0000, captured logs, exception payloads, assertion values, arbitrary tags/parameters and unsupported formats MUST be rejected with 422. Objects and arrays MUST NOT nest more than 16 levels deep; a deeper body SHALL return 422 on `body` and SHALL be rejected before it is decoded. Error bodies SHALL use the existing validation error shape keyed by JSON path with fixed messages, without reflecting submitted values or submitted key names in errors or logs: an unknown or duplicate key SHALL be reported on its enclosing object. At most the first 50 errors, in document order, SHALL be returned.

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

### Requirement: Invalid or oversized requests are atomic failures
Requests SHALL be limited to 32 MiB before JSON decoding and 100,000 event records. A declared Content-Length over the limit SHALL return 413 without reading the body, and a streamed body exceeding the limit SHALL return 413. Requests whose Content-Type is not `application/json`, or whose Content-Encoding is present and not `identity`, SHALL return 415. Malformed JSON SHALL return 400, reports with more than 100,000 records SHALL return 422 on `report.records`, other structurally invalid documents SHALL return 422, and connection failures or timeouts during report persistence SHALL return 503 with `Retry-After`. A project deleted between project lookup and insert SHALL return 404; any other referenced row (the submitting API key or the account) disappearing before the insert SHALL return 503 with `Retry-After` and store nothing. Parser errors SHALL render JSON bodies regardless of the Accept header. A configurable per-node cap (default 2) and a configurable per-account cap (default 1) SHALL limit concurrent uploads; an admitted upload SHALL hold its slot through body reads, decoding, validation and persistence. An authenticated upload denied admission by either cap MUST return 503 with `Retry-After` without reading its body or writing a report. Admission MUST be released on success, errors and request-process termination. The body SHALL be read against a configurable overall deadline (default 60 seconds); a body not fully received by then SHALL return 408, store nothing and release admission. Transient database errors during persistence (connection failures, timeouts, serialization failures, deadlocks, insufficient resources, operator intervention and lock unavailability) SHALL return 503 with `Retry-After`; other database errors SHALL NOT expose the database message. Requests rejected before persistence MUST leave no report row behind. A persistence connection failure or timeout MAY leave a committed row when commit confirmation was lost; the API MUST return 503 without acknowledging an uncertain outcome, and an exact frozen retry MUST resolve through the same idempotency rules. Ingestion MUST NOT change unrelated API body limits.

#### Scenario: Oversized upload
- **WHEN** an authenticated request body exceeds 32 MiB
- **THEN** ingestion returns 413 without retaining a partial document

#### Scenario: Compressed upload
- **WHEN** a request is sent with `Content-Encoding: gzip`
- **THEN** the API returns 415 and stores nothing

#### Scenario: Too many records
- **WHEN** a body under 32 MiB contains 100,001 records
- **THEN** the API returns 422 on `report.records` and stores nothing

#### Scenario: Concurrency cap exhausted
- **WHEN** all configured body-read/decode slots are occupied and another authenticated upload for an existing project arrives
- **THEN** it receives 503 with `Retry-After` without its body being read or any report being written
- **AND** slots are reclaimed when admitted requests finish or terminate

#### Scenario: Per-account cap exhausted
- **WHEN** an account already holds its configured number of upload slots on a node and sends another upload
- **THEN** it receives 503 with `Retry-After` without its body being read
- **AND** another account's upload on that node is still admitted

#### Scenario: Slow upload
- **WHEN** an upload body is still arriving when the read deadline passes
- **THEN** the API returns 408, stores nothing and releases the upload's slot

#### Scenario: Commit confirmation lost
- **WHEN** a report commits but the persistence connection fails before confirmation reaches the server
- **THEN** the API returns 503 without a storage acknowledgement
- **AND** an exact frozen retry returns 200 with the committed report id and does not create another row

#### Scenario: Storage unavailable
- **WHEN** the database is unavailable during report insertion
- **THEN** the API returns 503 and does not return an acknowledgement

#### Scenario: API key deleted before insert
- **WHEN** the authenticated API key is deleted after authentication and before the report is inserted
- **THEN** the API returns 503 with `Retry-After` and stores nothing
- **AND** a retry with the same key fails authentication with 401

#### Scenario: Other routes keep their limits
- **WHEN** a request is sent to an existing `/api/v1` route
- **THEN** it is parsed with the existing parser options and body limit

### Requirement: Successful responses acknowledge storage without returning report contents
201 and 200 responses SHALL return a stable server id, external report id, complete/incomplete status and whether the request was a duplicate. The API MUST NOT return the stored event document in acknowledgements. Test report storage SHALL remain independent of Spry recipe execution.

#### Scenario: Storage-only ingestion
- **WHEN** a report is accepted
- **THEN** the response acknowledges it without starting a recipe, running a job, displaying a dashboard or calculating test groups
