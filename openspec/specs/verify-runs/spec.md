# verify-runs Specification

## Purpose

Stores `verify-run/1` documents, the record of an agent grading one commit against one scenario set, with their artifacts in object storage, and defines which runs count as evidence for a change request.

## Requirements

### Requirement: Verify run routes require a key of the account
Every route under `/api/v1/projects/:project/verify-runs` SHALL require a valid key of the project's account: missing, expired or revoked keys get `401`. Uploading and committing MUST require an `sk_` key; a `pk_` key MUST get `403`. Listing and showing MUST accept `sk_` and `pk_` keys. A `ck_` key MUST get `403` on every route. An invalid slug gets `422` on `project` and an unknown one `404`, before the body is read.

#### Scenario: Private key uploads a run
- **WHEN** a client with an `sk_` key posts a valid `verify-run/1` document with no artifacts to project `goodcases`
- **THEN** the API responds `201` and stores the run under that project with `status` `final`

#### Scenario: Public key uploads a run
- **WHEN** a client with a `pk_` key posts a run
- **THEN** the API responds `403`, does not read the body, and stores nothing

#### Scenario: Cache key lists runs
- **WHEN** a client with a `ck_` key lists verify runs of its own project
- **THEN** the API responds `403`

### Requirement: A verify run belongs to a project
A verify run SHALL be stored under its project, not under a change request, and MAY be uploaded before any change request names its commit. The body MUST NOT carry a project, account or change request: such keys are unknown fields (`422`).

#### Scenario: Run before the change request
- **WHEN** a run for commit `aaaa…` is uploaded and change request 42 later reports `aaaa…` as its head
- **THEN** the run can count for change request 42 without being uploaded again

#### Scenario: Body names a change request
- **WHEN** a run document has a `change_request` key
- **THEN** the API responds `422` with `has an unknown field` on `body`

### Requirement: The body is a verify-run/1 document
The body SHALL be a JSON object with `format` `verify-run/1` and the required keys `run_id`, `started_at`, `finished_at`, `source`, `scenario_set`, `results`, `features`, `drift` and `artifacts`; the optional keys are `merge_result`, `links` and `workflow_run_id`. Unknown keys MUST get `422`. Body limits and JSON rules SHALL be those of workflow run uploads, including `413`, `415`, `400` and `422`.

#### Scenario: Minimal run
- **WHEN** a client posts a run with every required key, empty `features`, `drift` and `artifacts`, and a result for each scenario of its set
- **THEN** the API responds `201`

#### Scenario: Unsupported format
- **WHEN** a run has `format` `verify-run/2`
- **THEN** the API responds `422` with an error on `format` and stores nothing

### Requirement: Run fields are validated
`run_id` MUST be a lowercase canonical UUID. `started_at` and `finished_at` MUST be RFC 3339 times with `finished_at` not before `started_at`. `source` MUST have `commit` (40 or 64 lowercase hex), `branch` (1 to 256 bytes, no control characters, or null), `dirty` (boolean) and `changed_files` (at most 10,000 paths). Validation errors MUST NOT echo submitted values.

#### Scenario: Finished before started
- **WHEN** a run has `finished_at` one second before `started_at`
- **THEN** the API responds `422` with an error on `finished_at`

#### Scenario: Short commit
- **WHEN** `source.commit` is `abc1234`
- **THEN** the API responds `422` with an error on `source.commit`

#### Scenario: Missing dirty flag
- **WHEN** `source` has no `dirty` key
- **THEN** the API responds `422` with an error on `source.dirty`

### Requirement: A run names the scenario set it graded
`scenario_set` MUST be `{digest, source}` with `digest` 64 lowercase hex characters and `source` `intent` or `diff`. A version of a set of that source with that digest MUST already be stored on some change request of the same project; otherwise the API MUST respond `422` on `scenario_set.digest` and store nothing.

#### Scenario: Unknown digest
- **WHEN** a run names a digest that no scenario set of the project has
- **THEN** the API responds `422` with an error on `scenario_set.digest` and stores nothing

#### Scenario: Digest from another project
- **WHEN** a run in project `beta` names the digest of a set stored only in project `alpha`
- **THEN** the API responds `422` with an error on `scenario_set.digest`

#### Scenario: Source does not match
- **WHEN** a run names the digest of an intent set with `source` `diff`
- **THEN** the API responds `422` with an error on `scenario_set.digest`

### Requirement: A run has a result for every scenario
`results` MUST hold exactly one entry per scenario ID of the named set: `{id, result, failed_step, reason, evidence}` with `result` `passed`, `failed` or `not_run`, `failed_step` and `reason` strings of at most 4,096 bytes or null, and `evidence` a list of artifact IDs from `artifacts`. `id` MAY be a string or a positive integer and is matched in string form. A missing, extra or duplicate ID MUST get `422` on `results` and store nothing.

