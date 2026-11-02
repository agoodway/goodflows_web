# Inspector Review-Update — add-sprite-pools

**Reviewed:** 2026-11-01
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Ready to implement

> This report replaces the earlier pass. This pass checked the change against the code that landed afterwards: project-scoped recipes, test report storage (`TestReportBody`, `TestReportAdmission`, `SentryScrubber`), and the `RequireParsedBody` 415 plug. It also checked the sprites SDK 0.2.4 sources in `app/deps/sprites`.

## Summary

The change adds project-scoped Sprite pools, leased sessions, a Phoenix Channels exec contract, and the Rust `gf-transfer` helper. None of it is implemented yet. The MODIFIED deltas for projects, spry-recipes, and spry-templates still match the current canonical text.

Most problems were codebase drift:

- The design described SDK checkpoint calls as incremental streams. They are blocking calls.
- The `on_delete` choices did not follow the project deletion pattern the repo uses.
- The workspace upload route was missing the Sentry scrubber, the OpenAPI `415`, and the test-report-style upload guards.
- The design did not say how pools are enabled in tests.

There were also contradictions between files: exec status on owner loss, grants bounded by `wanted`, and pool response fields.

Every finding is patched. `openspec validate add-sprite-pools --strict` passes.

**Original counts:** Critical: 0 · Warning: 16 · Suggestion: 16
**Patches:** Auto-patched: 25 · User-guided: 0 · Model-recommended: 7 · Skipped: 0

## Scope inspected

- Proposal: `openspec/changes/add-sprite-pools/proposal.md`
- Design: `openspec/changes/add-sprite-pools/design.md`, `transfer-design.md`, `implementation-plan.md`
- Tasks: `openspec/changes/add-sprite-pools/tasks.md`
- Deltas:
  - `openspec/changes/add-sprite-pools/specs/{sprite-pools,pool-sessions,pool-execs,sprite-transfers,projects,spry-recipes,spry-templates}/spec.md`
- Canonical specs consulted:
  - `openspec/specs/{projects,spry-recipes,spry-templates,spry-runs,sprites-credential,test-report-storage}/spec.md`
- Other active changes consulted: `generalize-test-report-filters` (test-report-storage suite filters only, no overlap)

## Patches applied

25 findings were auto-patched and 7 were patched from model recommendations. None were skipped.

### Auto-patched

1. **SDK checkpoint calls are not streams.** `create_by_name`/`restore_by_name` block on `:httpc` with `{:timeout, :infinity}` and return the full message list (`deps/sprites/lib/sprites/checkpoint.ex:215-233`).
   - `design.md` Context and D1, and task 5.1, now say that the `bounded/3` kill is the only timeout and that a timed-out create or restore has an unknown remote outcome, so the member becomes `broken`.
   - The checkpoint comment lookup is filtered in GoodFlows.
