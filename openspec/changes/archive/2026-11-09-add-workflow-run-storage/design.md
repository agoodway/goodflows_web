# Design

## Context

See proposal.md for motivation and specs/workflow-run-storage/spec.md for the behavior contract.

The server already has a complete ingestion path for test reports. This change reuses that machinery for a second document type and doesn't re-derive it. What exists today:

- `GoodFlowsWeb.Plugs.BodyParsers` skips `Plug.Parsers` for raw-body routes, matching on path only. `GoodFlowsWeb.SentryScrubber` and `RequireParsedBody` use the same predicate.
- `GoodFlowsWeb.Plugs.TestReportBody` checks Content-Type, Content-Encoding (via `GoodFlowsWeb.RawBodyHeaders`) and declared length. It then takes an admission slot, reads in 1 MiB chunks against one deadline, scans depth and decodes with `objects: :ordered_objects`.
- `GoodFlows.TestReports.Document` provides `check_depth/1` (fixed depth 16), `decode/1`, `normalize/1`, `digest/1` (SHA-256 of canonical JSON) and `render_path/1`.
- `GoodFlows.TestReports` does an atomic `insert_all(on_conflict: :nothing)` followed by an account-scoped digest compare in SQL. It classifies transient errors (SQLSTATE 08/40/53/57, `55P03`, `25006`), handles the project foreign key race, and turns other database errors into a fixed-message `StorageError`.
- Spry run listing uses keyset pagination with a base64url `"<timestamp>|<id>"` cursor and `limit` 1..200 (default 50). Run show redacts per key type with `ApiKey.can_write?/1`.

The document format comes from goodci `src/history.rs` (`Record`, `Instance`, `Host`, `RecordSource`) and `src/runner.rs` (`Status`, `Scheduling`, `CommandCost`, `CommandKind`). The top-level list key is `results`. `schema_version` stays 1 after workflow-call jobs: `Record` gained optional `parent_run_id` and `caller_job`, and `Instance` gained optional `workflow` and `child_run_id`, with no version bump (goodflows `999f80e`). `partition` is `{index, count}`, with `index` starting at 1 and `count` at most `MAX_PARTITIONS` = 64. `command` and `error` are null or are cut to 1,024 bytes. `exit_code` is null or an `i32`. Workflow, caller-job, job, and step names all pass goodci's `validate_name` (non-blank, at most 64 bytes, no control characters). Two golden files from goodflows 0.6.0 live in `fixtures/` (goodflows PR #10 commit `88c5c33`) and must validate unchanged.

## Goals / Non-Goals

**Goals:**
- One immutable row per `(account, project, run_id)` holding the document exactly as validated, plus a few columns copied out of it for filtering and summaries.
- Behave the same as test-report ingestion for authentication, body handling, error shapes and idempotency, so the goodci publisher can share its retry and replay code.
- List and show reads that are cheap enough for the CLI to page through a workflow's history.