#### Scenario: Missing a Must scenario
- **WHEN** the set has scenarios `S1`, `S2` and `S3` and a run has results only for `S1` and `S2`
- **THEN** the API responds `422` with an error on `results` and stores nothing

#### Scenario: Extra scenario
- **WHEN** a run has a result for `S9` and the set has no `S9`
- **THEN** the API responds `422` with an error on `results`

#### Scenario: Evidence names a missing artifact
- **WHEN** a result's `evidence` lists `shot-4` and `artifacts` has no `shot-4`
- **THEN** the API responds `422` with an error on `results`

### Requirement: A run lists features, drift and links
`features` MUST be a list of at most 500 entries `{id, entry_point, result}` with `result` `passed`, `failed` or `not_run`; feature IDs are stored as given and need not be in the feature index. `drift` MUST be a list of at most 100 strings of at most 1,024 bytes. `links`, when present, MUST have the workflow run `links` shape.

#### Scenario: Feature not in the index
- **WHEN** a run lists feature `billing` and the feature index has no `billing`
- **THEN** the API responds `201` and stores the entry

#### Scenario: Unknown feature result
- **WHEN** a feature entry has `result` `skipped`
- **THEN** the API responds `422` with an error on `features`

### Requirement: A run may name a merge result and a workflow run
`merge_result`, when present and not null, MUST be `{base, commit}` with two commits of 40 or 64 lowercase hex characters. `workflow_run_id`, when present and not null, MUST be a lowercase canonical UUID; the server SHALL store it without requiring that workflow run to exist.

#### Scenario: Merge-result run
- **WHEN** a run has `merge_result` `{base: "cccc…", commit: "dddd…"}`
- **THEN** the API responds `201` and stores it

#### Scenario: Workflow run not uploaded yet
- **WHEN** a run names a `workflow_run_id` no stored workflow run has
- **THEN** the API responds `201`

### Requirement: Dirty runs are stored and never count
A run with `source.dirty` true SHALL be stored like any other run and MUST NOT count as evidence for any change request.

#### Scenario: Dirty run on the head
- **WHEN** a final run with `dirty` true grades the current approved intent set at the head of change request 42
- **THEN** the run is listed under the project, and the verdict of change request 42 does not use its results

### Requirement: A verify run is stored once per project
The project and `run_id` SHALL identify one run. The first upload MUST respond `201`. An upload whose document is the same JSON value (canonical digest) MUST respond `200` with `duplicate` true and the same `id`. A different document MUST respond `409` without revealing the stored one. Concurrent uploads MUST create one row.

#### Scenario: Exact retry
- **WHEN** a client uploads the same run twice with keys in a different order
- **THEN** the first responds `201`, the second `200` with `duplicate` true and the same `id`

#### Scenario: Conflicting reuse
- **WHEN** a client uploads a run whose `run_id` is stored with a different `results` entry
- **THEN** the API responds `409` and the stored run is unchanged

#### Scenario: Same run id in another project
- **WHEN** a `run_id` stored under project `a` is uploaded to project `b`
- **THEN** the API responds `201`

### Requirement: Artifacts are declared in the run
`artifacts` MUST be a list of at most 200 entries `{id, path, content_type, size, sha256}`: `id` unique within the run and matching `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`, `path` 1 to 1,024 bytes, `content_type` a MIME type, `size` 1 through 52,428,800, and `sha256` 64 lowercase hex characters. A larger `size` MUST get `413`; more entries or any other invalid entry MUST get `422`.

#### Scenario: Artifact over 50 MB
- **WHEN** an artifact has `size` 52,428,801
- **THEN** the API responds `413` and stores nothing

#### Scenario: 201 artifacts
- **WHEN** a run declares 201 artifacts
- **THEN** the API responds `422` with an error on `artifacts`

### Requirement: A run with artifacts starts as uploading
When `artifacts` is not empty, a new run SHALL be stored with `status` `uploading` and the response MUST include `expires_at` and, per artifact, `artifact_id`, `upload_url`, `upload_headers` and `upload_url_expires_at`. Each object MUST be named by the server. `upload_headers` MUST carry `content-length`, `content-type` and `x-amz-checksum-sha256`, signed into `upload_url`, as for cache uploads.

#### Scenario: Upload URLs for two artifacts
- **WHEN** a client posts a run with artifacts `shot-1` (120,000 bytes) and `transcript` (8,000 bytes)
- **THEN** the API responds `201` with `status` `uploading` and two uploads whose `upload_headers` carry `content-length` `120000` and `8000` and the base64 of each `sha256`

#### Scenario: Object store rejects a different body
- **WHEN** a client PUTs bytes whose SHA-256 differs from the declared `sha256`
- **THEN** the object store rejects the PUT

