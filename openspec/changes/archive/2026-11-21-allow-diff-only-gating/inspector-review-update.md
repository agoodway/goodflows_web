# Inspector Review-Update — allow-diff-only-gating

**Reviewed:** 2026-11-21
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Ready to implement

## Summary

The change lets projects without OpenSpec gate on diff scenario sets alone. It adds `scenarios.diff_only`, a baseline for diff sets, a `diff_set_weakened` review item that accepts a diff digest, and a revision check that tolerates docs-only pushes. Both specialists found the same critical hole: answers to `diff_set_weakened` items carried over to a new diff version at the same head, so an approval given on one version could accept another. That is now fixed by superseding those answers on diff upload. The rest were canonical requirements the delta contradicted without modifying, plus wrong test paths and missing tasks. All are patched.

**Original counts:** Critical: 1 · Warning: 10 · Suggestion: 12
**Patches:** Auto-patched: 18 · User-guided: 0 · Model-recommended: 5 · Skipped: 0

## Scope inspected

- Proposal: `openspec/changes/allow-diff-only-gating/proposal.md`
- Design: `openspec/changes/allow-diff-only-gating/design.md`
- Tasks: `openspec/changes/allow-diff-only-gating/tasks.md`
- Deltas:
  - `openspec/changes/allow-diff-only-gating/specs/review-policy/spec.md`
  - `openspec/changes/allow-diff-only-gating/specs/change-requests/spec.md`
  - `openspec/changes/allow-diff-only-gating/specs/change-request-review/spec.md`
  - `openspec/changes/allow-diff-only-gating/specs/qa-scenario-sets/spec.md`
  - `openspec/changes/allow-diff-only-gating/specs/project-events/spec.md` (new in this pass)
- Canonical specs consulted:
  - `openspec/specs/{review-policy,change-requests,change-request-review,qa-scenario-sets,verify-runs,project-events}/spec.md`
  - `openspec/changes/archive/2026-11-21-add-change-request-grading/design.md` (D2, D3)
- Other active changes consulted: none

## Patches applied

18 findings were auto-patched. 0 were patched after user guidance. 5 were patched from model recommendations. 0 were skipped.

### Auto-patched

