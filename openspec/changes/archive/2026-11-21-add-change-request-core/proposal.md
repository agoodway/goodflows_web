# Proposal

## Why

A pull request assumes code is expensive and that a person reads every line. Agents make code cheap, so human attention is now the scarce input. Goodflows will replace pull requests with change requests: records that carry a change's intent, evidence and risk, and a verdict that says whether a person needs to look at all. Change requests must work with any Git host, so the server never talks to one. It is a coordinator and datastore: clients report facts, the server applies the project's policy and holds the verdict, and clients act on it, including the merge.

This is phase 1 of 4. It adds change request records, the facts a client reports for each head, the review policy, and the verdict. Later phases add grading (`add-change-request-grading`), human review (`add-change-request-review`), and merge coordination with calibration (`add-change-request-merge`).

## What Changes

- Add change requests under `/api/v1/projects/:project/change-requests`. Each has a per-project number, a title, a source and target branch, the account membership that opened it, an optional linked OpenSpec change ID (at most one), and optional `links` (threads and tickets, the run-links shape).
- A change request moves through `draft`, `open`, `merged` and `closed`. It starts as `draft`. Any `sk_` key on the account may move it. `merged` is terminal and is set when a client reports the merge with the merged commit and target branch. The merge record keeps the verdict state, policy version and reasons at the head. A merge reported without a `mergeable` verdict is recorded and flagged, never rejected.
- `pk_` keys read change requests, facts, claims and verdicts with personal and content fields redacted. The phase 3 review packet and task routes are `sk_` only.
- Accept one immutable `git-facts/1` report per head and target branch: the head, target branch, merge base, the commits from merge base to head with their changed files, and the whole diff's file list with line counts. A different report for the same head and target branch is `409`. At most 1,000 commits and 10,000 files.
- Accept one `change-claims/2` document per head (any other format is rejected): a Markdown description in the gs-pull-request shape with YAML front matter for door, reach, `safe_because` facts with proof levels, optional evidence and the OpenSpec scenario each covers, open risks, questions and decision hunks. A `ran` proof must name evidence. It serves as the change request's description.
- Add a versioned `review-policy/1` document per project with fixed settings for claims, sensitive path globs, size limits and required workflows. Any `sk_` or `pk_` key reads it. Version 0, the default, turns off required workflows and the phase 2 checks. Only an `sk_` key whose membership is owner or admin writes a new version. Each version records who wrote it, when, and an optional note.
- Compute a verdict for the last reported head: `pending`, `blocked`, `needs_review` or `mergeable`, with one reason per rule that fired, the head, and the policy version. Recompute it whenever an input changes, including a new policy version. Required workflows use stored workflow runs on the head commit.
- Block project deletion while the project has change requests.
- Describe every route in the OpenAPI document.

Until `add-change-request-review` ships, a verdict that reaches `needs_review` cannot become `mergeable`, because answers do not exist yet.

## Capabilities

### New Capabilities

- `change-requests`: change request records, lifecycle, per-head Git facts and claims, and the verdict.
- `review-policy`: the versioned per-project policy document, who may read and write it, and how its settings map to verdict outcomes.

### Modified Capabilities

- `projects`: change requests block project deletion.

## Impact

- New tables and context modules for change requests, Git facts, claims, policy versions and verdicts. New API controllers and OpenAPI entries.
- Reads `workflow_runs` by `source_commit` for the required-workflows rule.
- Needs a companion goodflows CLI change: `cr open|ready|draft|close|reopen|status|path|push|claims|verdict`, and `policy get|set|history`. `goodflows cr open --claims <file>` opens a draft, reports Git facts, uploads claims and writes the new number into the file's `cr`; `goodflows cr claims <file>` updates claims. Both default `<file>` to the skill's `.goodflows/change-requests/<branch>/cr.md` (`.goodflows/change-requests/.detached/<short SHA>/cr.md` on a detached HEAD). This server owns the contracts and the CLI change cites them.
- The goodstack `gs-change-request` skill (branch `feat/change-request`, not yet committed) writes the claims file the CLI uploads.
- No Git host access, no repository mirror, and no merging on the server.