#### Scenario: Retry while uploading
- **WHEN** a client uploads the same document again while the run is `uploading`
- **THEN** the API responds `200` with `duplicate` true and fresh upload URLs for every artifact

### Requirement: Commit makes an uploading run final
`POST /api/v1/projects/:project/verify-runs/:run_id/commit` SHALL check that each artifact's object exists with the declared length and SHA-256 and then set `status` `final`. A missing or mismatched object MUST get `422` on `artifacts` naming the artifact IDs, and the run MUST stay `uploading`. An unreachable store MUST get `503` with `retry-after`.

#### Scenario: Commit after every PUT
- **WHEN** a client PUTs both artifacts and commits
- **THEN** the API responds `200` with `status` `final`

#### Scenario: Commit with a missing artifact
- **WHEN** a client PUTs `shot-1` only and commits
- **THEN** the API responds `422` naming `transcript`, the run stays `uploading`, and a commit after PUTting `transcript` responds `200`

#### Scenario: Retried commit
- **WHEN** a client commits a run that is already `final`
- **THEN** the API responds `200` with the same run

#### Scenario: Store unreachable
- **WHEN** the object store cannot answer during a commit
- **THEN** the API responds `503` with `retry-after: 1` and the run stays `uploading`

### Requirement: Only the uploading key commits
A commit MUST respond `404` when the run does not exist in the project, has expired, or was uploaded by a different API key. A run without artifacts SHALL be `final` at upload and needs no commit.

#### Scenario: Commit by another key
- **WHEN** a key that did not upload a run commits it
- **THEN** the API responds `404` and the run stays `uploading`

#### Scenario: Run without artifacts
- **WHEN** a client uploads a run with empty `artifacts`
- **THEN** the API responds `201` with `status` `final` and no upload URLs

### Requirement: Final runs are immutable
A `final` run's document, status and artifact objects MUST NOT change. No route updates or deletes a run. Only `final` runs count as evidence.

#### Scenario: Uploading run does not count
- **WHEN** a run grading the head of change request 42 is `uploading`
- **THEN** the verdict of change request 42 does not use its results

### Requirement: Uploading runs expire
An `uploading` run not committed within the cache reservation TTL (default 7,200 seconds) MUST be deleted by the sweep, and its objects queued for deletion. A commit after `expires_at` MUST get `404`, and a later upload of the same `run_id` MUST respond `201` as a new run.

#### Scenario: Abandoned upload
- **WHEN** a run stays `uploading` for 7,201 seconds and the sweep runs
- **THEN** the run is deleted, its uploaded objects are removed from the bucket, and its `run_id` can be uploaded again

### Requirement: Artifacts need configured object storage
When no bucket is configured, a run with at least one artifact MUST get `503` and store nothing, and a run with empty `artifacts` MUST be accepted. Presigned URLs MUST NOT appear in logs, error responses or error reports.

#### Scenario: No bucket and no artifacts
- **WHEN** the server has no bucket and a client uploads a run with empty `artifacts`
- **THEN** the API responds `201` with `status` `final`

#### Scenario: No bucket with artifacts
- **WHEN** the server has no bucket and a client uploads a run with one artifact
- **THEN** the API responds `503` and stores nothing

### Requirement: List a project's verify runs
`GET /api/v1/projects/:project/verify-runs` SHALL return run summaries (`id`, `run_id`, `status`, `started_at`, `finished_at`, `source.commit`, `source.branch`, `source.dirty`, `scenario_set`, result counts) newest `finished_at` first, ties by `run_id` descending, keyset-paged with `limit` (1 to 200, default 50) and `cursor`. Optional filters: `commit`, `digest`, `status`.

#### Scenario: Filter by commit
- **WHEN** a client lists runs with `commit` `aaaa…`
- **THEN** only runs whose `source.commit` is `aaaa…` are returned

#### Scenario: Result counts
- **WHEN** a run has 4 `passed`, 1 `failed` and 1 `not_run` results
- **THEN** its summary has counts `{passed: 4, failed: 1, not_run: 1}`

### Requirement: Show one verify run
`GET /api/v1/projects/:project/verify-runs/:run_id` SHALL return `id`, `run_id`, `status`, `inserted_at`, `document`, and `artifacts` with `id`, `expired`, and, for an `sk_` key on a `final` run whose artifact is not expired, `download_url` and `download_url_expires_at`. A missing run, a run of another project, or a non-canonical `run_id` MUST get `404`.

#### Scenario: Download an artifact
- **WHEN** a client with an `sk_` key shows a final run and GETs an artifact's `download_url`
- **THEN** the object store returns bytes whose SHA-256 equals the declared `sha256`

#### Scenario: Expired artifact
- **WHEN** an artifact's object was deleted by retention
- **THEN** the artifact has `expired` true and no `download_url`, and `document` is unchanged

