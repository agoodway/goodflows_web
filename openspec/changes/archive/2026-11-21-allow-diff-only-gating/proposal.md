# Proposal

## Why

A project that never uses OpenSpec has only diff scenario sets, and the review policy offers it no workable gate. With `scenarios.require_approved_intent` false, a change request with no scenario set passes. With it true, every diff-only change request gets a `diff_only_set` review item on every head, and a docs-only push after the diff set holds the verdict `pending` on `diff_set_revision`. Such projects need the diff set to be the whole scenario gate, with a person involved only when the agent weakens the set it is graded against.

## What Changes

- Add the policy setting `scenarios.diff_only`: `needs_review` (default; today's `diff_only_set` reason on every head), `weakening`, or `ignore`. It applies only when `scenarios.require_approved_intent` is true and the change request has a diff set and no intent set.
- Under `weakening`, compare the current diff version with its **baseline**: the newest diff version a person accepted, or version 1 when none was. Each Must scenario removed, or demoted to Should or Could, adds one `diff_set_weakened` reason (`needs_review`) with subject `["diff", <id>]`. Normal pushes that keep every Must add no reason. Edited Must sections are not weakening; they are shown as information on the item.
- `diff_set_weakened` applies only to change requests with no linked OpenSpec change; a linked one still waits on its intent set.
- Answering `approve` on every `diff_set_weakened` item of the current diff version (answers count only while the diff digest they were given on is current) records an `approve` decision on its digest, which makes that version the baseline, so the same weakening does not come back on the next push. Answering `reject` records a `reject` decision with the note and creates a task. Diff decisions are made only through review answers; the direct `…/scenario-sets/diff/approvals` and `…/rejections` routes stay `404`. The answer follows `scenarios.approver`.
- Diff versions report `accepted` (their digest's latest decision is `approve`); `approved` stays false for every diff version.
- Under `ignore`, a diff-only change request needs no person for being diff-only.
- **Revision fix**: a diff version also names the head when its `revision` names an earlier commit in the head's `git-facts.commits` and every later commit changes only paths matching `evidence.ignore_paths`, the same rule verify runs already follow. A docs-only push no longer holds the verdict `pending` on `diff_set_revision`.
- This reverses part of the grading design, which said "Diff sets are never approved: they only add ways to fail." Diff sets still take no approval before code, but a person can now accept a weakened diff set.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `review-policy`: the `scenarios` section gains `diff_only`, validated and reported as active.
- `change-requests`: the `diff_only_set` rule follows `scenarios.diff_only`; a new `diff_set_weakened` rule; the revision check accepts an earlier commit followed only by ignored paths.
- `change-request-review`: a `diff_set_weakened` item kind with its data, allowed answers, who may answer, and the decision its answers record.
- `qa-scenario-sets`: diff digests take decisions through review answers, and diff versions report `accepted`.
- `project-events`: `scenario_set_approved` and `scenario_set_rejected` gain `source`, so a diff acceptance can be told from an intent approval.

## Impact

- `GoodFlows.ReviewPolicies.Document` (new key, default, validation, active settings) and the review policy OpenAPI schema.
- `GoodFlows.ChangeRequests.Grading` and `Rules` (baseline lookup, weakening comparison, revision check), and `GoodFlows.Review` items, packet data and answers.
- `GoodFlows.ScenarioSets` decisions accept diff digests from the answer path, and decision events carry `source`. No migration for decisions, since `scenario_set_decisions` already stores a digest per change request with no source column or version foreign key. Review answers need the diff digest they were given on (design D3).
- Existing policies keep today's behavior because the default is `needs_review`. No CLI change.
