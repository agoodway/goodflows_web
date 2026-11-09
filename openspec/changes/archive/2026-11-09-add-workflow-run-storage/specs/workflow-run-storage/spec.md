# Spec Delta

## Purpose

Stores goodflows run-history documents uploaded by the `goodflows` CLI, one immutable record per workflow run within an account's project, and lets API clients list and retrieve them to compare runs across commits.

## ADDED Requirements

### Requirement: Workflow run upload requires a private key and a project
`POST /api/v1/projects/:project/workflow-runs` SHALL require a valid private (`sk_`) API key and derive the account from it. Missing, expired or revoked keys MUST return `401` and public keys `403`. The path slug MUST name a project of that account: an invalid slug returns `422` on `project`, and an unknown slug, including another account's, returns `404`. Authentication and project resolution MUST finish before the body is read.

#### Scenario: Private key uploads a run
- **WHEN** a client with an `sk_` key posts a valid run-history document to an existing project of its account
- **THEN** the API responds `201` and stores the run under that account and project

#### Scenario: Public key
- **WHEN** a client with a `pk_` key posts a run-history document
- **THEN** the API responds `403`, does not read the body, and stores nothing

#### Scenario: Unknown project
- **WHEN** a client posts to a slug that exists only on another account
- **THEN** the API responds `404` without reading the body and stores nothing

#### Scenario: Invalid project slug
- **WHEN** a client posts to the slug `GoodCases`
- **THEN** the API responds `422` with an error on `project`, does not read the body, and stores nothing

#### Scenario: Missing, expired, or revoked key
- **WHEN** a client with no key, an expired key, or a revoked key posts a document, including an exact retry of a stored run
- **THEN** the API responds `401`, does not read the body, and stores nothing

#### Scenario: Public key on an invalid slug
- **WHEN** a client with a `pk_` key posts to the slug `GoodCases`
- **THEN** the API responds `403` without reading the body and stores nothing

### Requirement: Clients must accept JSON
A request to any workflow-run route whose `Accept` header does not allow `application/json` MUST return `406` from the API pipeline before the body is read.

#### Scenario: Unacceptable Accept
- **WHEN** a client posts or lists with `Accept: text/plain`
- **THEN** the API responds `406` and, on a post, does not read the body

### Requirement: The body is a run-history document
The body SHALL be one goodflows run-history JSON object with `schema_version` `1`. Its required keys are `schema_version`, `workflow`, `run_id`, `started_at`, `outcome`, `duration_ms`, `parallelism`, `graph_sha256`, `max_in_flight`, `host`, and `results`. Its optional keys are `environment`, `requested_jobs`, `source`, `parent_run_id`, and `caller_job`. The body MUST NOT carry a project or account: `project`, `account_id`, and any other key are unknown fields (`422`).

#### Scenario: Minimal document
- **WHEN** a client posts a document with only the required keys and an empty `results` array
- **THEN** the API responds `201`

#### Scenario: Unsupported schema version
- **WHEN** a client posts a document whose `schema_version` is `2`
- **THEN** the API responds `422` with an error on `schema_version` and stores nothing

#### Scenario: Body names the project
- **WHEN** a client posts a document containing a `project` key
- **THEN** the API responds `422` with `has an unknown field` on `body` and stores nothing

### Requirement: A child run names its caller
`parent_run_id` and `caller_job` are optional and omit-only. `parent_run_id`, when present, MUST be a lowercase canonical UUID under the same rule as `run_id`. `caller_job`, when present, MUST follow the name rule. The two keys MUST both be present or both be absent. A null does not count as presence. The server MUST NOT require `parent_run_id` to identify a stored run, or `caller_job` to name a result on another document. A child document may be stored before its parent.

#### Scenario: Child run
- **WHEN** a client posts a document with `parent_run_id` `fb7d2711-6b67-4f5a-9104-492032a9e1e5` and `caller_job` `call-suite`
- **THEN** the API responds `201` and both values are stored as given

#### Scenario: Parent run id without caller job
- **WHEN** a document has `parent_run_id` set to a lowercase canonical UUID and omits `caller_job`
- **THEN** the API responds `422` with an error on `parent_run_id` and stores nothing