### Requirement: When a run counts for a change request
A run SHALL count for change request C at head H when it is `final`, `source.dirty` is false, `merge_result` is absent or null, its `scenario_set` is C's current intent version (approved, unless `require_approved_intent` is false) or current diff version, and `source.commit` is H or appears in H's `git-facts.commits` with every later commit's changed files matching `evidence.ignore_paths`.

#### Scenario: Run on the head
- **WHEN** a final clean run grades the current approved intent digest at commit H, the head of change request 42
- **THEN** the run counts for change request 42

#### Scenario: Docs-only commit after the run
- **WHEN** a run graded commit A, the head H is A's child, H changes only `docs/usage.md`, and `ignore_paths` is `["docs/**", "**/*.md"]`
- **THEN** the run counts at head H

#### Scenario: Code commit after the run
- **WHEN** a run graded commit A and the next commit B, before head H, changes `app/lib/good_flows/caches.ex`
- **THEN** the run does not count at head H

#### Scenario: Commit not in the facts
- **WHEN** a run graded a commit that is not in H's `git-facts.commits`, such as a commit from before a rebase
- **THEN** the run does not count

#### Scenario: Stale set digest
- **WHEN** a run graded intent digest `d1` and the current intent version has digest `d2`
- **THEN** the run does not count, even if `d1` was approved

#### Scenario: Merge-result run
- **WHEN** a final clean run has `merge_result` set and grades the head and the current approved digest
- **THEN** the run does not count for scenario results

### Requirement: The newest counted run decides each result
For each scenario of a graded set, the result SHALL be taken from the counted run with the newest `finished_at`, ties broken by `run_id` descending. Each change request SHALL record which runs it counted, for retention.

#### Scenario: Retry after a failure
- **WHEN** run R1 (finished 10:00) has `S1` `failed` and run R2 (finished 10:30) has `S1` `passed`, and both count
- **THEN** the verdict uses `passed` for `S1`

#### Scenario: Newer run did not run a scenario
- **WHEN** R1 has `S2` `passed` and the newer R2 has `S2` `not_run`
- **THEN** the verdict uses `not_run` for `S2`

### Requirement: Artifact retention
A sweep SHALL delete a final run's artifact objects 30 days after every change request that counted the run is `merged` or `closed`, and 14 days after the run became `final` when no change request counted it. Artifact rows MUST stay with `expired` true. Run documents MUST be kept. Failed deletions MUST be retried by later sweeps.

#### Scenario: Merged change request
- **WHEN** change request 42 counted run R and was merged 31 days ago, and no other change request counted R
- **THEN** the sweep deletes R's artifact objects and marks them `expired`, and R's document is still shown

#### Scenario: Two change requests
- **WHEN** run R was counted by change request 42, merged 40 days ago, and by change request 43, still `open`
- **THEN** the sweep keeps R's artifacts

#### Scenario: Uncounted run
- **WHEN** a final run was counted by no change request and became final 15 days ago
- **THEN** the sweep deletes its artifact objects

#### Scenario: Reopened change request
- **WHEN** change request 42 counted run R, was closed 20 days ago, and was reopened
- **THEN** the sweep keeps R's artifacts while change request 42 is not `merged` or `closed`

### Requirement: Public keys do not see run details
For a `pk_` key, each `results` entry MUST have `reason` and `failed_step` null, each `features` entry `entry_point` null, `source.changed_files` MUST be null, `links.threads`, when present, MUST be null, and no artifact MUST carry a download URL. Scenario IDs, results and counts MUST be as stored. A field absent from the document MUST NOT be added. The stored run MUST NOT change.

#### Scenario: Public key shows a run
- **WHEN** a client with a `pk_` key shows a run with a failed result whose `reason` is set
- **THEN** that result has `reason` null and `failed_step` null, its `id` and `result` are as stored, and a later `sk_` show returns the `reason`

#### Scenario: Public key and features
- **WHEN** a client with a `pk_` key shows a run with feature `{id: "checkout", entry_point: "/checkout", result: "passed"}`
- **THEN** that entry has `id` `checkout`, `result` `passed` and `entry_point` null

#### Scenario: Public key and artifacts
- **WHEN** a client with a `pk_` key shows a final run with unexpired artifacts
- **THEN** no artifact has a `download_url`

#### Scenario: Run without links
- **WHEN** a client with a `pk_` key shows a run without `links`
- **THEN** `data.document` has no `links` key

### Requirement: Verify run routes are in the OpenAPI document
Every verify run route SHALL be described in the OpenAPI document with its request body, responses and status codes.

#### Scenario: OpenAPI lists the routes
- **WHEN** a client fetches the OpenAPI document
- **THEN** it describes upload, commit, list and show under `/api/v1/projects/{project}/verify-runs`