2. **`stderr_to_stdout` is a `cmd/4` option, not a `spawn/4` one** (`command.ex:79`). Changed in D12 and tasks 2.4 and 5.1: stderr is kept out of the protocol decoder.
3. **Blocking `bounded/3` would freeze ExecServer and coordinator** (`sprites.ex:115-154`). D7 and task 2.4 now make `spawn_streaming`/`transfer/5` non-blocking. They return a handle, and the owner enforces the deadline through `Executions.kill_and_confirm/3`.
4. **Reserved-prefix validation locations.** D11 now names the real functions: `Template.reserved_sprite_name?/1`, `Recipe.name_format_errors/2`, `Plan.sprite_override_errors/2`, and `Plan.expand_name/2`.
5. **Breaking-change note was wrong.** `Plan.build` checks the expanded name on every run, so existing `gfp-` recipes fail on their next run as well as their next save (`design.md` Risks).
6. **Project FK mechanism.** In D10 and task 4.1, `ON DELETE RESTRICT` is replaced by the repo pattern: a composite FK with `on_delete: :nothing`, `no_assoc_constraint(:pools, …)`, `{:error, :has_pools}`, a FallbackController 409, and an updated OpenAPI description.
7. **`api_key_id` nilify does not trigger expiry.** D10 now has the reconciler expire sessions whose key is NULL, revoked, or expired with `key_revoked`. Task 6.2 tests this.
8. **SentryScrubber was missing from the raw-body route** (`sentry_scrubber.ex:13-16`). Added in D5 and task 7.1, with a Sentry test.
9. **Write ops missing the OpenAPI `415`.** Tasks 4.3 and 6.4 now add `ApiParams.unsupported_media_type()` and add the routes to `write_routes/1` in `require_parsed_body_test.exs`.
10. **OpenAPI project-operations test.** Tasks 4.3 and 6.4 now add the pool and session operations to `@project_operations` in `openapi_test.exs`.
11. **Pools would be disabled in tests.** The helper manifest is gitignored and cargo does not run in `mix precommit`. D13 and task 1.2 now add a committed fixture manifest under `test/support/fixtures/gf-transfer` configured in `config/test.exs`, plus a test that a missing manifest disables pools.
12. **Supervisor placement.** `pgflow_children/1` is empty in tests. D13 now starts the drain, coordinator and ExecServer supervisors, and the transfer semaphore in the main child list before the Endpoint. Only `PoolReconciler` stays in `pgflow_children/1`, and `Pools.Config.validate!/0` runs at application start.
13. **Channel param logging.** `Phoenix.Channel` logs `handle_in` params at `:debug`, and `filter_parameters` covers only password and token. D7 and task 8.5 now set `log_join: false, log_handle_in: false` and capture logs at `:debug`.
14. **Credential in crash reports.** D7 now keeps the credential only as `%Sprites.Client{}` or under `:token`, with `format_status/1`. Task 8.5 extends the redaction tests.
15. **Grants bounded by `wanted`, not `max_members`.** `pool-sessions/spec.md` "Members are granted partially".
16. **Pool response omitted provisioning diagnostics.** `sprite-pools/spec.md` "Pool responses report member state" now includes `provision_failures`, `next_provision_at`, and `last_provision_error`.
17. **Task 6.4/6.5 order.** Moved 6.5 below 6.4.
18. **Stale archive-default wording.** Fixed in `implementation-plan.md:19` and `transfer-design.md:110-111` to point to the D13 defaults.
19. **"still idle in the session" misuses the member state name.** `pool-execs/spec.md` report download scenario.
20. **Resume requirement ordering.** The `pool-execs` "Execs survive reconnects" requirement now introduces `resume` before its details and names the `gap` fields (`exec_id`, `from_seq`, `to_seq`).
21. **Channel event names missing from the spec.** `want` (`{wanted}`), `release_member` (`{member_id}`), and `release` are now in `pool-sessions/spec.md`.
22. **No task for member name generation.** Task 5.2 now covers the `gfp-` + base32 format, the unique index, and a collision retry test.
23. **Exec rejection tests incomplete.** Task 8.2 now also covers `not_granted`, `member_not_ready`, `command`/`argv` exclusivity, and `timeout_ms` < 1.
24. **No requirement for disabled pools or a draining node.** Added "Pools can be disabled" to `sprite-pools/spec.md` with a scenario, linked from task 4.3.
25. **No scenario for a pool still being deleted.** Added a scenario to `projects/spec.md`.

### Model-recommended patches

1. **Exec status when a session ends with `session_owner_lost`.** Changed `pool-execs/spec.md` "Session end stops execs", the `pool-sessions` scenarios, and D13.
   - **Chose:** status `error` with `error_reason` `owner_lost` for owner loss, and `cancelled` for every other end reason.
   - **Rationale:** This matches the existing "Exec owner lost" scenario and the D13 drain wording. Clients can tell infrastructure loss apart from deliberate cancellation.
2. **Default provision budget.** Added to D13 and task 5.2.
   - **Chose:** `provision_timeout_ms` defaults to 30 min. Startup validation requires the job timeout to cover the budget plus margin, and a member over budget becomes `broken`.
   - **Rationale:** D3 derives a compile-time job timeout from this setting, so it needs a default. 30 min fits toolchain-installing setups.
