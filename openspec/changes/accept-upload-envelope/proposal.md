# Proposal

## Why

The `goodflows` CLI now uploads run history (goodflows PR #20, `upload-run-history`). Each upload is the local history document plus three envelope fields: an optional `source.branch`, an optional top-level `ci`, and an optional top-level `graph`. `add-workflow-run-storage` left that envelope for a follow-up, so the server rejects every such upload with `422`, and the CLI spools and replays them. The CLI's `history list` also sends `--branch` and `--event` filters, which the list endpoint ignores today. This change accepts and stores the envelope, adds those two filters, and pins the contract to the CLI's fixtures (GOO-247).

## What Changes

- Accept `source.branch`, `ci` and `graph` on `POST /api/v1/projects/:project/workflow-runs`, validated exactly as the client allowlist in goodflows `src/reporting/run_contract.rs` at `4fa1da796a36135b9bcf219ba0db66c591884918`: the `SOURCE`, `CI`, `GRAPH`, `GRAPH_JOB`, `GRAPH_PARTITIONS`, `GRAPH_CONDITION`, `GRAPH_STEP` and `GRAPH_CALL` tables. Optional keys may be absent but are never null. Nullable keys are always present and may be null.
- When `graph` is present, enforce 1 to 1,024 jobs, unique job names, known dependencies, no dependency cycle, and every result `name` naming a graph job. A called workflow is referenced by `call.graph_sha256` and never inlined. The existing nesting (8) and body (4,194,304 bytes) limits apply unchanged.
- Remove the requirement that rejects the envelope as unknown fields.
- Copy `source.branch` and `ci` into columns, return both on list summaries, and add exact-match `branch` and `event` (`ci.event`) filters to `GET /api/v1/projects/:project/workflow-runs`, with a keyset index for `branch`.
- Extend public-key redaction on show to graph command text: every graph job's and step's `command`, and every condition's `text`, are null for a `pk_` key.
- Vendor goodflows `tests/fixtures/workflow-runs/` at that commit as contract fixtures, and update the OpenAPI document.

`schema_version` stays 1. Exact retries are still `200`. A document without the envelope is valid exactly as before.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workflow-run-storage`: accepts the upload envelope, filters the list by branch and event, and redacts graph text for public keys.

## Impact

- `GoodFlows.WorkflowRuns.Validator`: new field tables for `source.branch`, `ci` and `graph`, and graph consistency checks. The OpenAPI request schema is generated from those tables.
- One migration: nullable `source_branch` (`text`) and `ci` (`jsonb`) on `workflow_runs`, plus `workflow_runs_branch_list_index`. Rows stored before it could not carry the envelope, so there is no backfill.
- `WorkflowRuns.list_runs/3`, `WorkflowRunController.index`, `WorkflowRunJSON` and the OpenAPI schemas.
- Test fixtures under `app/test/support/fixtures/goodflows_workflow_runs/`, with a README that records the source path and commit.
- Unblocks the GOO-245 end-to-end smoke test: spooled CLI uploads replay against this server.
