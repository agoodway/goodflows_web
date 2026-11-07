# Proposal

## Why

The `goodflows` CLI (goodci) records each workflow run as an immutable run-history document: outcome, scheduling, and CPU and memory per command. Today that document only exists on the machine that ran it, and the history is off by default. On CI the machine is temporary, so the runs worth comparing across commits are lost. Test reports already reach the server with a `workflow_run_id`, but there is no stored run for that id to refer to. The archived `store-test-timings` design left that parent record out on purpose. This change adds it, so the CLI can upload runs and read them back.

## What Changes

- Add a private-key-authenticated `POST /api/v1/projects/:project/workflow-runs` endpoint that accepts one goodflows run-history document (`schema_version` 1) as the body. The path slug selects the project, the account comes from the key, and the body carries neither.
- Validate the document against a strict allowlist that mirrors goodci's history record. Unknown fields, unknown schema versions, duplicate keys, NUL characters, and bodies over the size, depth or instance limits are rejected, so the CLI keeps its snapshot and retries.
- Store each run once under `(account, project, run_id)`. An exact retry returns `200` with the same server identity, and a different document under the same identity returns `409`, including under concurrency.
- Add `GET /api/v1/projects/:project/workflow-runs`, which lists run summaries newest `started_at` first with keyset pagination. It filters by `workflow`, `environment`, `outcome`, `commit`, and `graph_sha256`.
- Add `GET /api/v1/projects/:project/workflow-runs/:run_id`, which returns the stored document as uploaded plus summaries of the test reports stored under the same `workflow_run_id`. Public (`pk_`) keys get each instance's `command` and `error` as null.
- Block deleting a project that has stored workflow runs (`409`), as for recipes, test reports and pools.
- Not included: aggregation or comparison across runs on the server, a dashboard UI, retention, quotas, and updates or deletes of stored runs. The CLI-side `goodflows history compare` command is deferred to a later change.

## Capabilities

### New Capabilities

- `workflow-run-storage`: authenticated upload, validation, immutable and idempotent storage, and project-scoped listing and retrieval of goodflows run-history documents.

### Modified Capabilities

- `projects`: deletion protection now also covers stored workflow runs.

## Impact

- New `GoodFlows.WorkflowRuns` context with a `Run` schema backed by a new `workflow_runs` table (one migration). It has a composite `(project_id, account_id)` foreign key with `ON DELETE NO ACTION`, the same shape as `test_reports` and `recipes`.
- New `WorkflowRunController`, JSON views and OpenAPI schemas, plus routes on the existing project-scoped read and write pipelines.
- `GoodFlowsWeb.Plugs.BodyParsers` must leave `POST .../workflow-runs` unread so authentication runs first, while the `GET` list on the same path keeps its parsed query string. The route-local body reading reuses `GoodFlowsWeb.RawBodyHeaders`.
- `Project` gets `has_many :workflow_runs` and a `no_assoc_constraint`. `Projects.delete_project/2` and `FallbackController` get a `:has_workflow_runs` case.
- Test reports are unchanged. The show endpoint reads `test_reports` by `(account_id, project_id, workflow_run_id)` and doesn't add a foreign key.
- Companion change in goodci (`upload-run-history`): a `[reporting]` setting that uploads the run whether or not local history is enabled, a spool snapshot that `goodflows reports upload` replays, and `goodflows history list` / `show` against the read endpoints. This change owns the wire contract.
- Separate issue: the server still accepts only `format: "exunit-timings"` for test reports, while goodci v0.6.0 sends `test-timings/1`. Fix that in its own change. It is not a prerequisite here.