#### Scenario: Caller job without parent run id
- **WHEN** a document has `caller_job` `call-suite` and omits `parent_run_id`
- **THEN** the API responds `422` with an error on `caller_job` and stores nothing

### Requirement: Optional keys are omit-only
An optional key MUST be absent or a value. Null is invalid on every optional key, including `parent_run_id`, `caller_job`, a result's `workflow`, and a result's `child_run_id`. In the uploaded document, the only keys that may be null are the required result keys `command`, `exit_code`, and `error`. Omitting any of those three is a missing required key (`422`). A null does not count as presence. A list summary may still be null for an absent `environment` or `source`.

#### Scenario: Null on a workflow-call optional
- **WHEN** a document sets `parent_run_id`, `caller_job`, a result's `workflow`, or a result's `child_run_id` to null
- **THEN** the API responds `422` with an error on that key and stores nothing

### Requirement: The upload envelope is out of scope
Top-level `graph` and `ci`, and a `branch` key on `source`, MUST be rejected as unknown fields (`422`). Accepting the CLI upload envelope that adds those keys is a follow-up and MUST NOT be treated as part of this change.

#### Scenario: Graph or ci on the document
- **WHEN** a client posts a document containing a top-level `graph` or `ci` key
- **THEN** the API responds `422` with `has an unknown field` on `body` and stores nothing

### Requirement: Run-level fields are validated
`run_id` MUST be a lowercase canonical UUID. `started_at` MUST be RFC 3339 UTC to the second (`YYYY-MM-DDTHH:MM:SSZ`). `outcome` MUST be `passed`, `failed`, or `cancelled`. `graph_sha256` MUST be 64 lowercase hex characters. `duration_ms` and `max_in_flight` MUST be nonnegative integers and `parallelism` a positive integer. `workflow` and `environment` MUST follow the name rule. `requested_jobs`, when present, MUST be a nonempty array of at most 1,024 names.

#### Scenario: Uppercase run id
- **WHEN** a client posts a document whose `run_id` contains uppercase hex digits
- **THEN** the API responds `422` with an error on `run_id`

#### Scenario: Fractional seconds
- **WHEN** a client posts `started_at` `2026-11-05T12:00:00.123Z`
- **THEN** the API responds `422` with an error on `started_at`

#### Scenario: Environment and requested jobs
- **WHEN** a client posts a document with `environment` `ci` and `requested_jobs` `["test"]`
- **THEN** the API responds `201` and both values are stored as given

#### Scenario: Empty requested jobs
- **WHEN** a document's `requested_jobs` is `[]`
- **THEN** the API responds `422` with an error on `requested_jobs`

#### Scenario: Too many requested jobs
- **WHEN** a document's `requested_jobs` has 1,025 names
- **THEN** the API responds `422` with an error on `requested_jobs`

### Requirement: Names follow one rule
Every workflow name (the document's `workflow` and a result's `workflow`), environment, requested job, `caller_job`, instance name, and step id in a document MUST be a string of 1 to 64 UTF-8 bytes that contains no control characters and is not only whitespace. Names are case-sensitive and MUST be stored without normalization.

#### Scenario: Long instance name
- **WHEN** a result's `name` is 65 bytes long
- **THEN** the API responds `422` with an error on `results[<index>].name`

#### Scenario: Whitespace workflow
- **WHEN** a document's `workflow` is `"   "`
- **THEN** the API responds `422` with an error on `workflow`

### Requirement: Host and source are structural only
`host` MUST contain `os` and `arch` (names), `logical_cpus` (a positive integer), and optionally `mem_total_bytes` and `mem_available_bytes` (nonnegative integers). `source`, when present, MUST contain `commit` (40 or 64 lowercase hex characters) and optionally `dirty` (a boolean). Any other key in either object is an unknown field (`422`).

#### Scenario: Host without memory
- **WHEN** a document's `host` has only `os`, `arch`, and `logical_cpus`
- **THEN** the API responds `201`

#### Scenario: Branch in source
- **WHEN** a document's `source` contains a `branch` key
- **THEN** the API responds `422` with `has an unknown field` on `source`

