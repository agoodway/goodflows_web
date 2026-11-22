---
paths:
  - "app/lib/good_flows/verify_runs.ex"
  - "app/lib/good_flows/verify_runs/**"
  - "app/lib/good_flows_web/controllers/api/v1/verify_run_*.ex"
  - "app/lib/good_flows_web/schemas/verify_run_*.ex"
  - "app/test/good_flows/verify_runs*.exs"
  - "app/test/good_flows/verify_runs/**"
  - "app/test/good_flows_web/controllers/api/v1/verify_run_controller_test.exs"
  - "app/test/good_flows_web/verify_run_hygiene_test.exs"
---

# Verify runs API

An agent uploads the folder a verify skill wrote after driving a scenario set, with `goodflows cr runs upload`. The server stores it under the project as a `verify-run/1` document, counts it for every change request whose head is the run's commit, and puts its scenario results into that change request's verdict. A run names a set the server already stores, carries one result per scenario of that set, and is stored once: an upload of the same folder again stores nothing new.

## Sub-features

- `runs-upload` stores a run folder with no evidence files as a final run and prints the verdict it changed.
- `runs-counted` adds the run's results to the verdict of the change request whose head is the run's commit, with `counted runs: 1`.
- `runs-upload-again` reports `final (already stored)` for a second upload of the same folder.
- `runs-unknown-set` refuses a run whose `scenarios.md` is not a stored set with 422 on `scenario_set.digest`.
- `runs-artifacts` returns 503 for a run with evidence files when the server has no object storage.
- `runs-list` lists the project's runs at `/api/v1/projects/<slug>/verify-runs`.

## How to get to it (user POV)

- Run `goodflows cr runs upload <run folder>` from the branch's checkout, then `goodflows cr verdict`.
- Read runs with `GET $GF_URL/api/v1/projects/<slug>/verify-runs` and `…/verify-runs/<run_id>`, or in Swagger UI at `$GF_URL/api/v1/docs`.

## Driving it with control-goodflows

Preconditions:

- Everything [Change requests API](./change-requests-api.md) sets up, through its **Scenario set** step: an open or draft change request whose diff set is uploaded at HEAD, and `$GF` with `GOODFLOWS_URL` and `GOODFLOWS_API_KEY` exported.
- A run folder in the scratch checkout, `R=.verify/hello/<UTC yyyymmddThhmmssZ>-<short sha>`, holding `scenarios.md` (the uploaded set, copied byte for byte) and a `run.md` that opens with `verify-run-notes/1` front matter: `set.path` and `set.sha256` of `scenarios.md`, `commit` set to HEAD, `dirty: false`, one `results` entry per scenario with `evidence: []`, and one `features` entry. `$GF cr validate $R` prints `ok`. `.verify/` and `.goodflows/` stay untracked, so `git status --porcelain` lists only them.

- **Upload.** Run `$GF cr runs upload $R`. It prints `Verify run <run_id>: final  passed 1, failed 0, not run 0; 0 artifacts`, then the change request's verdict with the `diff set v1` line showing the passes and `counted runs: 1`. `scenario_results_missing` is gone.
- **Upload again.** Run the same command. It prints `final (already stored)` with the same `run_id`.
- **List.** Run `$C api verify-runs GET /api/v1/projects/verify-cr/verify-runs`. It returns 200 with one run whose `source.commit` is HEAD and `source.dirty` is `false`.
- **Unknown set.** Copy `$R` to a second folder, append a line to its `scenarios.md`, and run `$GF cr validate` on it: it fails with `set.sha256 is …, but scenarios.md has SHA-256 …`. Update `set.sha256` to the new digest and upload it: `cr runs upload failed: request rejected (HTTP 422): {"errors":{"scenario_set.digest":["must be the digest of a stored scenario set"]}}`. Delete the copy.
- **Artifacts.** List one file of the folder under a result's `evidence` and upload: `server error (HTTP 503): {"errors":{"detail":"Artifacts need object storage, which is not configured"}}`. Report this as unreachable, with that response, unless the run configured object storage.
- **Proof.** Keep the output of each upload, the `api/verify-runs.*` files, and the run folders under `$GF_RUN_DIR/cr/checkout/.verify/`.

## Gotchas

- Launch configures no object storage, so a run with evidence files cannot be uploaded and stays `verified-unreachable`. Keep evidence in the folder for the person reading it, and upload a copy whose results list `evidence: []`.
- The set digest is the SHA-256 of the folder's `scenarios.md`, so the copy must match the uploaded set byte for byte. `control-goodflows launch --scenarios <file>` makes that copy for runs of GoodFlows Web itself.
- The server stores a run whose `dirty` is `true` but never counts it, and it counts a run only for a change request whose head is the run's `commit`. A new commit needs a new run.
- `cr runs upload` finds the change request of the current branch. Pass `-n <number>` from another branch.
