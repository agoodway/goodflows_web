# Inspector Review-Update — add-spry-api

**Reviewed:** 2026-11-01
**Reviewer:** inspector-review-update (structural/consistency and codebase/gaps specialists)
**Mode:** auto
**Verdict:** Ready to implement

## Summary

The change proposes account-scoped recipes, encrypted Sprites credentials, asynchronous lifecycle runs, and request-driven templates. Both specialists' findings were deduplicated and all 14 were patched in the change artifacts. The revised design bounds local execution and confirms ownership termination before releasing abandoned-run guards; it explicitly documents that remote commands may survive a disconnected client.

**Original counts:** Critical: 2 · Warning: 10 · Suggestion: 2
**Patches:** Auto-patched: 9 · User-guided: 0 · Model-recommended: 5 · Skipped: 0

## Scope inspected

- Proposal: `openspec/changes/add-spry-api/proposal.md`
- Design: `openspec/changes/add-spry-api/design.md`
- Tasks: `openspec/changes/add-spry-api/tasks.md`
- Deltas: `specs/spry-recipes/spec.md`, `specs/sprites-credential/spec.md`, `specs/spry-runs/spec.md`, and `specs/spry-templates/spec.md` under this change directory.
- Canonical specs consulted: none exist; `openspec/specs/` contains only `.gitkeep`.
- Other active changes consulted: none; no archived changes exist either.
- Local app code and installed `sprites`, `pgflow`, and Phoenix dependencies were inspected. No external documentation was needed.
- Git context: at pre-read the target was untracked and the root repository had no commits. During review, an initial commit (`7496fcd`) appeared; final status shows the remaining artifact edits and the new report. This review issued no git mutations.

## Patches applied

9 findings were auto-patched. 0 were patched after user guidance. 5 were patched from model recommendations. 0 were skipped. References below point to the updated artifacts; severities are the original finding severities.

### Auto-patched

1. **Context-aware template scanner (Warning)** — `openspec/changes/add-spry-api/design.md:66` → Aligned the design with task 2.1: `scan/2` receives the allowed-name context, including name overrides.

2. **Indexed rejection of every non-string step (Warning)** — `openspec/changes/add-spry-api/design.md:54` → Aligned raw validation with the recipe delta; added number, null, nested-list, and blank-string test coverage in task 3.2.

3. **Recipe deletion conflict rendering (Warning)** — `openspec/changes/add-spry-api/design.md:154` → Added `{:error, :active_run}` → `409` to the planned fallback and task 6.7.

4. **Immutable plans and retained history (Warning)** — `openspec/changes/add-spry-api/specs/spry-runs/spec.md:229` → Promoted the existing snapshot/history design to normative scenarios; tasks 6.3, 6.4, and 6.6 verify edits after enqueue and run retrieval after recipe deletion.

5. **Accurate run endpoint path (Suggestion)** — `openspec/changes/add-spry-api/design.md:104` → Replaced nonexistent `POST /runs` references in the lifecycle diagram and operation description with the actual nested endpoint.

6. **Serialize recipe deletion and run admission (Warning)** — `openspec/changes/add-spry-api/design.md:124` → Required both transactions to lock and re-read the account-scoped recipe row; admission rebuilds its plan under the lock. Added a delta scenario and concurrent tests for both orderings.

7. **Resolve conflicts outside an aborted transaction (Warning)** — `openspec/changes/add-spry-api/design.md:123` → Required rollback/savepoint recovery before querying the active run; retry admission if the conflicting run already finished. Task 6.3 tests concurrent insert/completion.

8. **Rollback when enqueue returns an error (Warning)** — `openspec/changes/add-spry-api/design.md:118` → Required explicit rollback on every enqueue error and storing the returned execution id in the same repo transaction. Task 6.3 verifies no orphan run/message and compiles job definitions for integration tests.

9. **Verified missing-sprite SDK result (Suggestion)** — `openspec/changes/add-spry-api/design.md:95` → Recorded `{:error, {:not_found, body}}` from installed SDK source, preserved other errors as failures, and updated task 5.1 and the formerly open SDK question.

### Model-recommended patches

1. **Credential timing for queued and executing runs (Warning)** — `openspec/changes/add-spry-api/specs/sprites-credential/spec.md:74`
   - **Chose:** Fetch the current credential once after claim; retain one in-memory client throughout execution. Missing credentials fail before VM calls, and no plaintext token/client enters persisted jobs or plans.
   - **Rationale:** This matches the proposal that later runs use the replacement token and prevents one run from crossing organizations after a rotation. Removal affects future claims; it does not change an already claimed client.