1. **Canonical "Approve or reject an intent set digest" still said diff sets take no decisions** — `specs/qa-scenario-sets/spec.md` → added a MODIFIED copy with all four scenarios; the last sentence now says diff digests take decisions only through `diff_set_weakened` answers.
2. **Canonical "An approval binds to the digest, not the head" covered intent only** — `specs/qa-scenario-sets/spec.md` → MODIFIED to cover intent and diff versions; added the scenario "Push after diff acceptance".
3. **Canonical "Answers resolve needs_review" requires reasons to stay after clearing** — `specs/change-requests/spec.md` → MODIFIED with an exception for `diff_set_weakened` (accepting moves the baseline, so the reasons go away); added the scenario "Accepted weakening leaves the verdict".
4. **Revision rule ambiguous for a short SHA matching both H and an earlier commit** — `specs/change-requests/spec.md:30,57` → the prefix-of-head rule now applies first (today's behavior kept), with the ignored-paths rule as a fallback; the ambiguous scenario now names two earlier commits.
5. **"up to the current one" in the baseline rule adds nothing** — `specs/change-requests/spec.md`, `design.md` D2 → removed.
6. **`edited_musts` definition vague** — `specs/change-request-review/spec.md:27`, `design.md` D2 → defined as scenarios that are `must` in both versions with a different section digest.
7. **The decision's membership and key were unspecified** — `specs/change-request-review/spec.md` → the decision records the completing answer's membership and key; added the scenario "Decision records the completing answer".
8. **"One of two" scenario did not show partial clearing** — `specs/change-request-review/spec.md` → THEN now asserts `review` `{"items": 2, "cleared": 1}`.
9. **No coverage of repeated diff decisions** — `specs/change-request-review/spec.md` → added the scenario "Reject twice with the same note"; tested in task 4.2.
10. **`record_decision/4` rejects any digest other than the current intent digest** (`app/lib/good_flows/scenario_sets.ex:330`) — `design.md` D3, task 4.2 → it gains a `source`.
11. **Order inside the answer transaction unspecified** (`app/lib/good_flows/review.ex:190-217`) — `design.md` D3 → store the answer, check the stored verdict's items, record the decision, then recompute once under the row lock.
12. **The upload response would lack `accepted`** (`scenario_set_controller.ex:112`) — task 4.5 → covers upload, list and version reads.
13. **No task required the OpenAPI enums to list the new rule and kind** — tasks 3.3 and 4.1 → added `openapi_test.exs` checks.
14. **Wrong test files** — tasks 2.1 and 3.2 → the unit cases now go in `grading_rules_test.exs`, where the `names_head?`, `counts?` and rule-table tests live; `grading_test.exs` keeps the DB-backed counted-run case.
15. **`names_head?` has no facts or ignore globs** (`grading.ex:88,102`) — `design.md` D4, task 2.1 → `Grading.set` takes `commits` and ignore globs and reuses `Grading.counts?`; the design notes this also lets diff runs count.
16. **Baseline digest and weakening must enter through `Grading`** (`rules.ex:621` is pure) — task 3.3 → `Grading` adds `accepted`, `baseline` and the weakened entries; `digests/1` adds `diff_baseline_digest`.
17. **`approved_digests/1` will return diff digests** (`scenario_sets.ex:197`) — `design.md` D3, task 3.1 → noted that this is safe (the source is in the hashed bytes, and `approved?/2` guards on source), and the docs get updated.
18. **Archive-edit follow-up; v3 needs its own run** — `tasks.md` → removed the follow-up that edited the archived design (the reversal is recorded in this change); task 5.1 records a passing run on v3's digest.

### Model-recommended patches

1. **Answers carried across diff versions at the same head** (Critical) — `specs/change-request-review/spec.md`, `design.md` D3, task 4.3
   - **Chose:** a new requirement, "Weakened diff set answers bind to the diff digest": answers count only while the digest current when they were given is still current. Implemented by superseding every `diff_set_weakened` answer in the transaction that stores a diff version. Two scenarios added.
   - **Rationale:** the item subject `["diff", id]` and head binding stay as they are, and the existing `superseded_at` mechanism avoids a column on `review_answers` and a migration. Putting the digest in the subject would have broken the stable-ID convention.
2. **"Acceptance taken back" cannot be reached through the API** — `specs/change-requests/spec.md`, `design.md`
   - **Chose:** reworded it as a stored-data precondition ("Latest decision decides"), added "Revoking a diff acceptance" as a non-goal, and replaced the matching risk bullet.
   - **Rationale:** this keeps one meaning for decisions across sources without inventing a revoke route the user never asked for.
3. **Decision events cannot tell intent from diff** — new `specs/project-events/spec.md`, `proposal.md`, task 4.4
   - **Chose:** add `source` to the `scenario_set_approved` and `scenario_set_rejected` data, with a MODIFIED copy of "Each event type carries its change" and two diff scenarios.
   - **Rationale:** the field is additive and matches `scenario_set_uploaded`, which already carries `source` (`scenario_sets.ex:119`).
4. **Weakening on a linked change request without an intent set** — `specs/change-requests/spec.md`, `proposal.md`, `design.md` D3
   - **Chose:** `diff_set_weakened` requires no linked OpenSpec change; added the scenario "Linked change without an intent set".
   - **Rationale:** the user scoped this change to projects that never use OpenSpec. A linked change request must still wait for its intent set.
5. **Rollback note was inaccurate** — `design.md` Migration Plan
   - **Chose:** state that old servers read stored `diff_only` and ignore it, refuse writes containing it, and need `ChangeRequests.recompute_project/1` afterwards.
   - **Rationale:** verified that `effective/1` keeps unknown keys (`review_policies/document.ex:98`) and that the old item builder drops unknown kinds (`review/items.ex:84-86`).

### Skipped

_None._

## Critical

_None._

## Warning

_None._

## Suggestion

_None._

## Alignment notes

- **Other active changes:** none.
- **Canonical specs:** the contradictions with qa-scenario-sets ("Diff sets take no decisions", intent-only digest binding), change-requests (reasons stay after clearing) and project-events (intent-only decision events) are now covered by MODIFIED blocks. `openspec validate` passes. It warns about four over-length requirements, all existing blocks copied whole into MODIFIED as the OpenSpec rules require.
- **Codebase assumptions verified:** every module and test file named exists; `scenario_set_decisions` has no source column, foreign key or unique constraint, so it needs no migration; the diff decision routes already return `404`; `ScenarioSets.changes/2`, `Grading.counts?/4` and `ChangeRequests.recompute_project/1` exist; `check_approver/2` is already on the answer path.

## What looks good

- One outcome setting whose default keeps every written policy's behavior.
- A baseline instead of the previous version, which closes the "demote, then keep it demoted" loophole, and renamed Musts count as removed.
- `accepted` kept separate from `approved`, so intent-approval meaning is unchanged everywhere.
- The revision fix reuses the verify-run counting rule instead of inventing a second one.