3. **Credential snapshot retention after credential removal.** Added to the `sprite-pools` "Credential changes pause provisioning" requirement.
   - **Chose:** Snapshots survive removal or replacement, stay encrypted and never returned, and are deleted with the member row.
   - **Rationale:** This is the smallest change. It is stated in sprite-pools instead of adding a MODIFIED sprites-credential delta that would have to copy canonical text, and it does not contradict the canonical "Remove a credential" requirement.
4. **Reset and destroy while the account credential is missing.** Changed in `sprite-pools/spec.md`, D13 Risks, and task 5.3.
   - **Chose:** Pause only provisioning. Reset and destroy continue with member snapshots.
   - **Rationale:** Snapshots exist for exactly this purpose. Pausing reset would strand released members in `resetting` and go against the proposal's goal of no leaked members.
5. **FK `on_delete` for pool tables.** Changed in D10.
   - **Chose:** `pool_members.pool_id` uses `:nothing`. `pool_sessions.pool_id` and `pool_execs.member_id` use `:nilify_all`, with `pool_slug`, `project_slug`, and `member_name` copied onto the rows. `pool_execs.session_id` uses `:delete_all`, and every `account_id` uses `:delete_all`.
   - **Rationale:** Session records must still show pool and project slugs after the pool and its members are removed. This also follows the existing `runs.recipe_id` nilify pattern.
6. **Workspace upload guards.** Changed in D5, D13, task 7.1, and the `pool-sessions` "Workspace upload" requirement.
   - **Chose:** The `TestReportBody` order: `415` on content type or encoding, a declared-length `413` before reserving, `503` for the spool budget or a per-account concurrent-upload cap (default 1), a `408` read deadline (default 300 s) that releases the reservation, then a chunked `413`.
   - **Rationale:** This reuses the pattern the codebase just established. It stops slow uploads from pinning spool reservations and stops one account from taking the whole node budget.
7. **Credential fingerprint definition.** Changed in the D13 Risks section of `design.md`.
   - **Chose:** HMAC-SHA256 of the token keyed with a server secret. Any token replacement is a new namespace that rebuilds members. Org-preserving rotation is deferred.
   - **Rationale:** `SpritesCredential` stores only `token` and `last4`, so no org identity is available. An HMAC avoids exposing a bare hash.

### Skipped

_None._

## Critical

_None._

## Warning

_None remaining._

## Suggestion

_None remaining._

## Alignment notes

- **Other active changes:** `generalize-test-report-filters` changes only test-report-storage filter requirements and does not conflict.
- **Canonical specs:** The projects RENAMED+MODIFIED block keeps every canonical clause, including the test-report deletion protection from store-test-timings. The spry-recipes and spry-templates MODIFIED blocks match canon word for word plus the `gfp-` additions.
- **Codebase assumptions verified:**
  - SDK 0.2.4 `Checkpoint` (blocking), `spawn/4` options, and `Filesystem.write/4`
  - `Sprites.bounded/3` and `await/3`, `exec/4` (the merge happens in our own `collect/6`)
  - `Plan`, `Recipe`, and `Template` validation functions
  - Projects composite FK and `no_assoc_constraint` pattern
  - `BodyParsers.test_report_upload?/1`, `RequireParsedBody`, `SentryScrubber`, and `TestReportBody` ordering
  - `ApiParams.unsupported_media_type/0`, `openapi_test.exs` `@project_operations`
  - `Application.pgflow_children/1` behavior in tests
  - `Phoenix.Channel` default logging, `Redaction` keys
- Nothing from this change is implemented yet.

## What looks good

- MODIFIED deltas are current with canon and drop nothing.
- Fenced state transitions and the owner-recovery design reuse the proven run machinery.
- The transfer protocol is thoroughly specified, and a live spike gates production integration.
- Raw-body handling was already planned to generalize the test-report predicate rather than add a second special case.