2. **Short-token metadata (Warning)** — `openspec/changes/add-spry-api/specs/sprites-credential/spec.md:42`
   - **Chose:** Return `last4: null` for non-empty tokens of four or fewer characters, retaining the existing acceptance rule.
   - **Rationale:** Returning four characters could expose the entire token. Suppressing this metadata closes the contradiction without inventing provider-specific token-length validation.

3. **Elapsed-time action deadlines (Critical)** — `openspec/changes/add-spry-api/design.md:97`
   - **Chose:** Enforce a wrapper-owned monotonic deadline for lookup/create/exec/destroy, with supervised local-task cleanup and a continuous-output regression test. Document that remote shell termination is not guaranteed.
   - **Rationale:** The installed SDK receive timeout resets on output and cannot satisfy the step deadline. A separate elapsed-time bound preserves existing buffered execution while making its local guarantees explicit.

4. **Total-run budget and PgFlow hard timeout (Warning)** — `openspec/changes/add-spry-api/design.md:119`
   - **Chose:** Use a configurable six-hour total-run budget; cap actions by remaining time, reserve five minutes of finalization overhead in PgFlow (default 21,900 seconds), and reject incompatible configuration.
   - **Rationale:** Installed PgFlow actively terminates tasks on timeout, so a vaguely high timeout is insufficient. An explicit budget bounds multi-step runs and gives normal finalization time before the hard kill; the reaper covers external termination.

5. **Confirm execution ownership ended before reaping (Critical)** — `openspec/changes/add-spry-api/design.md:130`
   - **Chose:** Record execution ownership and PgFlow id, corroborate staleness with execution state, stop and confirm reachable local execution before release, retain the guard for unreachable owners, and use conditional worker/reaper transitions.
   - **Rationale:** Timestamps and failed PgFlow rows alone cannot establish worker death. This prioritizes the one-active-executor contract; an unreachable owner requires restored contact or operational confirmation of node termination. Tests cover late workers, completion races, queued claim races, and guard release.

### Skipped

_None._

## Critical

_None._

## Warning

_None._

## Suggestion

_None._

## Alignment notes

- **Other active changes:** None; no overlapping capabilities or change conflicts.
- **Canonical specs:** None to compare. All four capabilities are ADDED deltas, matching the proposal.
- **Codebase assumptions verified:** API read/write pipelines in `app/lib/good_flows_web/router.ex:35` and `:39`; existing fallback behavior in `app/lib/good_flows_web/controllers/fallback_controller.ex:12`; empty PgFlow job registration in `app/config/runtime.exs:42`; and shared enqueue repo configuration in `app/config/config.exs:83`.
- **SDK deadline evidence:** `app/deps/sprites/lib/sprites/command.ex:601` recursively starts another receive timeout for each output message. Missing-sprite mapping is explicit in `app/deps/sprites/lib/sprites/client.ex:129`.
- **PgFlow evidence:** `app/deps/pgflow/lib/pgflow/worker/server.ex:502` terminates timed-out tasks; `:1171` schedules the hard execution timer. `app/deps/pgflow/lib/pgflow.ex:223` documents enqueue failure when definitions are not compiled.
- **Existing request filtering:** Phoenix already filters token request parameters (`app/deps/phoenix/mix.exs:72`); no redundant missing-filter finding was added.
- **Accepted implementation limits:** Buffered SDK output may consume more memory than the persisted 64 KiB tail. Local timeout/disconnect does not establish remote shell termination. An unreachable execution owner keeps its guard until termination is confirmed. These are explicit trade-offs, not skipped findings.

## Verification

- `openspec validate add-spry-api --strict` passes after the patches.
- Reviewed requirement/scenario structure, task coverage for new decisions, and report finding counts/references.
- Application code was not changed; application execution tests remain implementation tasks.

## What looks good

- Account-scoped reads and private-key writes match existing authentication patterns.
- Pure planning shares validation and expansion between dry-run and asynchronous execution.
- Database uniqueness enforces active-run admission, with explicit transaction and lifecycle handling.
- Immutable plans, fail-fast execution, ciphertext checks, and negative API tests are represented in implementation tasks.
