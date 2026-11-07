# Inspector Review-Update — remove-sprite-pools

**Reviewed:** 2026-11-05
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Ready to implement

## Summary

The change removes sprite pools: the API, socket, reconciler, `gf-transfer` helper, and four tables, and it drops the `gfp-` reservation and the pool check on project deletion. The four pool deltas remove every canonical requirement, and the projects, spry-recipes, and spry-templates replacements keep the non-pool behavior. After the patches, the tasks match the code: shared Sprites helpers stay, pool-only test support is deleted, and the early `mix test` gates no longer run while Spry tests still reference pool modules.

**Original counts:** Critical: 0 · Warning: 5 · Suggestion: 1
**Patches:** Auto-patched: 5 · User-guided: 0 · Model-recommended: 1 · Skipped: 0

## Scope inspected

- Proposal: `openspec/changes/remove-sprite-pools/proposal.md`
- Design: `openspec/changes/remove-sprite-pools/design.md`
- Tasks: `openspec/changes/remove-sprite-pools/tasks.md`
- Deltas:
  - `openspec/changes/remove-sprite-pools/specs/sprite-pools/spec.md`
  - `openspec/changes/remove-sprite-pools/specs/pool-sessions/spec.md`
  - `openspec/changes/remove-sprite-pools/specs/pool-execs/spec.md`
  - `openspec/changes/remove-sprite-pools/specs/sprite-transfers/spec.md`
  - `openspec/changes/remove-sprite-pools/specs/projects/spec.md`
  - `openspec/changes/remove-sprite-pools/specs/spry-recipes/spec.md`
  - `openspec/changes/remove-sprite-pools/specs/spry-templates/spec.md`
- Canonical specs consulted:
  - `openspec/specs/sprite-pools/spec.md`
  - `openspec/specs/pool-sessions/spec.md`
  - `openspec/specs/pool-execs/spec.md`
  - `openspec/specs/sprite-transfers/spec.md`
  - `openspec/specs/projects/spec.md`
  - `openspec/specs/spry-recipes/spec.md`
  - `openspec/specs/spry-templates/spec.md`
  - `openspec/specs/spry-runs/spec.md`
  - `openspec/specs/sprites-credential/spec.md`
  - `openspec/specs/test-report-storage/spec.md`
- Other active changes consulted: none

## Patches applied

5 findings were auto-patched. 0 were patched after user guidance. 1 was patched from a model recommendation. 0 were skipped.

### Auto-patched

1. **Pool test support left behind** — `openspec/changes/remove-sprite-pools/design.md:18` → Added `FakeExec` and `TarFixtures` to the design test-support list, the proposal test impact, and the task 3.6 delete list. Every caller is a pool test already removed earlier.
2. **`mix test` cannot pass at task 3.6** — `openspec/changes/remove-sprite-pools/tasks.md:26` → Task 3.6 now removes only the `Pools` Mimic copies and the `:helper_binary` exclusion, and it checks compile instead of the full suite. The `Sprites.Checkpoint` and `Sprites.Filesystem` copies move to task 4.2. Task 3.7 greps `lib` only, because `sprites_test.exs` still aliases `GoodFlows.Pools.TransferProtocol` until that task.
3. **`:draining` is a pool error** — `openspec/changes/remove-sprite-pools/design.md:66` → Design and task 2.4 now remove the `:draining` fallback clause. Only `GoodFlows.Pools.Sessions` returns it. `:admission_contended` stays, because Spry returns that error.
4. **Doc comments the pool grep would still hit** — `openspec/changes/remove-sprite-pools/tasks.md:17` → Task 2.4 rewrites the `body_parsers.ex` moduledoc. Task 2.6 removes the raw-body comment in `endpoint.ex` (around lines 60-61) and allows the Ecto `pool_size` mention in `test_report_admission.ex`.
5. **Config grep matches a stock DBConnection comment** — `openspec/changes/remove-sprite-pools/tasks.md:22` → Task 3.2's verify step allows the `config/runtime.exs` comment about multiple pools of `pool_size`.

### Model-recommended patches

1. **`tail/2` is test-only, and its helpers are shared** — `openspec/changes/remove-sprite-pools/design.md:60` → `tail/2` stays on the delete list. Design and task 4.1 now keep `finish_output/3` and `drop_continuation_bytes/2`, because private `collect/6` (used by `exec`) calls them. Task 4.2 deletes the `tail/2` describe and replaces the `Wrapper.tail/2` call in `run_job_test.exs`.
   - **Chose:** Delete `tail/2` and update the two Spry tests. Keep the shared output helpers.
   - **Rationale:** The design goal is that `Sprites` keeps only what Spry calls. Production Spry does not call `tail/2`; the tests do. Keeping the function would leave a public wrapper with no production caller. Deleting `finish_output/3` with it would break `exec`.

### Skipped

_None._

## Critical

_None._

## Warning

_None._

## Suggestion

_None._

## Alignment notes

- **Other active changes:** No conflict. `remove-sprite-pools` is the only unarchived change.
- **Canonical specs:** Each REMOVED requirement name matches a canonical heading. The four pool deltas remove every requirement in `sprite-pools` (20), `pool-sessions` (16), `pool-execs` (16), and `sprite-transfers` (12). The added projects, spry-recipes, and spry-templates requirements keep the surviving scenarios and drop only the pool and `gfp-` ones. `spry-runs`, `sprites-credential`, and `test-report-storage` do not require pool behavior. Deltas cannot edit the projects Purpose; task 7.3 already says to drop "and sprite pools" and "or pools" by hand at archive.
- **Codebase assumptions verified:** Application children, router, controllers, OpenAPI schemas, config, migration, and the listed `Sprites` arities match the tasks. `bounded/3` serves `exists?`, `create`, `destroy`, and `exec`. Private `collect/6` is called only from `exec`. `openspec validate remove-sprite-pools --strict` passes after the patches.

## What looks good

- Removing each pool requirement, and replacing the three shared requirements under new names, matches the OpenSpec rule that a modified requirement cannot drop scenarios.
- `retire_capabilities: true` retires the four pool specs at archive instead of leaving empty files.
- Deleting `20261102100000_create_sprite_pools.exs` with no drop migration matches the confirmed deployment state, and tasks 1.1 and 1.2 cover member sprites and local databases.
- The `gfp-` deltas loosen only the reserved-prefix rule. Existing invalid-name scenarios and status codes are unchanged.
- Task order still removes the web layer before the pool modules, and it keeps the app compiling at the compile gates.