**Non-Goals:**
- Normalized per-instance or per-command tables, aggregates, or comparison logic on the server.
- Admission caps and a heap limit for this route (see Risks).
- Changing test-report behavior. The shared helpers this change extracts must keep test-report responses byte-for-byte unchanged. Test reports already accept `test-timings/1` (PR #5).
- The CLI upload envelope. goodflows adds top-level `graph` and `ci`, and optional `source.branch`, only on the uploaded copy. Local history omits them, and so do the golden files. Accepting those keys is a follow-up. This change keeps rejecting them as unknown fields.
- Columns or list filters for `parent_run_id`, `caller_job`, a result's `workflow`, or `child_run_id`. They stay inside `payload`.

## Decisions

### D1. This repo owns the wire contract, and it mirrors `schema_version` 1 exactly

The spec's validation rules are the history `Record` allowlist at `schema_version` 1, written out in full, including the workflow-call fields goodflows added without a version bump: top-level `parent_run_id` (lowercase canonical UUID) and `caller_job` (the name rule), present together or not at all, and result `workflow` (the call target, the name rule) and `child_run_id` (lowercase canonical UUID). `child_run_id` is allowed only when that result's `workflow` is present. Thomas approved keeping `schema_version` 1 and widening this allowlist so both golden files validate. A version bump would reject documents the CLI already writes. Server-side bounds stay as before: names follow the 64-byte rule, `requested_jobs` and `commands` are capped at 1,024 entries, partitions are capped at 64, and integers at 2^53-1. The server accepts only `schema_version` 1. When goodci bumps the history version, it must update this contract first, and older servers keep rejecting the new version with `422`, which the CLI treats as a pending upload to keep. The `outcome` consistency check repeats goodci's own derivation (`failed` exactly when some result is `failed`/`timed_out`; `cancelled` allowed without a cancelled result because of the signal snapshot). A local history document the CLI considers valid therefore can't be rejected by the server for a reason the CLI can't predict. The upload-only keys (`graph`, `ci`, `source.branch`) are not part of that local record and stay unknown fields until the follow-up.

*Alternative considered:* an upload envelope (`{"format": "goodflows-history", "document": {...}}`). It was rejected because the CLI reads the document back and parses it with the same code it uses for local files. An envelope adds a layer with no field to put in it: project and account already come from the path and the key.

*Alternative considered:* permissive validation that stores unknown keys. It was rejected because history excludes stdout, stderr and env values by allowlist, and a server that accepted extra keys would quietly accept a future CLI bug that leaks output.

### D2. One table, a few copied columns, JSONB for everything else

Add a `workflow_runs` table (`GoodFlows.WorkflowRuns.Run`):

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | server id |
| `account_id` | uuid | `references(:accounts, on_delete: :delete_all)` |
| `project_id` | uuid | composite FK `(project_id, account_id)` -> `projects (id, account_id)`, `ON DELETE NO ACTION`, named `workflow_runs_project_id_fkey` |
| `api_key_id` | uuid null | `references(:api_keys, on_delete: :nilify_all)`, records which key uploaded it |
| `run_id` | uuid | from the document |
| `workflow` | text | |
| `environment` | text null | |
| `outcome` | text | |
| `started_at` | utc_datetime | second precision, as in the document |
| `duration_ms` | bigint | |
| `parallelism`, `max_in_flight` | bigint | the spec allows integers up to 2^53-1; a PostgreSQL `integer` overflows at 2^31-1 (SQLSTATE 22003), which is not transient and would become a 500 |
| `graph_sha256` | text | |
| `source_commit` | text null | |
| `source_dirty` | boolean null | |
| `host` | jsonb | copied out so a list never reads `payload` |
| `payload` | jsonb | the validated document |
| `payload_digest` | bytea | canonical-JSON SHA-256 (D3) |
| `inserted_at` | utc_datetime_usec | no `updated_at` |

Indexes:
- unique `(account_id, project_id, run_id)`, which is also the conflict target
- `(account_id, project_id, started_at DESC, run_id DESC)` for the default list
- `(account_id, project_id, workflow, started_at DESC, run_id DESC)` for a workflow's history. The graph index below cannot serve `workflow` alone, because `graph_sha256` sits between `workflow` and `started_at`
- `(account_id, project_id, workflow, graph_sha256, started_at DESC, run_id DESC)` for `workflow` plus `graph_sha256`
- `(account_id, project_id, source_commit, started_at DESC, run_id DESC)` for a commit page in list order
- `api_key_id`, for the nilify on key delete

`environment` and `outcome` stay unindexed. A filter on only those columns scans that project's runs. Do not copy `parent_run_id`, `caller_job`, a result's `workflow`, or `child_run_id` into columns, and do not add list filters for them. They stay in `payload` and come back on show inside `document`. List summaries do not gain those keys. There is no foreign key from a child run to its parent: either document may arrive alone.

The composite FK has the same shape as `test_reports` and `recipes`, so an account delete that cascades to both projects and runs succeeds in any order. Add `has_many :workflow_runs` on `Project`, `no_assoc_constraint(:workflow_runs, name: :workflow_runs_project_id_fkey)` in `Project.delete_changeset/1`, and a `{:error, :has_workflow_runs}` branch in `Projects.delete_project/2`. `FallbackController` renders it as a fixed-detail `409`. The projects delta renames the current requirement "Recipes and test reports protect a project from deletion". Pools were removed in PR #8, so the delta does not mention them.

The run and its test reports are linked only by `test_reports.workflow_run_id = workflow_runs.run_id` within the same `(account_id, project_id)`. There's no foreign key either way: reports usually arrive before the run (they are published as jobs finish), and either side may never arrive. The show query reuses the existing `(account_id, project_id, workflow_run_id, job, report_id)` unique index and MUST `ORDER BY job, report_id`. The index can serve that sort. Postgres does not promise index order without `ORDER BY`.

*Alternative considered:* normalizing `results` into rows. It was deferred because the CLI does the comparison and needs the whole document anyway, and normalizing would commit us to query shapes nobody has asked for.

### D3. Idempotency copies test reports, through extracted helpers

Extract the JSON-document helpers that don't depend on report format out of `GoodFlows.TestReports.Document` into `GoodFlows.JsonDocument`: `check_depth/2` (with the depth limit as an argument), `decode/1`, `normalize/1`, `digest/1`, `render_path/1` and `max_integer/0`. `TestReports.Document` delegates to it with depth 16, so test-report behavior doesn't change.

Extract the Postgres error classification into `GoodFlows.StorageErrors`: the `DBConnection.ConnectionError` rescue, `transient?/1`, foreign-key-constraint matching, and the fixed-message re-raise. `TestReports` and `WorkflowRuns` both call it, each passing its own project-FK name and its own `StorageError` module.

`WorkflowRuns.ingest/4` does the following:
1. Run `insert_all(Run, [row], on_conflict: :nothing, conflict_target: [:account_id, :project_id, :run_id], returning: [:id])` with `log: false`.
2. If no row came back, select `{id, payload_digest == ^digest}` scoped to `(account_id, project_id, run_id)`. `TestReports.compare/1` filters the full identity (`test_reports.ex`). Scoping only to the account and project makes `Repo.one/2` raise once a second run exists, and an exact retry becomes a 500.
3. Return `201`, `200` (`duplicate: true`) or `409`.

Both queries take a `timeout:` from `:workflow_run_db_timeout_ms` (default 15,000). Failure handling, in this order:
- Rescue `DBConnection.ConnectionError` (a dropped connection has no SQLSTATE) to `{:error, :workflow_run_storage_unavailable}`, rendered as `503` with `Retry-After`. `TestReports.persist/1` already does this.
- A violation of `workflow_runs_project_id_fkey` (the project was deleted after `LoadProject`) returns `404`.
- Any other FK violation, or a transient SQLSTATE (classes 08/40/53/57, `55P03`, `25006`), returns `{:error, :workflow_run_storage_unavailable}` (`503` with `Retry-After`).
- Any other error is logged with only its SQLSTATE and constraint name and re-raised as `GoodFlows.WorkflowRuns.StorageError` (`500`).

### D4. Body handling: method-aware raw route and a lighter body plug

`POST` and `GET` share the path `/api/v1/projects/:project/workflow-runs`. `raw_body_route?(%Plug.Conn{})` today ignores the method and delegates to the path list (`body_parsers.ex`). `SentryScrubber` and `RequireParsedBody` both pass the conn, not a path list. A path-list match on `workflow-runs` would make a `GET` skip `Plug.Parsers`, leave `query_params` unfetched, and drop list filters and cursors.

Add a conn clause, defined before that delegation, that matches only `%Plug.Conn{method: "POST", path_info: ["api", "v1", "projects", _, "workflow-runs"]}`. The path-list form MUST return false for this route. Do not implement the POST match by making the path form return true. `RequireParsedBody` then skips its 415 only for that POST, and `SentryScrubber` sends no body only for that POST. A `GET` is parsed normally.

A route-local `GoodFlowsWeb.Plugs.WorkflowRunBody` runs after `LoadProject`. It:
1. Checks Content-Type (`application/json`, optionally `charset=utf-8`; otherwise `415`).
2. Checks Content-Encoding and declared Content-Length through `RawBodyHeaders` (`415`/`413`).
3. Reads in chunks of at most 1 MiB against one monotonic deadline (`:workflow_run_read_timeout_ms`, default 30,000, returns `408`), returning `413` as soon as the bytes read pass `:workflow_run_max_body_bytes` (default 4,194,304).
4. Runs `JsonDocument.check_depth(body, 8)`, then `JsonDocument.decode/1`. Malformed JSON is `400`. `decode/1` only returns `:malformed_json` (`document.ex`). On success, call `normalize/1`: duplicate keys, NUL characters, and integers above 2^53-1 are `422`. Non-integer numbers pass `normalize/1` (`document.ex`); the validator rejects them on integer fields.
5. Stores the normalized term in `conn.private`. The controller never reads `conn.params` for the body.

The body read and decode loop is shared with `TestReportBody` by extracting it into a function both plugs call. That covers chunking, the deadline and the overflow tag handling. Only `TestReportBody` wraps it in admission and a heap limit.

Configuration follows the test-report pattern: values are read at call time and set in `config/runtime.exs` from `WORKFLOW_RUN_MAX_BODY_BYTES`, `WORKFLOW_RUN_READ_TIMEOUT_MS` and `WORKFLOW_RUN_DB_TIMEOUT_MS` (documented in `.env.sample`), except in test (`config/test.exs`).

### D5. Validator

`GoodFlows.WorkflowRuns.Validator` follows the approach of `TestReports.Validator`: a declarative field table per object (top level, `host`, `source`, result, `partition`, command), with errors collected as `{path, message}` in document order, cut to 50 and rendered through `JsonDocument.render_path/1`. Messages come from the same fixed list (`can't be blank`, `is invalid`, `has an unknown field`, `has a duplicate key`, `is too long`, …), so no submitted value is ever interpolated. The cross-field `outcome` check runs only when every result's `status` is valid, so one bad status doesn't produce a second, misleading `outcome` error.

`TestReports.Shape`'s `{:object, fields}` requires every key (`shape.ex`), and `TestReportParts.to_schema/2` puts every key in OpenAPI `required`. goodci omits optional keys instead of sending null: `environment`, empty `requested_jobs`, `source`, `parent_run_id`, `caller_job`, host memory, `dirty`, `partition`, result `workflow`, `child_run_id`, empty `commands`, `step`, CPU times, and `peak_rss_bytes` (`history.rs`, `runner.rs`). Add a backward-compatible object form: required keys must be present, and an optional key may be absent. Null is invalid for an optional key. Do not model absence as `{:nullable, spec}`. The explicit exception is the required result trio `command`, `exit_code`, and `error`: each must be present, and each may be null. All three are null on a workflow-call result. Model only that trio as nullable. A missing pair (`parent_run_id` without `caller_job`, or the reverse), a `child_run_id` without `workflow`, and null on an omit-only key are `is invalid` on that key. The workflow OpenAPI schema lists only the required keys in `required`, and marks only that trio `nullable`. `{:list, spec, max: n}` allows an empty list, so `requested_jobs` and `commands` also need a minimum of 1. `Shape.string_error/2` accepts a whitespace-only name when `:min` is 1; the name rule also rejects a string whose trim is empty. The name rule covers the document `workflow`, a result's `workflow`, `environment`, requested jobs, `caller_job`, instance names, and step ids. Existing test-report specs use none of these new forms, so test-report validation stays unchanged.

`exit_code` is null or a signed integer from -2147483648 through 2147483647 (goodci `Option<i32>`). `Shape`'s `{:int, nil}` accepts any integer through ±(2^53-1), so this bound is its own check.

The validator returns the document plus the values to copy into columns (D2). `started_at` is parsed by an exact `YYYY-MM-DDTHH:MM:SSZ` match before `DateTime.from_iso8601/1`, so offsets and fractional seconds are rejected rather than normalized.

### D6. Reads

Routes:
- `GET /workflow-runs` and `GET /workflow-runs/:run_id` go on the project read scope (`[:api, :api_authenticated, :load_project]`).
- `POST /workflow-runs` goes on the project write scope (`[:api, :api_authenticated, :api_write, :load_project]`) with `WorkflowRunBody` as a controller-level plug for `:create`.

`WorkflowRuns.list_runs(account, project, params)` validates `limit`, `cursor` and the filters with a schemaless changeset, the same way `Spry.page_params/1` does (`page_params/1` is private). Filter rules are those of the matching field: the name rule, the outcome enum, `commit` as 40/64 lowercase hex, `graph_sha256` as 64 lowercase hex. It orders by `started_at DESC, run_id DESC`, uses the cursor `base64url("<started_at iso8601>|<run_id>")`, fetches `limit + 1` rows, and selects only the copied columns, never `payload`. Summary `source` is null when `source_commit` is null. Otherwise it is `%{"commit" => source_commit}` plus `"dirty" => source_dirty` only when `source_dirty` is not null. `host` is the stored jsonb object, so omitted memory fields stay omitted.

`WorkflowRuns.get_run(account, project, run_id)` returns `404` unless `run_id` matches the validator's lowercase canonical UUID. Do not downcase the path and look it up. `Ecto.UUID.cast/1` is the wrong check: `Spry.get_run/2` uses it and accepts uppercase (`spry.ex`). It then loads the row and its test-report summaries in two queries, with the report query ordered as in D2.

Redaction happens in `WorkflowRunJSON` from `ApiKey.can_write?(conn.assigns.current_api_key)`: for public keys, each `results[*]` has `command` and `error` replaced with `nil` before rendering. The stored row is never touched.

### D7. OpenAPI and hygiene

Add the schemas `WorkflowRunRequest` (generated from the validator's field tables, as the test-report request schema is), `WorkflowRunAcknowledgement`, `WorkflowRunSummary`, `WorkflowRunListResponse` and `WorkflowRunResponse`. Responses:
- `POST`: 200, 201, 400, 401, 403, 404, 406, 408, 409, 413, 415, 422, 503
- `GET`: 200, 401, 404, 406, 422

`406` is the `:api` pipeline rejecting an `Accept` that does not allow JSON, before the body is read (`router.ex`). This route has no admission cap and does not return `429`. D8 still treats a proxy `429` as retryable.

Insert and compare queries run with `log: false`. Do not add parameter filters: the body is never parsed into params. Controller tests assert that a sentinel string in `command` and `error` never shows up in logs, error bodies, or `pk_` show responses.

### D8. goodci companion contract (`upload-run-history`)

The companion change in goodci owns:
- A `[reporting]` setting (for example `history = true`) that builds the same `Record` in memory and uploads it whether or not local history is enabled. The record isn't sent when no reporting block exists.
- Pre-upload validation against the rules in D1, so a CLI-side bug never reaches the server. D1 is the local history document. The companion's upload-only keys (`graph`, `ci`, `source.branch`) are not in D1. Sending them before the follow-up returns `422`, and the CLI keeps that upload pending.
- A frozen spool snapshot alongside the test-report snapshots, replayed by `goodflows reports upload <run-directory>` with its original `run_id`.
- Treating `201`/`200` as done, `409` as a permanent conflict that is reported and not retried, and `408`/`429`/`5xx`/transport errors as retryable within the existing 30-second publishing budget.
- Read commands `goodflows history list` and `goodflows history show <run_id>` against D6.

`goodflows history compare` is deferred.

## Risks / Trade-offs

- [No admission caps on this route] -> Bodies are capped at 4 MiB (8x smaller than test reports) and the read deadline bounds slow clients. Peak memory per upload is a few times the body size. Revisit if uploads ever approach the test-report scale or come from untrusted publishers.
- [Command text can contain inline secrets] -> goodci records configured commands verbatim. Mitigations: `pk_` reads null them out, insert queries skip logging, and Sentry body scrubbing covers the route. The server can't detect secrets, so this stays the publisher's responsibility, as it is for local history files.
- [Contract drift between goodci and the server] -> One `schema_version`, strict validation, and D8's pre-upload validation. Version 1 is widened in place for the workflow-call fields, because that is what the CLI writes. The upload envelope (`graph`, `ci`, `source.branch`) stays a follow-up, so those keys remain unknown fields until that change. Test reports already accept `test-timings/1` (PR #5); this change does not touch that contract.
- [The `run_id` is chosen by the client] -> Identity is scoped to account and project and requires an `sk_` key, so a key can only collide with its own account's runs, and a collision is a `409`, never an overwrite.
- [Unbounded growth] -> Accepted for this version, as with test reports: no retention or quota. History documents are small (goodci's default local cap is 10 MiB across 1,000 runs).
- [The method-aware raw-route predicate] -> The `Plug.Conn` form and the path-list form now differ for this one route. Document this on `raw_body_route?/1`, and cover both forms in the `BodyParsers` tests.

## Migration Plan

1. Deploy the server (one new migration, `create_workflow_runs`, and the extracted helpers) before enabling uploads in goodci.
2. Rollback: remove the routes and leave the table in place. Drop it only when accepting the loss of stored runs.
3. The migration doesn't touch existing tables, so it is safe to roll forward and back independently of goodci.