### Requirement: Each result describes one instance
Each `results` entry MUST contain `name`, `status` (`passed`, `failed`, `skipped`, `timed_out`, or `cancelled`), `started` (a boolean), `exit_code` (null or an integer from -2147483648 through 2147483647), `command` and `error` (null or a string of at most 1,024 UTF-8 bytes), and nonnegative integer `duration_ms`, `blocked_ms`, and `queued_ms`. It MAY contain `partition`, `commands`, `workflow`, and `child_run_id`, and no other key.

#### Scenario: Result with command output
- **WHEN** a result contains a `stdout` key
- **THEN** the API responds `422` with `has an unknown field` on `results[<index>]` and stores nothing

#### Scenario: Oversized command text
- **WHEN** a result's `command` is 1,025 bytes long
- **THEN** the API responds `422` with an error on `results[<index>].command`

#### Scenario: Exit code out of range
- **WHEN** a result's `exit_code` is 2147483648
- **THEN** the API responds `422` with an error on `results[<index>].exit_code`

### Requirement: A result may record a workflow call
A result MAY contain `workflow` (the call target; the name rule; omit-only) and `child_run_id` (a lowercase canonical UUID under the same rule as `run_id`; omit-only). `child_run_id` is allowed only when that result's `workflow` is present. `workflow` MAY be present without `child_run_id`. The server MUST NOT require `child_run_id` to identify a stored run. A result's `workflow` does not further constrain `command`, `exit_code`, or `error`.

#### Scenario: Workflow call result
- **WHEN** a result has `workflow` `suite`, `child_run_id` `0e54fb55-a115-4ac7-80fe-8fde26e76afb`, and `command`, `exit_code`, and `error` all null
- **THEN** the API responds `201` and stores that result as given

#### Scenario: Call without a child run
- **WHEN** a result has `workflow` `suite`, omits `child_run_id`, and has `command`, `exit_code`, and `error` all null
- **THEN** the API responds `201`

#### Scenario: Child run id without workflow
- **WHEN** a result has `child_run_id` set to a lowercase canonical UUID and omits `workflow`
- **THEN** the API responds `422` with an error on `results[<index>].child_run_id` and stores nothing

### Requirement: Partitions and command costs are validated
`partition`, when present, MUST be `{"index": i, "count": n}` with `1 <= n <= 64` and `1 <= i <= n`. `commands`, when present, MUST be a nonempty array of at most 1,024 entries. Each entry MUST contain `kind` (`condition` or `command`) and a nonnegative integer `wall_ms`. It MAY contain `step` (the name rule), nonnegative integers `cpu_user_ms` and `cpu_system_ms`, and a positive integer `peak_rss_bytes`. Those keys are omit-only: null is invalid for any of them.

#### Scenario: Partition index beyond count
- **WHEN** a result has `partition` `{"index": 4, "count": 3}`
- **THEN** the API responds `422` with an error on `results[<index>].partition`

#### Scenario: Zero peak memory
- **WHEN** a command entry has `peak_rss_bytes` `0`
- **THEN** the API responds `422` with an error on that entry's `peak_rss_bytes`

#### Scenario: Step cost
- **WHEN** a command entry has `kind` `command`, `step` `compile`, `wall_ms`, and CPU times, and omits `peak_rss_bytes`
- **THEN** the API responds `201` and stores the entry as given

#### Scenario: Empty commands
- **WHEN** a result's `commands` is `[]`
- **THEN** the API responds `422` with an error on `results[<index>].commands`

#### Scenario: Too many command costs
- **WHEN** a result's `commands` has 1,025 entries
- **THEN** the API responds `422` with an error on `results[<index>].commands`

### Requirement: Outcome agrees with result statuses
A document MUST be rejected with `422` on `outcome` when `outcome` is `failed` and no result is `failed` or `timed_out`, or when `outcome` is not `failed` and some result is `failed` or `timed_out`, or when `outcome` is `passed` and some result is `cancelled`. A `cancelled` outcome with no cancelled result MUST be accepted, because a signal can cancel a run after its last job finishes.

