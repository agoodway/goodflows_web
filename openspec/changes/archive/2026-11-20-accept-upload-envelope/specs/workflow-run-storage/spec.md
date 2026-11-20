## MODIFIED Requirements

### Requirement: The body is a run-history document
The body SHALL be one goodflows run-history JSON object with `schema_version` `1`. Its required keys are `schema_version`, `workflow`, `run_id`, `started_at`, `outcome`, `duration_ms`, `parallelism`, `graph_sha256`, `max_in_flight`, `host`, and `results`. Its optional keys are `environment`, `requested_jobs`, `source`, `parent_run_id`, `caller_job`, and the upload envelope keys `ci` and `graph`. The body MUST NOT carry a project or account: `project`, `account_id`, and any other key are unknown fields (`422`).

#### Scenario: Minimal document
- **WHEN** a client posts a document with only the required keys and an empty `results` array
- **THEN** the API responds `201`

#### Scenario: Unsupported schema version
- **WHEN** a client posts a document whose `schema_version` is `2`
- **THEN** the API responds `422` with an error on `schema_version` and stores nothing

#### Scenario: Body names the project
- **WHEN** a client posts a document containing a `project` key
- **THEN** the API responds `422` with `has an unknown field` on `body` and stores nothing

#### Scenario: Upload envelope
- **WHEN** a client posts a document with `source.branch`, `ci`, and `graph`
- **THEN** the API responds `201` and stores all three as given

### Requirement: Optional keys are omit-only
An optional key MUST be absent or a value. Null is invalid on every optional key, including `parent_run_id`, `caller_job`, a result's `workflow`, a result's `child_run_id`, `source.branch`, `ci`, every optional key inside `ci`, `graph`, and a graph job's `call`. A nullable key MUST be present and MAY be null. The nullable keys are a result's `command`, `exit_code`, and `error`, a graph job's `command`, `partitions`, `timeout_secs`, and `condition`, and a graph step's `shell` and `condition`. Omitting a nullable key is a missing required key (`422`). A null does not count as presence. A list summary may still be null for an absent `environment`, `source`, or `ci`.

#### Scenario: Null on a workflow-call optional
- **WHEN** a document sets `parent_run_id`, `caller_job`, a result's `workflow`, or a result's `child_run_id` to null
- **THEN** the API responds `422` with an error on that key and stores nothing

#### Scenario: Null on an envelope optional
- **WHEN** a document sets `source.branch`, `ci`, `graph`, or a graph job's `call` to null
- **THEN** the API responds `422` with an error on that key and stores nothing

#### Scenario: Missing nullable graph key
- **WHEN** a graph job omits `timeout_secs`
- **THEN** the API responds `422` with an error on `graph.jobs[<index>].timeout_secs`

#### Scenario: Null nullable graph keys
- **WHEN** a graph job has `command`, `partitions`, `timeout_secs`, and `condition` all null
- **THEN** the API responds `201`

