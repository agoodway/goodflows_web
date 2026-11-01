# Inspector Review-Update — store-test-timings

**Reviewed:** 2026-11-01
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Needs revision (companion publisher contract); target artifacts reviewed and patched

## Summary

The change adds private-key-authenticated `POST /api/v1/projects/:project/test-reports` ingestion with immutable JSONB storage, project-scoped identity and per-report completion. Two specialists found six actionable artifact issues; all were patched within this change directory. The target artifacts have no remaining review findings, but the existing prerequisite to update the companion publisher contract remains outstanding. The dependent projects capability must also be synced before this change can be archived.

**Original counts:** Critical: 0 · Warning: 5 · Suggestion: 1
**Patches:** Auto-patched: 5 · User-guided: 0 · Model-recommended: 1 · Skipped: 0

## Scope inspected

- Proposal: `openspec/changes/store-test-timings/proposal.md`
- Design: `openspec/changes/store-test-timings/design.md`
- Tasks: `openspec/changes/store-test-timings/tasks.md`
- Deltas:
  - `openspec/changes/store-test-timings/specs/test-report-storage/spec.md` (ADDED: ingestion, strict validation, identity, completeness, project deletion protection and acknowledgements)
  - `openspec/changes/store-test-timings/specs/projects/spec.md` (MODIFIED: existing project deletion rule; added during this review)
- Canonical specs consulted: `openspec/specs/spry-recipes/spec.md`, `openspec/specs/spry-runs/spec.md`. Neither `projects` nor `test-report-storage` has a canonical spec yet.
- Other active changes consulted: `openspec/changes/scope-recipes-by-project/`, including its `projects` delta and implementation in the working tree.
- Companion artifacts consulted: `../goodci/openspec/changes/upload-test-timings/` and `../goodcases/openspec/changes/publish-test-timings/`; producer formatter and publisher configuration validation were checked.
- Git: target directory is untracked and has no committed history. Existing application changes belong to the projects work; this review did not edit application files.

## Patches applied

5 findings were auto-patched. 0 were patched after user guidance. 1 was patched from a model recommendation. 0 were skipped. References below use final artifact line numbers.

### Auto-patched

1. **Project deletion specifications contradicted each other** (Warning) — `openspec/changes/store-test-timings/proposal.md:24`, `openspec/changes/store-test-timings/specs/projects/spec.md:5`, `openspec/changes/store-test-timings/design.md:108`, `openspec/changes/store-test-timings/tasks.md:27` → Declared `projects` modified and added a MODIFIED copy of the dependency's deletion requirement. A deletable project now has neither recipes nor reports; recipe-only and report-only projects retain 409 protection. Recorded that the dependency must be implemented and synced/archived first. Evidence: `openspec/changes/scope-recipes-by-project/specs/projects/spec.md:60` previously required 204 for every project without recipes.
2. **Concurrency admission lacked normative coverage and cleanup tests** (Warning) — `openspec/changes/store-test-timings/specs/test-report-storage/spec.md:131`, `openspec/changes/store-test-timings/specs/test-report-storage/spec.md:145`, `openspec/changes/store-test-timings/design.md:93`, `openspec/changes/store-test-timings/tasks.md:19` → Added the existing configurable cap (default 2), 503 with `Retry-After` before reading/writing when full, and slot reclamation after success, errors and request-process termination. Added an exhaustion scenario and verification tasks.
3. **Task described a nonexistent validation code field** (Suggestion) — `openspec/changes/store-test-timings/tasks.md:8` → Replaced “field paths/codes” with field paths and fixed validation messages, matching D3 and the existing validation response shape.
4. **Parser length option did not enforce the exact byte boundary** (Warning) — `openspec/changes/store-test-timings/design.md:93`, `openspec/changes/store-test-timings/tasks.md:19` → Require rejection of `{:more, ...}` and an explicit byte-size check even on `{:ok, body, conn}` before decoding. Added exact-limit and oversize-success-tag coverage. Evidence: `app/deps/plug/lib/plug/conn.ex:1167` documents that read lengths are approximate.
5. **Environment had no explicit non-null type or bound** (Warning) — `openspec/changes/store-test-timings/design.md:39`, `openspec/changes/store-test-timings/tasks.md:6` → Defined environment as null or a nonempty string of at most 64 UTF-8 bytes without control characters and required type/bound validation tests. Evidence: `../goodci/src/config.rs:149` and `../goodci/src/config.rs:245` already enforce these rules for environment names.

### Model-recommended patches

1. **Persistence failure cannot guarantee rollback after lost commit confirmation** (Warning) — `openspec/changes/store-test-timings/specs/test-report-storage/spec.md:131`, `openspec/changes/store-test-timings/specs/test-report-storage/spec.md:150`, `openspec/changes/store-test-timings/design.md:79`, `openspec/changes/store-test-timings/tasks.md:14` → Limited the no-write guarantee to requests rejected before persistence and documented uncertain persistence outcomes.
   - **Chose:** Return 503 without acknowledgement on persistence connection failures/timeouts; allow an already committed row and resolve it through an exact frozen retry using the existing immutable identity. Added lost-confirmation coverage proving a retry returns the committed id without another row.
   - **Rationale:** Commit can succeed before its confirmation is lost. Exact retries preserve the proposal's immutable idempotency contract without falsely promising rollback or inventing a new reconciliation API.

### Skipped

_None._ All six findings were resolved. External prerequisites below were already recorded in the input artifacts and remain outside this review's authorized edit scope.

## Critical

_None._

## Warning

_None._ No unpatched findings in the target artifacts.

## Suggestion

_None._

## Alignment notes

- **Other active changes:** `scope-recipes-by-project` provides the table, context and loader this change depends on. Its unconditional empty-of-recipes deletion rule (`openspec/changes/scope-recipes-by-project/specs/projects/spec.md:60`) is superseded by this change's new MODIFIED delta after the dependency is synced. The dependency's own design anticipates report deletion protection at `openspec/changes/scope-recipes-by-project/design.md:93`.
- **External readiness prerequisite:** `../goodci/openspec/changes/upload-test-timings/design.md:54` still posts to `/api/v1/test-timing-reports`; it must use `/api/v1/projects/:project/test-reports` and omit body `project`. This remains explicit in `openspec/changes/store-test-timings/proposal.md:33` and `openspec/changes/store-test-timings/tasks.md:30`. Companion contract alignment must finish before declaring the coordinated implementation ready. No companion files were edited.
- **Canonical specs and validation:** `openspec validate store-test-timings --strict` passes. It also emits an informational archive warning because canonical `projects` does not exist yet. This is the documented dependency order, not permission to archive early: sync/archive `scope-recipes-by-project` first, then revalidate and sync/archive this change. Existing canonical Spry specs are unaffected.
- **Codebase assumptions verified:** Existing `GoodFlows.Projects`, `Project.valid_slug?/1`, `LoadProject`, write pipelines and recipe-deletion constraint mapping match the plan. The installed Sentry supports the proposed body scrubber callback. The producer preserves the timing event fields used by D1. No test-report implementation exists yet; this is artifact review, not implementation verification.
- **Verification scope:** Strict OpenSpec validation and artifact consistency checks only; no application tests were required for documentation-only changes.

## What looks good

- Account and project ownership come from authentication and the resolved path, rather than body fields.
- Immutable whole-document equality handles exact retries while preserving incomplete reports.
- Test failures are distinct from report incompleteness and whole-invocation completion.
- Body bounds, payload exclusions and diagnostic scrubbing are explicit.
- Storage remains separate from Spry execution and has a data-preserving rollback option.
