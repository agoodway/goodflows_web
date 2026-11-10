# Design

## Context

The contract source is goodflows commit `4fa1da796a36135b9bcf219ba0db66c591884918` (the PR #20 merge). Cite that commit, not `main`: GOO-246 removes the goodflows `openspec/` directory.

- Allowlist: `src/reporting/run_contract.rs`, tables `DOCUMENT`, `SOURCE`, `CI`, `GRAPH`, `GRAPH_JOB`, `GRAPH_PARTITIONS`, `GRAPH_CONDITION`, `GRAPH_STEP` and `GRAPH_CALL`, and the checks in `validate`, `source`, `ci`, `graph` and `graph_consistency`.
- Rationale: `openspec/changes/upload-run-history/design.md`, sections D2 (key placement), D3 (`ci` sources and value rules), D4 (validation rules and bounds), "Server contract changes needed" and "Follow-up: upload envelope".
- Fixtures: `tests/fixtures/workflow-runs/` (`full.json`, `minimal.json`, `child.json`, `history-parent-default.json`, `history-child-suite.json`).

The server already validates the history document with `Shape` field tables in `GoodFlows.WorkflowRuns.Validator`, and generates the OpenAPI request schema from those tables. This change adds tables and does not change that approach.

## Goals / Non-Goals

**Goals:**
- Every record the CLI accepts locally is accepted here, and every record it rejects is rejected here, so a `422` means a contract change rather than a bug on either side.
- Store the envelope, and let the CLI's `history list --branch --event` filter on the server.

**Non-Goals:**
- Server-side analysis of the graph (critical path, joins from a call job to its child run). The graph is stored in `payload` only.
- CI providers other than GitHub Actions. `ci.provider` accepts only `github_actions`, matching the client.

## Decisions

### D1. Field tables mirror `run_contract.rs`

Each Rust table becomes one `Shape` object spec. Rust `Optional` is `{:omit, spec}` (absent, or a non-null value). Rust `Nullable` is `{:nullable, spec}` on a required key. The rules per key are the client's:

| Key | Rule |
|---|---|
| `source.branch` | optional, 1 to 256 UTF-8 bytes, no control characters (whitespace-only is allowed: it is a label, not a name) |
| `ci.provider` | required, `github_actions` |
| `ci.event`, `ci.runner` | optional, name rule |
| `ci.run_id` | optional, 1 to 256 bytes, no control characters |
| `ci.attempt`, `ci.pull_request` | optional, integers from 1 to 2^53-1 |
| `ci.url` | optional, at most 2,048 bytes, an absolute `https` URL with a nonempty host |
| `graph.jobs` | required, 1 to 1,024 entries |
| job `name`, `shell` | required: name rule, boolean |
| job `depends_on`, `steps` | required lists of at most 1,024 entries (names; step objects) |
| job `command` | nullable, text (at most 1,024 bytes) |
| job `partitions` | nullable `{count: 1..64, strategy: "index"}` |
| job `timeout_secs` | nullable, positive integer |
| job `condition`, step `condition` | nullable `{kind: "expression" \| "shell", text: text}` |
| job `call` | optional `{workflow: name, graph_sha256: 64 lowercase hex}`, exactly those two keys |
| step `id`, `command` | required: name rule, text |
| step `shell` | nullable boolean |

The server keeps its own error vocabulary and reports every error (up to 50) instead of the first. Paths have the same `graph.jobs[1].steps[0].id` shape as the client's.

`ci.url` uses Elixir's RFC 3986 `URI.new/1` where the client uses WHATWG `Url::parse`. The client builds the URL from the origin's ASCII serialization, an `owner/name` of `[A-Za-z0-9_.-]` segments, and a digit run id (`src/reporting/ci.rs`), so every URL it sends parses under both.

### D2. Graph consistency is a cross-field pass

Uniqueness, known dependencies, acyclicity and result coverage run after the structural pass, like pair and outcome checks, and merge into the 50-error cap in document order. They run only when `graph.jobs` is a list within bounds whose jobs all have a string `name` and a list of string `depends_on`, so a structural error is not reported twice. Errors:

- A repeated name: `must be unique` on `graph.jobs[i].name` (each repeat after the first).
- An unknown dependency: `must name a graph job` on `graph.jobs[i].depends_on[j]`.
- A cycle: `must not form a cycle` on `graph.jobs[i].depends_on`. The search is the client's depth-first search over jobs in order and dependencies in order, so `i` is the job whose dependency closes the first cycle found, the same job the client names. It runs only when names are unique and every dependency is known.
- A result whose `name` is not a graph job: `must name a graph job` on `results[i].name`.

Without `graph`, results are not cross-checked. A called workflow is never inlined: `call` allows only `workflow` and `graph_sha256`, so a nested `jobs` or `graph` is an unknown field. A fully inlined graph would also nest past depth 8. The deepest legal path is document › `graph` › `jobs` › job › `steps` › step › `condition` (7), so the existing depth limit needs no change.

### D3. Columns for branch and `ci`, and the filters

`source_branch` (`text`) and `ci` (`jsonb`) are copied out of the validated document like `source_commit` and `host`, so a list never reads `payload`. `graph` stays in `payload` only. It can be large and no list needs it.

- `branch` matches `source_branch` exactly and is validated with the `source.branch` rule (1 to 256 bytes, no control characters).
- `event` matches `ci->>'event'` exactly and is validated with the name rule.
- Runs without a branch or without `ci.event` never match those filters. Pull-request checkouts usually have no branch (goodflows design "Server contract changes needed" item 8), so `branch=main&event=push` selects push builds of `main`.

The new `workflow_runs_branch_list_index` on `(account_id, project_id, source_branch, started_at DESC, run_id DESC)` serves `branch` with the keyset order, like the commit index. `event` has a handful of values and stays unindexed, like `environment` and `outcome`, and is applied as a filter on whichever index the planner picks.

Summaries gain `ci` (the stored object, or null) and `source.branch` (only when stored).

### D4. Public keys do not see graph text

The goodflows design states that the server redacts command text for `pk_` reads, and its `history show` spec expects graph text to be absent for a public key. Show already nulls each result's `command` and `error`. It now also nulls each graph job's and step's `command` and each condition's `text`. Names, dependencies, partitions, `call` and condition `kind` stay visible. Because a step's `command` and a condition's `text` are non-null on upload, the show response's `document` uses a schema generated from the same tables with every `command` and `text` nullable.

### D5. Vendored fixtures

The five goodflows fixtures are copied byte for byte into `app/test/support/fixtures/goodflows_workflow_runs/`, with a README recording the source path, commit and digests. Tests read only these copies. Bumping the commit is an explicit contract change. A contract test uploads each one as the CLI would, retries it exactly, and round-trips `full.json`.

## Risks / Trade-offs

- [Contract drift] → The fixtures and this design cite one goodflows commit, and the validator's tests mirror `run_contract.rs`'s test cases. A new client field still returns `422`, which the CLI keeps pending.
- [Graph size] → A graph adds at most 1,024 jobs of bounded text, inside the existing 4 MiB body cap.
- [Event filter without an index] → Accepted for now. If event-only lists over large projects become common, add an expression index on `(account_id, project_id, (ci->>'event'), started_at DESC, run_id DESC)`.

## Migration Plan

One additive migration, with no backfill: earlier rows could not contain the envelope. Rollback drops the two columns and the index.