#### Scenario: Passed run with a failure
- **WHEN** a document has `outcome` `passed` and one result `failed`
- **THEN** the API responds `422` with an error on `outcome`

#### Scenario: Failed with no failure
- **WHEN** a document has `outcome` `failed` and every result `passed`
- **THEN** the API responds `422` with an error on `outcome`

#### Scenario: Passed run with a cancellation
- **WHEN** a document has `outcome` `passed` and one result `cancelled`
- **THEN** the API responds `422` with an error on `outcome`

#### Scenario: Signal after the last job
- **WHEN** a document has `outcome` `cancelled` and every result `passed`
- **THEN** the API responds `201`

### Requirement: Malformed or oversized uploads store nothing
Bodies over a server-configured limit (default 4 MiB) MUST return `413`, without reading the body when the declared length is over the limit. A non-JSON Content-Type or any Content-Encoding other than `identity` MUST return `415`. Malformed JSON MUST return `400`. Duplicate keys, U+0000 in a string, nesting deeper than 8 levels, non-integer numbers, and integers above 2^53-1 MUST return `422`. A body not fully read within the server's read deadline MUST return `408`.

#### Scenario: Oversized upload
- **WHEN** a client declares a Content-Length one byte over the limit
- **THEN** the API responds `413` without reading the body and stores nothing

#### Scenario: Duplicate key
- **WHEN** a document contains the key `outcome` twice
- **THEN** the API responds `422` with `has a duplicate key` on `body` and stores nothing

#### Scenario: Gzip body
- **WHEN** a client sends `Content-Encoding: gzip`
- **THEN** the API responds `415` and stores nothing

#### Scenario: Streamed body over the limit
- **WHEN** a client streams a body one byte over the limit without declaring that length
- **THEN** the API responds `413` and stores nothing

#### Scenario: Non-JSON content type
- **WHEN** a client sends `Content-Type: text/plain`
- **THEN** the API responds `415` and stores nothing

#### Scenario: Malformed JSON
- **WHEN** a client posts a body of `{`
- **THEN** the API responds `400` and stores nothing

#### Scenario: Read deadline
- **WHEN** the body is not fully read within the server's read deadline
- **THEN** the API responds `408` and stores nothing

#### Scenario: NUL in a string
- **WHEN** a document's `workflow` contains U+0000
- **THEN** the API responds `422` and stores nothing

#### Scenario: Nesting too deep
- **WHEN** a document nests objects or arrays 9 levels deep
- **THEN** the API responds `422` and stores nothing

#### Scenario: Non-integer number
- **WHEN** a document's `duration_ms` is the JSON number `1.0`
- **THEN** the API responds `422` with an error on `duration_ms` and stores nothing

#### Scenario: Integer above the safe range
- **WHEN** a document's `duration_ms` is 9007199254740992
- **THEN** the API responds `422` with an error on `duration_ms` and stores nothing

### Requirement: Validation errors never echo submitted values
`422` responses SHALL map JSON paths (for example `results[3].status`) to messages from a fixed list, at most the first 50 errors in document order. An unknown or duplicate key MUST be reported on its enclosing object without naming the key. Error responses, logs, and error reports MUST NOT include the document or any submitted value.

#### Scenario: Unknown key is not echoed
- **WHEN** a document contains an unknown key `secret_token_xyz`
- **THEN** the `422` response does not contain `secret_token_xyz`

#### Scenario: Command text is not echoed
- **WHEN** an invalid document places a sentinel string in a result's `command`
- **THEN** that sentinel appears in neither the `422` response, the logs, nor the error report

#### Scenario: Error cap
- **WHEN** a document has 51 validation errors
- **THEN** the `422` response contains the first 50 errors in document order and omits the 51st

### Requirement: A run is stored once per project
The account, project, and `run_id` SHALL identify one immutable stored run. The first upload MUST return `201`. An upload whose validated body is the same JSON value (object key order ignored, arrays in order, strings exact, integers by value) MUST return `200` with the same server id. Any other difference MUST return `409` without revealing the stored id or document. Concurrent uploads MUST follow the same rules and create one row.

