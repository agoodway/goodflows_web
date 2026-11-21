# Design

## Context

See proposal.md for motivation. This is phase 1 of 4: `add-change-request-core`, `add-change-request-grading`, `add-change-request-review`, `add-change-request-merge`. Later phases add inputs to the same verdict, so this phase fixes the verdict's shape and the rule that combines outcomes.

What exists today and is reused:

- API keys belong to an account membership (`GoodFlows.Accounts.ApiKey` -> `AccountUser`), so every write traces to a user and a role. The Sprites credential controller already restricts writes to owners and admins with `AccountUser.admin?/1`.
- Workflow runs store `source_commit`, `outcome` and `workflow` as columns, so "required workflow passed on the head" is a query on existing data.
- Run `links` (threads and tickets) have a validated shape and indexed columns.
- Validators use `Shape` field tables, reject unknown keys, and never rewrite a submitted value. Retries compare a canonical JSON digest (`GoodFlows.JsonDocument.digest/1`).
- Lists use `GoodFlows.KeysetCursor`.

## Goals / Non-Goals

**Goals:**
- The server stores facts, applies policy and holds the verdict. Clients do everything else.
- Every verdict names the head, the policy version and one reason per rule that fired, so a client can tell whether it is still current and what to do next.
- Work with any Git host using only facts the client reports.

**Non-Goals:**
- Talking to a Git host, mirroring a repository, or merging. The server needs no host credentials.
- Enforcing who graded or who used a key. Trust in the client is the client's concern.
- A web UI. v1 review and approval go through the CLI and the API.
- Overriding a `blocked` verdict.

## Decisions

### D1. The server is a coordinator and datastore

```
  client / agent (goodflows CLI)                server
  ------------------------------                ------
  cr open --claims <file>       ---- create -->  change request (draft)
                                ---- report -->  git-facts/1 for head H
                                ---- upload -->  change-claims/2 for head H
  cr push (git push + facts)    ---- report -->  git-facts/1 for new head
  cr claims <file>              ---- upload -->  change-claims/2 for head H
                                                 verdict(H, policy vN)
  cr verdict                    <--- read -----
  merge on the host (client)
  report merged                 ---- report -->  merged
```

The alternative, a server that mirrors the repository and pushes merges, was rejected: it needs host credentials and per-host integration, and it contradicts "any Git host".

### D2. Lifecycle

```
                 ready
   +-------+ -----------> +------+  report merged   +--------+
   | draft |              | open | ---------------> | merged |  terminal
   +-------+ <----------- +------+                  +--------+
       |        draft         |
       | close                | close
       v                      v
   +--------+ <---------------+
   | closed | --- reopen ---> draft or open
   +--------+
```