### Requirement: Names follow one rule
Every workflow name (the document's `workflow`, a result's `workflow`, and a graph call's `workflow`), environment, requested job, `caller_job`, instance name, command-cost step, `ci.event`, `ci.runner`, graph job name, `depends_on` entry, and graph step id in a document MUST be a string of 1 to 64 UTF-8 bytes that contains no control characters and is not only whitespace. Names are case-sensitive and MUST be stored without normalization.

#### Scenario: Long instance name
- **WHEN** a result's `name` is 65 bytes long
- **THEN** the API responds `422` with an error on `results[<index>].name`

#### Scenario: Whitespace workflow
- **WHEN** a document's `workflow` is `"   "`
- **THEN** the API responds `422` with an error on `workflow`

#### Scenario: Long graph step id
- **WHEN** a graph step's `id` is 65 bytes long
- **THEN** the API responds `422` with an error on `graph.jobs[<index>].steps[<index>].id`

### Requirement: Host and source are structural only
`host` MUST contain `os` and `arch` (names), `logical_cpus` (a positive integer), and optionally `mem_total_bytes` and `mem_available_bytes` (nonnegative integers). `source`, when present, MUST contain `commit` (40 or 64 lowercase hex characters) and optionally `dirty` (a boolean) and `branch` (1 to 256 UTF-8 bytes with no control characters). Any other key in either object is an unknown field (`422`).

#### Scenario: Host without memory
- **WHEN** a document's `host` has only `os`, `arch`, and `logical_cpus`
- **THEN** the API responds `201`

#### Scenario: Branch in source
- **WHEN** a document's `source` has `branch` `feature/login`
- **THEN** the API responds `201` and stores the branch as given

#### Scenario: Branch too long or with a control character
- **WHEN** a document's `source.branch` is 257 bytes long, or contains a newline
- **THEN** the API responds `422` with an error on `source.branch`

### Requirement: Run summaries carry the comparison fields
Each summary SHALL include `id`, `run_id`, `workflow`, `environment` (null when absent), `outcome`, `started_at`, `duration_ms`, `parallelism`, `max_in_flight`, `graph_sha256`, `source`, `ci`, `host`, and `inserted_at`. `source` MUST be null when the document had no source. Otherwise it MUST be an object with `commit`, plus `dirty` and `branch` only when the document included each. `ci` MUST be the stored `ci` object, or null when the document had none. `host` MUST be the stored host object, with memory fields omitted when the document omitted them. Summaries MUST NOT include `results` or `graph`.

#### Scenario: Run outside a git checkout
- **WHEN** a stored run's document had no `source`, `environment`, or `ci`
- **THEN** its summary has `source` null, `environment` null, and `ci` null

#### Scenario: Commit without dirty
- **WHEN** a stored document's `source` is `{"commit": "<64 lowercase hex>"}` and has no `dirty` key
- **THEN** the summary `source` is that same object and has no `dirty` key

#### Scenario: Branch and CI context
- **WHEN** a stored document has `source.branch` `main` and `ci` `{"provider": "github_actions", "event": "push"}`
- **THEN** its summary `source` has `branch` `main` and its `ci` is that object

### Requirement: The list can be filtered
The list SHALL accept the exact-match filters `workflow`, `environment`, `outcome`, `commit` (matching `source.commit`), `branch` (matching `source.branch`), `event` (matching `ci.event`), and `graph_sha256`, combined with AND. A run without `source.branch` never matches `branch`, and a run without `ci.event` never matches `event`. A filter value that breaks its field's rule, an invalid `limit`, or an invalid `cursor` MUST return `422` on that parameter. Unknown query parameters SHALL be ignored.

#### Scenario: Same graph across commits
- **WHEN** a client lists with `workflow=ci&graph_sha256=<hex>`
- **THEN** only runs of workflow `ci` with that graph hash are returned

#### Scenario: Branch and event
- **WHEN** a client lists with `branch=main&event=push`
- **THEN** only runs whose `source.branch` is `main` and whose `ci.event` is `push` are returned

#### Scenario: Pull-request run without a branch
- **WHEN** a stored run has `ci.event` `pull_request` and no `source.branch`, and a client lists with `branch=main`
- **THEN** that run is not returned

#### Scenario: Invalid outcome filter
- **WHEN** a client lists with `outcome=green`
- **THEN** the API responds `422` with an error on `outcome`

#### Scenario: Unknown query parameter
- **WHEN** a client lists with `color=blue`
- **THEN** the API responds `200` and does not filter on `color`

#### Scenario: Invalid name filter
- **WHEN** a client lists with a `workflow` of 65 bytes, or an `environment` or `event` that is only whitespace
- **THEN** the API responds `422` with an error on that parameter

#### Scenario: Invalid branch filter
- **WHEN** a client lists with a `branch` of 257 bytes, an empty `branch`, or a `branch` containing a newline
- **THEN** the API responds `422` with an error on `branch`

### Requirement: Public keys do not see command text or errors
For a public (`pk_`) key, every `results` entry in `document` MUST have `command` and `error` set to null, and every `graph` job and step MUST have `command` set to null and any `condition` `text` set to null. Every other field, including job names, dependencies, partitions, `call`, and condition `kind`, MUST be as stored. Private keys MUST see the document as stored. The stored row MUST NOT change.

#### Scenario: Public key reads a run
- **WHEN** a client with a `pk_` key shows a run whose results have commands and errors
- **THEN** every result in `data.document` has `command` null and `error` null, every other field is as stored, and a later `sk_` show of that run still has the stored `command` and `error`

#### Scenario: Public key reads a graph
- **WHEN** a client with a `pk_` key shows a run whose graph has job and step commands and condition text
- **THEN** each graph job and step has `command` null, each condition has `text` null and its `kind` as stored, and a later `sk_` show returns the graph as stored

## ADDED Requirements

### Requirement: Uploads may carry CI context
`ci`, when present, MUST be an object with `provider` `github_actions`. It MAY contain `event` and `runner` (the name rule), `run_id` (1 to 256 UTF-8 bytes with no control characters), `attempt` and `pull_request` (integers from 1 to 2^53-1), and `url` (an absolute `https` URL with a host, at most 2,048 bytes). Any other key is an unknown field (`422`).

#### Scenario: Provider only
- **WHEN** a document's `ci` is `{"provider": "github_actions"}`
- **THEN** the API responds `201`

#### Scenario: Unsupported provider
- **WHEN** a document's `ci.provider` is `gitlab`
- **THEN** the API responds `422` with an error on `ci.provider`

#### Scenario: Plain HTTP run URL
- **WHEN** a document's `ci.url` is `http://ghe.local/a/b/actions/runs/1`
- **THEN** the API responds `422` with an error on `ci.url`

#### Scenario: Unknown CI key
- **WHEN** a document's `ci` contains a `token` key
- **THEN** the API responds `422` with `has an unknown field` on `ci`

### Requirement: Uploads may carry the job graph
`graph`, when present, MUST be an object with only `jobs`, a list of 1 to 1,024 jobs. Each job MUST contain `name`, `depends_on` (at most 1,024 names), `shell` (a boolean), `steps` (at most 1,024 steps), and the nullable keys `command` (text of at most 1,024 UTF-8 bytes), `partitions` (`{"count": n, "strategy": "index"}`, `1 <= n <= 64`), `timeout_secs` (a positive integer), and `condition`. It MAY contain `call`. Any other job key is an unknown field (`422`).

#### Scenario: Too many graph jobs
- **WHEN** a document's `graph.jobs` has 1,025 entries
- **THEN** the API responds `422` with an error on `graph.jobs`

#### Scenario: Empty graph
- **WHEN** a document's `graph.jobs` is `[]`
- **THEN** the API responds `422` with an error on `graph.jobs`

### Requirement: Graph steps and conditions are validated
Each graph step MUST contain `id`, `command` (text of at most 1,024 UTF-8 bytes), and the nullable keys `shell` (a boolean) and `condition`. A job or step condition MUST be `{"kind": "expression" | "shell", "text": <text of at most 1,024 UTF-8 bytes>}`. Any other key is an unknown field (`422`).

#### Scenario: Oversized graph text
- **WHEN** a graph step's `command` is 1,025 bytes long
- **THEN** the API responds `422` with an error on that step's `command`

#### Scenario: Unknown condition kind
- **WHEN** a graph job's `condition.kind` is `regex`
- **THEN** the API responds `422` with an error on that condition's `kind`

### Requirement: The graph is consistent
When `graph` is present, its job names MUST be unique, every `depends_on` entry MUST name a job in the graph, the dependencies MUST NOT form a cycle, and every result `name` MUST name a job in the graph. A cycle is reported on the job whose dependency closes the first cycle found in document order. Without `graph`, result names are not checked.

#### Scenario: Duplicate job name
- **WHEN** two graph jobs are both named `build`
- **THEN** the API responds `422` with an error on the second job's `name`

#### Scenario: Unknown dependency
- **WHEN** a graph job depends on `deploy` and no graph job is named `deploy`
- **THEN** the API responds `422` with an error on that `depends_on` entry

#### Scenario: Dependency cycle
- **WHEN** graph job `build` (index 0) depends on `test` and `test` (index 1) depends on `build`
- **THEN** the API responds `422` with an error on `graph.jobs[1].depends_on`

#### Scenario: Result outside the graph
- **WHEN** a result's `name` is `deploy` and no graph job is named `deploy`
- **THEN** the API responds `422` with an error on `results[<index>].name`

#### Scenario: No graph
- **WHEN** a document has no `graph` and a result named `deploy`
- **THEN** the API responds `201`

### Requirement: A called workflow is referenced by hash
A graph job that calls a workflow MAY contain `call`, an object with exactly `workflow` (the name rule) and `graph_sha256` (64 lowercase hex characters). The called workflow's jobs MUST NOT be inlined: any other key in `call` is an unknown field (`422`). The called workflow's graph arrives in the child run's own document, whose `graph_sha256` equals `call.graph_sha256`. The server MUST NOT require that child run to be stored.

#### Scenario: Call job
- **WHEN** a graph job has `command` null, `steps` `[]`, and `call` `{"workflow": "suite", "graph_sha256": "<64 lowercase hex>"}`
- **THEN** the API responds `201` and stores the call as given

#### Scenario: Inlined called workflow
- **WHEN** a graph job's `call` contains a `jobs` key
- **THEN** the API responds `422` with `has an unknown field` on that `call`

### Requirement: Uploads match the goodflows client contract
The server SHALL accept every fixture in goodflows `tests/fixtures/workflow-runs/` at commit `4fa1da796a36135b9bcf219ba0db66c591884918` (`full.json`, `minimal.json`, `child.json`, `history-parent-default.json`, `history-child-suite.json`). The tests MUST use copies vendored into this repository, not fetch them.

#### Scenario: Fixture upload and retry
- **WHEN** a client uploads one of those fixtures byte for byte, then uploads it again
- **THEN** the first response is `201` and the second is `200` with `duplicate` true and the same `id`

#### Scenario: Envelope round trip
- **WHEN** a client uploads `full.json` and shows it with an `sk_` key
- **THEN** `data.document` equals `full.json` as a JSON value, including `graph`, `ci`, and `source.branch`

## REMOVED Requirements

### Requirement: The upload envelope is out of scope
**Reason**: The CLI now uploads the envelope (goodflows PR #20), and this change accepts it. "The body is a run-history document", "Host and source are structural only", "Uploads may carry CI context", "Uploads may carry the job graph", "Graph steps and conditions are validated", "The graph is consistent", and "A called workflow is referenced by hash" define it.
**Migration**: None. Documents without the envelope validate exactly as before. Uploads the CLI spooled after a `422` replay successfully.
