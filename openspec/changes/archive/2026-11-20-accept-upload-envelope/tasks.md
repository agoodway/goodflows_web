# Tasks

## 1. Contract fixtures

- [x] 1.1 Vendor goodflows `tests/fixtures/workflow-runs/` (`full.json`, `minimal.json`, `child.json`, `history-parent-default.json`, `history-child-suite.json`) at `4fa1da796a36135b9bcf219ba0db66c591884918` into `app/test/support/fixtures/goodflows_workflow_runs/`, byte for byte, with a README that records the source path, commit and SHA-256 of each file (design D5). Tests never fetch them.

## 2. Validator

- [x] 2.1 Add the `source.branch`, `ci`, `graph`, graph job, partitions, condition, step and call tables to `GoodFlows.WorkflowRuns.Validator` (design D1), with optional keys as `{:omit, spec}` and nullable keys as `{:nullable, spec}`.
- [x] 2.2 Add the graph consistency pass (design D2): unique names, known dependencies, no cycle, and every result name a graph job.
- [x] 2.3 Validator tests mirror the `run_contract.rs` cases: each vendored fixture validates; null on every optional envelope key; each nullable graph key missing and null; `source.branch` at 256 and 257 bytes, with a control character and empty; every `ci` rule; 0, 1,024 and 1,025 graph jobs; 1,025 `depends_on` and `steps`; 1,025-byte graph text; partition count 0 and 65; strategy and condition kind; a duplicate name; an unknown dependency; a self cycle, a two-job and a three-job cycle; an unknown result name with and without `graph`; `call` with an uppercase or short hash, without `workflow`, and with inlined jobs; and no submitted value in any error.

## 3. Storage and reads

- [x] 3.1 Migration adding `source_branch` and `ci` to `workflow_runs` and `workflow_runs_branch_list_index` (design D3). Copy both columns in `ingest/4`.
- [x] 3.2 `list_runs/3`: validated `branch` and `event` filters. Summaries include `ci` and `source.branch`. Verify the planner serves `branch` from the new index.
- [x] 3.3 Show: null graph job and step `command` and condition `text` for public keys (design D4).

## 4. API and documentation

- [x] 4.1 OpenAPI: the generated request schema includes the envelope, the summary includes `ci`, the list documents `branch` and `event`, the show `document` schema allows the redacted nulls, and the API description is updated.
- [x] 4.2 Contract test: each vendored fixture uploads with `201` and an exact retry is `200`; `full.json` round-trips `graph`, `ci` and `source.branch` on show and list; invalid envelope values are `422` on their path.
- [x] 4.3 Controller tests: `branch` and `event` alone and combined, a branch with `/`, case sensitivity, runs without branch or `ci`, invalid `branch` and `event` values, and graph redaction for a `pk_` key.
- [x] 4.4 `openspec validate accept-upload-envelope --strict` and `mix precommit` pass.
