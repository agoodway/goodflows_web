# Inspector Review-Update — remove-spry-and-sprite-pools

**Reviewed:** 2026-11-04
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Ready to implement

## Summary

The change removes Spry and sprite pools while retaining projects and report storage. Two specialist reviews identified retirement and fixture blockers plus verification and cleanup gaps. All findings were patched within this change directory; application code and canonical specs were not modified.

**Original counts:** Critical: 2 · Warning: 4 · Suggestion: 3
**Patches:** Auto-patched: 9 · User-guided: 0 · Model-recommended: 0 · Skipped: 0

## Scope inspected

- Proposal: `proposal.md`; design: `design.md`; tasks: `tasks.md`; metadata: `.openspec.yaml` (paths relative to this change directory).
- All delta and canonical specs for `projects`, `test-report-storage`, `spry-recipes`, `spry-runs`, `spry-templates`, `sprites-credential`, `sprite-pools`, `pool-sessions`, `pool-execs`, and `sprite-transfers`.
- Application contexts, routes/helpers, fixtures and shared tests, migrations, configuration, dependency/check aliases, and local OpenSpec sync/archive guidance.
- Other active changes: none. Change files were untracked, with no change-specific Git history.

## Patches applied

9 findings were auto-patched. 0 were patched after user guidance. 0 were patched from model recommendations. 0 were skipped. Citations below refer to updated artifacts in this directory.

### Auto-patched

1. **Critical — capability retirement and archive lifecycle** — `.openspec.yaml:3`, `design.md:43`, `tasks.md:36`: declared `retire_capabilities: true`, replaced unsupported Purpose-only leftovers with the supported retirement workflow, and moved post-implementation archive actions outside tracked completion tasks. Local sync/archive skills require this marker for full retirement.
2. **Critical — shared project fixture would disappear** — `tasks.md:22`: require extracting `project_fixture/2` into `ProjectsFixtures` and updating surviving imports before deleting Spry fixtures. Evidence: `app/test/support/fixtures/spry_fixtures.ex:28`.
3. **Warning — premature green gates** — `tasks.md:3`, `tasks.md:28`: coordinate groups 1–3 and run dependent checks after migration/fixture updates. Explicitly remove pool migration setup from the surviving migration test while retaining report FK ordering. Evidence: `app/test/good_flows/migrations/create_projects_migration_test.exs:9` and `:28`.
4. **Warning — reference audit could never pass before archive** — `tasks.md:12`, `tasks.md:34`, `tasks.md:40`, `design.md:17`, `design.md:48`: separate application audit from canonical retirement audit, include hidden maintained files, and exclude generated/dependency/history content and generic pool terminology.
5. **Warning — missing shared parser test migration** — `tasks.md:22`: rewrite `require_parsed_body_test.exs` around project routes, retaining content-type, auth precedence, delete, JSON success and no-mutation checks. Evidence: `app/test/good_flows_web/plugs/require_parsed_body_test.exs:14`.
6. **Warning — project deletion signature and outcomes** — `design.md:9`, `design.md:41`, `tasks.md:9`, `tasks.md:18`: correct `/1` to `/2` and preserve success/not-found outcomes and account isolation. Evidence: `app/lib/good_flows/projects.ex:65`.
7. **Suggestion — shared helper documentation** — `tasks.md:8`: include pool wording cleanup in RawBodyHeaders, SentryScrubber and RequireParsedBody while retaining their report behavior and redaction tests.
8. **Suggestion — unrelated host coverage** — `tasks.md:22`: replace the Sprites example hostname in the retained runtime URL/issuer test with `example.com`, preserving the test. Evidence: `app/test/good_flows/runtime_config_test.exs:14`.
9. **Suggestion — unlock behavior description** — `design.md:49`: describe the unused-lock task as removing entries and require lockfile inspection rather than claiming it fails on unused locks.

### Model-recommended patches

_None. Findings had verifiable mechanical or additive fixes; no product decision was required._

### Skipped

_None._

## Critical

_None._

## Warning

_None._

## Suggestion

_None._

## Alignment notes

- **Other active changes:** none; no concurrent spec conflict found.
- **Canonical specs:** all eight removal deltas match their canonical requirement names and counts. Projects owns the retained delete rule; test-report acknowledgement behavior is preserved.
- **Codebase assumptions verified:** shared fixture consumers, parser tests, migration dependencies, project deletion signature, and generic report helper consumers.
- **Verification:** strict change validation passed after edits. Application tests were not run for this planning-only review; application dependencies are not installed in this checkout. PgFlow empty-job startup remains an explicit implementation check with the existing fallback.

## What looks good

- Composite project/account index remains for report foreign keys.
- Reset and rollback implications of rewriting migration history are explicit.
- Generic encryption, background-job infrastructure and release distribution remain within the stated scope.