- Every change request starts as `draft`. The verdict is computed in `draft` too, so agents get feedback early.
- Any `sk_` key on the account may change the state. Each change is stored with the membership, key and time.
- A merge report carries the merged commit and target branch (and, from phase 4, an optional `lease_id`). It is accepted from `draft` or `open` and stores the verdict's state, policy version and reasons at the reported head in `merge`, so calibration (phase 4) can read them later. If that state is not `mergeable`, the change request is flagged `merge.merged_without_mergeable_verdict`; phase 4 adds `merge.merged_without_lease` beside it. Recording rather than rejecting follows from D1: the merge already happened on the host.
- A merge the client never reports leaves the change request `open`. Detecting it is the client's job (for example a future `goodflows cr sync`).
- Numbers count up per project and are never reused. A `pk_` key may read, redacted; only `sk_` keys write. The phase 3 review packet and task routes are `sk_` only.
- `pk_` redaction: every `user_id` and `links.threads` null, `description` null, claims reads with `document` null and only `format`, `cr`, `head` and `door` in `front_matter`, Git facts reads with `changed_files` and `diff.files` null (the read's `totals` stay), and reasons with `subject` and `message` null. This matches the verify-run (phase 2) and event (phase 3) redaction: values become null, absent fields are never added, stored rows never change.

### D3. `git-facts/1`, one immutable report per head and target branch

```yaml
format: git-facts/1
head: <40-hex sha>
target: { branch: main, merge_base: <sha> }
commits:   # merge_base..head, oldest first
  - { sha, parents: [<sha>...], changed_files: [{ path, status, additions, deletions }] }
diff:      # merge_base..head as a whole
  files: [{ path, status, additions, deletions, old_path }]
```

- The client reports whenever the head or the base moves. The last reported head is the change request's head. The verdict is computed only for that head.
- Reports are identified by head and `target.branch`. A second report for the same pair with an equal digest is an idempotent `200`; a different one is `409`. The target branch is part of the identity because retargeting a stacked change request (`add-change-request-merge`) changes the merge base without changing the head.
- Limits: 1,000 commits and 10,000 diff files; more is `422`.
- `status` is one of `added`, `modified`, `deleted`, `renamed`, `copied`, `type_changed`. `old_path` is required only for `renamed` and `copied`.
- No patch-ID matching across rebases: a rebased commit sits on a different base, so the tested code is not the merged code.

### D4. `change-claims/2`, one per head

The goodstack `gs-change-request` skill writes the file; the CLI uploads it. The body is the gs-pull-request description (What changed, How it works, Evidence, What could break, How to check, Questions for the reviewer, Decisions to judge); the "Safe because:" line under What could break mirrors `safe_because`. The front matter, in key order:

```yaml
format: change-claims/2
cr: 42            # integer or null
head: <sha>
door: one_way     # one_way | two_way
door_reason: "..."
reach: "..."
safe_because:     # at least one; proof: stated < pointed < walked < ran
  - { fact, location, proof,
      evidence: [".verify/<app>/<run-id>/...", "run.md#<scenario id>", "<file>:<line>"],  # optional; required when proof is ran
      covers: { capability, requirement, scenario } }                                    # optional
left_open:  [{ risk, location, affected }]
questions:  [{ id, text, options, recommendation }]   # recommendation in options
decisions:  [{ id, path, hunk, note }]                # at most three
```

- The server accepts only `change-claims/2`; the earlier format is rejected with `422` on `format`. Nothing has shipped, so there is no compatibility path.
- The server checks: `head` equals the reported head, every `decisions[].path` appears in that head's `git-facts` diff, every `safe_because` entry has a valid `proof`, and an entry with `proof: ran` has nonempty `evidence`. Whether `location` names a real line, or an `evidence` path exists, is the client's concern.
- `covers` names an OpenSpec scenario in the same `{capability, requirement, scenario}` shape as an intent set's coverage rows, so phase 2 can let a proven claim close a spec gap.
- On the client the file lives at `.goodflows/change-requests/<branch>/cr.md`, with each `/` in the branch name a directory, or `.goodflows/change-requests/.detached/<short SHA>/cr.md` on a detached HEAD. The server never sees the path.
- CLI: `goodflows cr open --claims <file>` opens a draft change request, reports Git facts, uploads the claims, and writes the new number into the file's `cr`; `goodflows cr claims <file>` uploads claims for the current head. Both default `<file>` to the path above. Writing `cr` into the untracked file is intended.
- The server stores the raw file and parses only the front matter. Claims for an older head stay stored and are not used.
- Alternative considered: claims attached to the change request rather than the head. Rejected because answers (phase 3) bind to the head, and a claim describes the code at one head.

### D5. `review-policy/1`, fixed settings, versioned per project

```toml
[scenarios]                         # used from phase 2
require_approved_intent = true
should_failures = "needs_review"    # needs_review | ignore
spec_gaps = "ignore"
approver = "any"                    # any | other_member | admin

[evidence]
required_workflows = ["ci"]
ignore_paths = ["docs/**", "**/*.md"]   # used from phase 2

[claims]
one_way_door = "needs_review"
min_proof_level = "ran"
open_items = "needs_review"

[[paths]]
glob = "app/priv/repo/migrations/**"
outcome = "needs_review"

[size]
max_changed_files = 40
max_changed_lines = 1500

[coverage]                          # used from phase 2
unmapped_areas = "needs_review"
undriven_features = "blocked"

[merge]                             # used from phase 4
lease_ttl = "10m"
regrade_merge_result = true
```

- The CLI sends the document as JSON; the TOML above is the CLI's file form. The whole schema is accepted from phase 1 so a project writes one policy, and settings for later phases have no effect until their phase ships.
- A generic `{when, then}` rule language was rejected for v1: the inputs are a closed set, globs give the flexibility that matters, and fixed settings make reasons easy to explain. A rule list can come as `review-policy/2`.
- A project with no policy uses a documented default version 0. It differs from the example above: `evidence.required_workflows = []`, `scenarios.require_approved_intent = false`, and `scenarios.spec_gaps`, `coverage.unmapped_areas` and `coverage.undriven_features` all `"ignore"`, so a project that has set up no workflows, scenario sets or feature index is not held `pending` once phase 2 ships.
- `lease_ttl` is a string `<n>s`, `<n>m` or `<n>h` from `1m` to `1h`. `require_approved_intent` and `regrade_merge_result` are booleans. `paths` globs are distinct.
- `active_settings` grows by phase: phase 1 activates everything except `scenarios.*`, `evidence.ignore_paths`, `coverage.*` and `merge.*`; phase 2 adds `scenarios.*`, `evidence.ignore_paths` and `coverage.*`; phase 4 adds `merge.*`.
- Reads: any `sk_` or `pk_` key. Writes: `sk_` keys whose membership is owner or admin, like the Sprites credential. `ck_` keys: none. Each version stores the membership, key, time, previous version and an optional note. Versions are immutable.
- Policy lives on the server, not in the repository, so a change request cannot weaken the policy that judges it.

### D6. The verdict

```
  state          meaning                                    precedence
  pending        an input is missing at the head            1 (highest)
  blocked        an input fails                             2
  needs_review   rules fired that need a person             3
  mergeable      nothing else (or, from phase 3, every      4
                 needs_review reason cleared by an answer)

  verdict = highest-precedence outcome across all rules, with every reason
```

Phase 1 rules:

| Input | Rule | Outcome | Subject |
|---|---|---|---|
| no `git-facts` for head and target branch | `git_facts_missing` | `pending` | `[]`, or `[<head>]` after a retarget |
| no claims for head | `claims_missing` | `pending` | `[<head>]` |
| no clean run (or a cancelled newest run) on head for a required workflow | `required_workflow_missing` | `pending` | `[<workflow>]` |
| required workflow's newest run on head failed | `required_workflow_failed` | `blocked` | `[<workflow>]` |
| `door: one_way` | `one_way_door` | `claims.one_way_door` | `[]` |
| a `safe_because` proof below `min_proof_level` | `proof_below_minimum` | `needs_review` | the `fact`s |
| `left_open` or `questions` not empty | `open_items` | `claims.open_items` | each `risk` and question `id` |
| a diff path matches a `paths` glob | `path_match` (one per entry) | that entry's outcome | `[<glob>, <paths>...]` |
| diff over `max_changed_files` | `max_changed_files` | `needs_review` | `[]` |
| diff over `max_changed_lines` | `max_changed_lines` | `needs_review` | `[]` |

- `pending` outranks `blocked` because a verdict from incomplete facts would be wrong.
- Each reason has a stable `rule`, a `subject` (an array of strings, sorted unless the rule defines an order) and a message. `rule` plus `subject` is unique within a verdict. Phase 3 turns reasons into review packet items, keyed by rule and subject.
- The verdict is stored with the head, the policy version, the inputs' digests and a computed-at time. It is recomputed inside the transaction that changes an input: a facts report, a claims upload, a state change, a new policy version (every open and draft change request of the project), and a workflow run upload whose `source_commit` is the head of an open or draft change request.
- A client may act on a verdict only while its head and policy version are still current. The API returns both so the client can check.

### D7. Glob matching

Globs use `**` for any number of path segments, `*` within one segment, and `?` for one character, matched against the whole repository-relative path. They are compiled once per policy version. Both `path` and `old_path` of a renamed file are matched.

## Risks / Trade-offs

- [A buggy or dishonest client reports wrong facts or claims] -> Accepted by design. Every upload records the membership and key, and phase 4 calibration surfaces policies that let defects through.
- [The head moves and nobody reports it] -> The verdict goes stale. It names its head, so a careful client checks; `goodflows cr push` reports on every push.
- [A policy change recomputes many verdicts at once] -> Recompute only `draft` and `open` change requests, in a background job when there are more than a configured number.
- [Settings for later phases are accepted before they work] -> The API returns which settings are active in this server version.

## Migration Plan

New tables only, plus a new restriction on project deletion. Deploy before the CLI change. Rollback drops the new routes; the tables can stay.

## Open Questions

- None. Version 0 was decided above: the sketch with the phase 2 checks and required workflows turned off.