#### Scenario: Exact retry
- **WHEN** a client uploads the same document twice, with its keys in a different order the second time
- **THEN** the first response is `201`, the second is `200` with `duplicate` true, and both carry the same `id`

#### Scenario: Conflicting reuse of a run id
- **WHEN** a client uploads a document whose `run_id` is already stored in that project with a different `outcome`
- **THEN** the API responds `409`, the stored run is unchanged, and the response contains neither the stored id nor its document

#### Scenario: Concurrent identical uploads
- **WHEN** two identical uploads of a new run arrive at once
- **THEN** one responds `201`, the other `200`, and exactly one row exists

#### Scenario: Same run id in another project
- **WHEN** a run id already stored under project `a` is uploaded to project `b` of the same account
- **THEN** the API responds `201` and stores a separate run under `b`

#### Scenario: Reordered results
- **WHEN** a client uploads a document whose `results` array is the stored array in a different order
- **THEN** the API responds `409` and the stored run is unchanged

#### Scenario: Concurrent conflicting uploads
- **WHEN** two uploads of a new run id arrive at once and differ in `duration_ms`
- **THEN** one responds `201`, the other `409`, and exactly one row exists

### Requirement: Upload acknowledgements do not return the document
`201` and `200` responses SHALL return `data` with the server `id`, the `run_id`, and `duplicate`. They MUST NOT return the stored document. A violation of `workflow_runs_project_id_fkey` MUST return `404`. Any other foreign-key violation, a dropped connection, or any other transient or unknown commit MUST return `503` with `Retry-After`. When a lost commit left a row, an exact retry MUST return `200`. The server MUST NOT acknowledge an upload before it is committed.

#### Scenario: Acknowledgement shape
- **WHEN** a new run is stored
- **THEN** the response is `201` with `{"data": {"id": "<uuid>", "run_id": "<run_id>", "duplicate": false}}` and no document fields

#### Scenario: Database unavailable
- **WHEN** the database connection fails while the run is being stored
- **THEN** the API responds `503` with `Retry-After`

#### Scenario: Project deleted during upload
- **WHEN** the project is deleted after resolution and the insert violates `workflow_runs_project_id_fkey`
- **THEN** the API responds `404`

#### Scenario: Other foreign key
- **WHEN** the insert violates a foreign key other than `workflow_runs_project_id_fkey`
- **THEN** the API responds `503` with `Retry-After`

#### Scenario: Lost commit
- **WHEN** the insert commits and the connection drops before the acknowledgement
- **THEN** the client sees `503`, and an exact retry responds `200` with `duplicate` true

