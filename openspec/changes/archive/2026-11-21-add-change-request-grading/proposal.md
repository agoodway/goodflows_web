# Proposal

## Why

Phase 1 (`add-change-request-core`) gives change requests a verdict from Git facts, claims and workflow runs. It cannot yet say whether the change does what was intended. This phase adds the acceptance bar and the evidence against it: QA scenario sets, a person's approval of intent scenarios before code exists, verify runs that grade a commit against an approved set, and a feature index that shows which changed areas have verification and whether it ran. Approving about five scenarios up front is the cheapest human review in the flow, and it stops an author agent from writing the bar it is graded against.

Depends on `add-change-request-core`.

## What Changes

- Accept `qa-scenarios/2` scenario sets for a change request (any other format is rejected). The client uploads the raw Markdown file. The server parses only the YAML front matter (`format`, `source`, `review`, `scenarios` of `{id, name, priority}`, and the intent or diff keys the goodstack `gs-openspec-qa-scenarios` and `gs-qa-scenarios` skills write) and stores a digest of the raw bytes plus a digest per scenario section the client sends.
- A change request has at most one intent set (for its one linked OpenSpec change) and at most one diff set. A diff set must name the current head as its `revision` (a full SHA or a short prefix), or the verdict is `pending`. A set carrying run results is rejected: results belong in a verify run. Every version of each set is kept.
- Approve or reject an intent set's digest, only while the change request is `draft` or `open`. The policy's `scenarios.approver` decides who may: `any` (default), `other_member`, or `admin`. Each decision records the membership, key, digest, time, channel (`cli`) and, for a rejection, a note. A digest is approved when its latest decision is `approve`, and stays approved across pushes while the digest is unchanged. Any edit means a new digest and a new approval. Diff sets are never approved: they only add ways to fail.
- Show what changed between set versions by scenario ID, with weakening changes (a Must removed or demoted) first.
- Accept `verify-run/1` documents per project, independent of any change request. A run names its commit, branch, whether the tree was dirty, the scenario set digest it graded, a result for every scenario ID in that set, the features it drove, feature map drift, artifacts, links, and an optional merge-result base and workflow run ID. A run missing a scenario ID is `422`. An exact retry is idempotent.
- Upload artifacts (screenshots, transcripts) in two phases like cache entries: the run is stored as `uploading`, the server returns presigned PUT URLs with size and checksum signed in, and a commit call checks every object and makes the run final. Only final runs count.
- A run counts for a change request when it is final and clean, its digest is the current approved intent set's or the current diff set's, and its commit is the head or an earlier commit in the head's `git-facts` after which every commit changes only `evidence.ignore_paths`.
- Sync a per-project feature index from the verify skill's feature files, each with an ID and `paths` globs. Any `sk_` key may sync; each sync is a new version.
- Add verdict rules: approved intent set present, Must and Should results, spec gaps, diff-only sets, unmapped changed areas, and changed features no counted run drove. A spec gap (a `no_check` intent coverage row) is closed when a `change-claims/2` `safe_because` entry `covers` the same OpenSpec scenario with proof at or above `claims.min_proof_level`. Policy version 0 turns the approval, spec-gap and coverage checks off, so a project that never set them up is not held `pending`.
- Keep run documents forever. Delete artifacts 30 days after every change request that counted the run is merged or closed, or 14 days after upload for runs no change request counted.
- `pk_` keys see scenario IDs, priorities, results, counts and approval state, but not scenario set `content` or `sections`, `reason`, `failed_step`, `changed_files`, feature `entry_point`, coverage feature IDs or changed paths, thread links or artifact URLs.

## Capabilities

### New Capabilities

- `qa-scenario-sets`: scenario set intake, versions, approval and version comparison.
- `verify-runs`: the `verify-run/1` document, artifact upload, retention, and which runs count for a change request.
- `feature-index`: the synced per-project feature index and coverage of changed files.

### Modified Capabilities

- `change-requests`: the verdict gains scenario, evidence and coverage rules.
- `projects`: verify runs block project deletion; feature index versions are deleted with the project.

## Impact

- New tables for scenario set versions, approvals, verify runs, artifacts and feature index versions. Reuses the cache presigned-upload code and a sweep job like `GoodFlows.Caches.Sweep`.
- Needs object storage configured, as caches do.
- Companion CLI change to `cr open` and `cr claims`, replacing core's lines (design D3a): `cr open [--claims <file>] [--openspec-change <id>] [--title <t>]` reuses the one `draft` or `open` change request of the current branch, or creates a draft with the linked OpenSpec change, and reports Git facts and uploads claims only when the claims file exists, so a change request can be opened before code for intent set approval. `cr claims <file>` reports Git facts for HEAD before uploading claims.
- Companion CLI change: `cr scenarios upload|approve|diff`, `cr runs upload <.verify run folder>`, `features sync`. `cr scenarios upload` must upload the set file as written and must never reformat it; results go up only with `cr runs upload`. `gs-qa-scenarios` run mode never edits a set: it copies the set into the run folder as `scenarios.md` and writes results only to `run.md`. `cr runs upload` must compute `scenario_set.digest` as the SHA-256 of that folder's `scenarios.md`, not take it from `run.md`, which has a digest only for sets loaded from a file. A run of a set copied from a comment or chat counts only when those bytes equal the uploaded set; otherwise the upload gets `422`.
- The goodstack `gs-openspec-qa-scenarios` skill must write each intent coverage row with `capability`, `requirement` and `scenario`, the shape `gs-change-request` uses for `safe_because[].covers`.
- The goodstack verify skills need optional `paths` front matter in feature files, and `gs-maintain-verification-skill` should keep it current.
