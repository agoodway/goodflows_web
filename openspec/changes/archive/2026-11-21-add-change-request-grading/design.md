# Design

## Context

See proposal.md for motivation. Builds on `add-change-request-core`, which defines the verdict, its precedence (`pending > blocked > needs_review > mergeable`), `git-facts/1` and `review-policy/1`. The policy already accepts the `scenarios`, `evidence.ignore_paths` and `coverage` settings; this phase makes them take effect.

Scenario sets come from two goodstack skills: `gs-openspec-qa-scenarios` (intent, from an OpenSpec change's specs) and `gs-qa-scenarios` (diff). Both write `qa-scenarios/2` YAML front matter: shared `format`, `source`, optional `review`, and `scenarios` of `{id, name, priority}` (intent scenarios may add `covers`); intent sets add `change`, `specs` and `coverage`, diff sets add `branch`, `base`, `revision` and `regressions`. Only `qa-scenarios/2` is accepted. Grading is done by an agent running `gs-qa-scenarios` run mode through the project's `verify-<app>` skill, which writes `.verify/<app>/<run-id>/`. The CLI packages that folder; the server only sees uploads.

## Goals / Non-Goals

**Goals:**
- The approved bar cannot change without a new approval.
- A Must scenario with no result is impossible, not guessed at.
- Coverage is computed by the server from reviewed, versioned mappings, not reported per change.

**Non-Goals:**
- Proving that the CLI really drove the app, or who graded. That is the client's concern.
- Parsing the Markdown body of a scenario set.
- Carrying evidence across a rebase.

## Decisions

### D1. Digest over raw bytes; section digests for comparison

The set digest is SHA-256 of the uploaded file's bytes, so a formatting-only edit also needs approval. The CLI must never reformat a set. For version comparison the CLI sends, per scenario ID, a digest of that scenario's Markdown section; the server compares those and the front matter `priority` without parsing the body.

Alternative: digest only the front matter. Rejected, because steps and Expect lines live in the body and could change after approval.

Run results never go into a set. `gs-qa-scenarios` run mode writes results (`result`, `failed_step`, `evidence`, a scenario `reason`, a `run` block) into the set file, which would change the raw-bytes digest and lose the approval. So the server refuses a set carrying any of them with `422` on `content`, and the CLI uploads the set as written before any run; results reach the server only in a `verify-run/1` document.

Scenario IDs are YAML integers (`1`, `2`, ...) in the goodstack templates. The server accepts a positive integer or a string and stores and compares the string form, so `id: 1` matches a section digest or run result with `id` `"1"`.

### D2. Roles of the two set kinds

```
  CR 42
  +-- intent set   one per linked OpenSpec change, approved by digest
  +-- diff set     at most one, revision must name the head, never approved

  for each set:  Must failed or not_run   -> blocked
                 Should failed or not_run -> scenarios.should_failures
```

- With `require_approved_intent = true`: no intent set, or an unapproved current version, is `pending` with reason `scenario_set_approval`; a change request with no linked change and no diff set is `pending` with `scenario_set_missing`; a change request with only a diff set gets a `diff_only_set` reason (`needs_review`) on every head.
- With `false` (policy version 0): no scenario set is required, and a diff set's results are judged like any other set's, with no human step.
- Scenario reasons use `subject` `[<source>, <scenario id>]` because IDs are unique only within a set.
- A diff set's `revision` is the short SHA the template writes, or a full one: 7 to 64 hex characters that must be a prefix of the head. One that is not is `pending` until a new one is uploaded.

### D3. Approval and rejection

- Decisions (`approve` or `reject`, with a required note on `reject`) are stored per change request and digest. A digest is approved only when its latest decision is `approve`, so a rejection takes back an earlier approval until someone approves again. Phase 3's `reject` answer on a `scenario_set_approval` item records the same rejection.
- `approver = any`: any `sk_` key on the account. `other_member`: a membership other than the change request's author. `admin`: owner or admin. The setting applies to both decisions.
- Uploads and decisions are accepted only while the change request is `draft` or `open`; otherwise `409`, as for facts, claims and answers.
- A decision binds to the set digest, not the head, because the set is approved before code exists and the head moves on every push. This is the one exception to phase 3's rule that answers bind to the head.
- Channel is recorded (`cli` in v1) so a later `approve_via = "web"` setting can require the web UI.
- Before Git facts exist, the verdict still runs `scenario_set_approval` and `scenario_set_missing`, which read no facts. Every other grading rule waits for a head.

### D3a. Opening a change request before code (CLI contract)

The intent set is approved before code, and uploads need a `draft` or `open` change request whose `openspec_change` matches the set. `openspec_change` can be set only at create. So a change request implementing an OpenSpec change is opened right after its intent set is written, with no commit to describe and no claims file. This replaces the `cr open` and `cr claims` lines of core's D1 and D4, which the server implementation does not depend on:

```
  1  OpenSpec proposal              openspec/changes/<id>/
  2  gs-openspec-qa-scenarios       <change-dir>/qa-scenarios.md   (review: null)
  3  cr open --openspec-change <id> --title <t>   -> draft, verdict pending (git_facts_missing, scenario_set_approval [])
  4  cr scenarios upload            -> scenario_set_approval [<digest>]
  5  cr scenarios approve           -> pending (git_facts_missing) only
  6  implement, commit, cr push, gs-qa-scenarios run, cr runs upload
  7  gs-change-request --approved   -> cr open (finds the draft from step 3), reports facts, uploads claims, writes cr
  8  cr ready, review, merge
```

- `goodflows cr open [--claims <file>] [--openspec-change <id>] [--title <t>]` first lists the project's `draft` and `open` change requests with `source_branch` equal to the current branch. With exactly one, it uses it and creates nothing, so `gs-change-request --approved` with `cr: null` reaches the draft from step 3. With more than one, it fails and lists their numbers. With none, it creates a draft with `source_branch`, `openspec_change` and `title`. `--title` defaults to the claims file's `#` heading and is required when there is no claims file.
- When `--openspec-change` is given and the found change request links another change or none, `cr open` fails and names both, because no route changes the link.
- Only when the claims file exists does `cr open` also report Git facts for HEAD, upload the claims, and write the number into the file's `cr`. Without it, `cr open` prints the number.
- `goodflows cr claims <file>` reports Git facts for HEAD before uploading, as `cr open` does, because the server refuses claims for a head that was not reported. An identical report is a `200` no-op.
- `cr scenarios upload|approve|diff` and `cr runs upload` find the change request the same way, by the current branch, unless given a number.
- The intent set's `review` stays `null` after upload. Filling in the change request number changes the bytes and needs a new approval (D1).
- A chore with only a diff set needs none of this: its change request is opened at the end by `gs-change-request --approved`, and the diff set and runs are uploaded after.

### D4. Weakening changes first

Comparing version N with the last approved version, by scenario ID:

```
  ! removed (was Must)          weakening, listed first
  ! demoted Must -> Should|Could
  ~ changed section digest
  + added
```

Removing or demoting a Must is the legitimate way past a `blocked` verdict, so the reviewer must always see it.

### D5. `verify-run/1`

```yaml
format: verify-run/1
run_id: <uuid>
started_at: ...
finished_at: ...
source: { commit, branch, dirty, changed_files }
scenario_set: { digest, source: intent | diff }
merge_result: { base, commit } | null
results: [{ id, result: passed | failed | not_run, failed_step, reason, evidence: [artifact ids] }]
features: [{ id, entry_point, result }]
drift: ["..."]
artifacts: [{ id, path, content_type, size, sha256 }]
links: { threads, tickets }
workflow_run_id: <uuid> | null
```

- Owned by the project, not a change request, because agents grade before a change request exists. A change request counts runs by digest and commit, like workflow runs are keyed by commit.
- `results` must hold exactly the scenario IDs of the set with that digest; the set must already be stored on some change request of the project. Otherwise `422`.
- A dirty run is stored and never counts.
- Identity `(project, run_id)`; an equal digest is `200`, a different one `409`.

### D6. Artifacts reuse the cache upload path

```
  POST run (with manifest) -> run status uploading, presigned PUTs (size + sha256 signed)
  PUT each artifact
  POST commit              -> server HEADs each object, checks size and checksum
                           -> run status final, immutable
```

An `uploading` run expires after the cache reservation timeout and is deleted with its objects. Artifact limits: 200 per run, 50 MB each.

### D7. When a run counts

A final, clean run counts for change request C at head H when its digest is C's current approved intent set or current diff set, and either its commit is H, or its commit appears in H's `git-facts.commits` and every later commit's `changed_files` match `evidence.ignore_paths`. For each scenario, the newest counted run's result is used.

`merge_result` runs are excluded here and used only by phase 4.

### D8. Feature index and coverage

- `features sync` uploads `{ id, title, paths: [globs] }` for each feature file. Each sync is an immutable version; the newest is used.
- Coverage for head H, over the `git-facts` diff:
  - `unmapped_area`: a changed file matching no feature's globs -> `coverage.unmapped_areas`.
  - `undriven_feature`: a changed file maps to feature X, and no counted run lists X in `features` with `passed` -> `coverage.undriven_features`.
- Spec gaps: `coverage` rows with `no_check` in the intent set -> `scenarios.spec_gaps`, subject `[capability, requirement, scenario]`. Rows name the OpenSpec scenario as `{capability, requirement, scenario}`, the same shape as a `change-claims/2` `safe_because[].covers`. A row is closed, with no `spec_gap`, when the claims at the head have an entry covering it with `proof` at or above `claims.min_proof_level`; a covering entry below the minimum leaves the gap and also fires `proof_below_minimum`. Claims uploads already recompute the verdict.
- With no feature index synced, both coverage rules report one `pending` reason, `feature_index_missing`, unless both settings are `ignore` (as in policy version 0).

### D9. Retention and redaction

A sweep deletes artifact objects (rows stay with `expired: true`) 30 days after every change request that counted the run is `merged` or `closed`, and 14 days after finalization for runs no change request counted. Run documents are kept forever. `pk_` redaction mirrors workflow runs and phase 1: fields become null, and a field absent from the document is never added. Decisions show `note` and `decided_by.user_id` null. Scenario set reads show `content`, `front_matter` and `sections` null but keep `source`, `version`, `digest`, approval state and scenario IDs with priorities. The verdict's `coverage.unmapped_areas` (changed paths) and mapped feature IDs are null, like the `diff.files` of Git facts. Verify-run `features` keep `id` and `result` with `entry_point` null.

Commits (`source.commit`, `merge_result`) are 40 or 64 lowercase hex, as in `git-facts/1`. A diff set `revision` and an intent set `specs` are 7 to 64 lowercase hex (`specs` may also be `uncommitted`), because the skills write short SHAs.

## Risks / Trade-offs

- [Strict byte digest makes a whitespace edit need re-approval] -> Intended. The CLI never rewrites set files.
- [Feature globs drift as code moves] -> `unmapped_area` makes drift visible; `gs-maintain-verification-skill` keeps globs current.
- [Self-grading by the author's agent] -> Accepted; the approved intent set limits what a weak run can pass.
- [Artifacts can contain real data] -> `pk_` keys get no artifact URLs; retention bounds exposure.

## Migration Plan

New tables and routes. Ship after `add-change-request-core` and before the CLI's grading commands. Projects without object storage can store scenario sets and runs without artifacts.