### Requirement: List a project's workflow runs
`GET /api/v1/projects/:project/workflow-runs` SHALL accept any valid key of the account and return run summaries newest `started_at` first, with ties broken by `run_id` descending. Pages MUST use keyset pagination on (`started_at` descending, `run_id` descending), with `limit` (1 to 200, default 50) and `cursor` (the previous page's `next_cursor`, null on the last page). A run uploaded after a page was read MUST NOT shift the next page. Summaries MUST NOT include `results`.

#### Scenario: Newest first
- **WHEN** a run that started yesterday is uploaded after a run that started today
- **THEN** the list returns today's run first

#### Scenario: Paging
- **WHEN** a project has 3 runs and a client lists with `limit=2`, then with the returned `cursor`
- **THEN** the first page has 2 runs and a `next_cursor`, and the second has 1 run and `next_cursor` null

#### Scenario: Same start time
- **WHEN** two runs have the same `started_at` and different `run_id` values
- **THEN** the list returns the greater `run_id` first

#### Scenario: Insert between pages
- **WHEN** a client has read a page and a run that sorts onto that page is uploaded before the next page
- **THEN** the next page repeats no run from the first page and skips no run that was already stored

#### Scenario: Public key can list
- **WHEN** a client with a `pk_` key lists runs
- **THEN** the API responds `200`

### Requirement: Run summaries carry the comparison fields
Each summary SHALL include `id`, `run_id`, `workflow`, `environment` (null when absent), `outcome`, `started_at`, `duration_ms`, `parallelism`, `max_in_flight`, `graph_sha256`, `source`, `host`, and `inserted_at`. `source` MUST be null when the document had no source. Otherwise it MUST be an object with `commit`, plus `dirty` only when the document included `dirty`. `host` MUST be the stored host object, with memory fields omitted when the document omitted them.

#### Scenario: Run outside a git checkout
- **WHEN** a stored run's document had no `source` or `environment`
- **THEN** its summary has `source` null and `environment` null

#### Scenario: Commit without dirty
- **WHEN** a stored document's `source` is `{"commit": "<64 lowercase hex>"}` and has no `dirty` key
- **THEN** the summary `source` is that same object and has no `dirty` key

### Requirement: The list can be filtered
The list SHALL accept the exact-match filters `workflow`, `environment`, `outcome`, `commit` (matching `source.commit`), and `graph_sha256`, combined with AND. A filter value that breaks its field's rule, an invalid `limit`, or an invalid `cursor` MUST return `422` on that parameter. Unknown query parameters SHALL be ignored.

#### Scenario: Same graph across commits
- **WHEN** a client lists with `workflow=ci&graph_sha256=<hex>`
- **THEN** only runs of workflow `ci` with that graph hash are returned

#### Scenario: Invalid outcome filter
- **WHEN** a client lists with `outcome=green`
- **THEN** the API responds `422` with an error on `outcome`

#### Scenario: Unknown query parameter
- **WHEN** a client lists with `color=blue`
- **THEN** the API responds `200` and does not filter on `color`

#### Scenario: Invalid name filter
- **WHEN** a client lists with a `workflow` of 65 bytes, or an `environment` that is only whitespace
- **THEN** the API responds `422` with an error on that parameter

### Requirement: Show one workflow run
`GET /api/v1/projects/:project/workflow-runs/:run_id` SHALL accept any valid key and return `data` with `id`, `run_id`, `inserted_at`, and `document`. For a private key, `document` MUST equal the upload as a JSON value (key order not preserved). A public key MUST follow "Public keys do not see command text or errors". A missing run, a run under another project or account, or a `run_id` that is not a lowercase canonical UUID MUST return `404` and MUST NOT be looked up after downcasing.

#### Scenario: Round trip
- **WHEN** a client with an `sk_` key shows a stored run
- **THEN** `data.document` equals the uploaded document as a JSON value

#### Scenario: Run in another project
- **WHEN** a run is stored under project `a` and a client shows its `run_id` under project `b`
- **THEN** the API responds `404`

### Requirement: Public keys do not see command text or errors
For a public (`pk_`) key, every `results` entry in `document` MUST have `command` and `error` set to null. Private keys MUST see them as stored. The stored row MUST NOT change.

#### Scenario: Public key reads a run
- **WHEN** a client with a `pk_` key shows a run whose results have commands and errors
- **THEN** every result in `data.document` has `command` null and `error` null, every other field is as stored, and a later `sk_` show of that run still has the stored `command` and `error`

### Requirement: Show lists the run's test reports
The show response SHALL include `test_reports`, a list of the test reports stored in the same account and project whose `workflow_run_id` equals the run's `run_id`, ordered by `job` then `report_id`. Each has `id`, `job`, `job_status`, `suite_id`, `report_id`, `partition`, `partition_count`, and `status`, and MUST NOT include report contents. A run with no such reports MUST return an empty list.

#### Scenario: Reports uploaded before the run
- **WHEN** a test report with `workflow_run_id` X is stored, and then a run with `run_id` X is uploaded and shown
- **THEN** `test_reports` lists that report

#### Scenario: Reports in another project
- **WHEN** a test report with `workflow_run_id` X is stored under project `b` and the run X is shown under project `a`
- **THEN** `test_reports` is empty

#### Scenario: Report summary order and fields
- **WHEN** two reports for the run have `job` and `report_id` values that sort differently by `job` than by `report_id`
- **THEN** `test_reports` lists them by `job` then `report_id`, each entry has only `id`, `job`, `job_status`, `suite_id`, `report_id`, `partition`, `partition_count`, and `status`, and no entry includes report contents
