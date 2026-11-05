# Proposal

## Why

The Spry API (recipes, runs, templates, Sprites credentials) and sprite pools (pools, sessions, execs, workspace/report transfers) are no longer wanted. Together they are most of the codebase, a Rust helper crate, a third-party SDK with outstanding vulnerability warnings, and five background jobs. GoodFlows should keep only projects and test report storage. Nothing has been deployed with real data, so the migration history can be rewritten instead of carrying drop migrations forever.

## What Changes

- **BREAKING** Remove every Spry endpoint: `/api/v1/projects/:project/recipes*`, `/api/v1/runs/:id`, and `/api/v1/sprites-credential` (GET/PUT/DELETE).
- **BREAKING** Remove every pool endpoint: `/api/v1/projects/:project/pools*`, `/api/v1/pool-sessions/*`, `/api/v1/pool-execs/:id/reports/:name`, and the `/api/v1/socket` channel socket.
- Remove the Spry and Pools contexts, their PgFlow jobs, schedulers, supervisors, config validation, mix tasks (`spry.force_abandon`, `pools.destroy_members`), and OpenAPI schemas.
- Remove the `sprite-transfer/` Rust crate, `docs/pool-protocol.md`, and the `sprites` Hex dependency.
- Remove the `Leadership` module, which only the Spry reaper and the pool reconciler used.
- **BREAKING (schema history)** Rewrite the migrations: delete the recipe, Sprites credential, run, run step, and sprite pool migrations, and reduce `create_projects` to the projects table alone. Every existing database must be reset.
- Project deletion is now blocked only by stored test reports.
- Remove pool and Spry settings from config, `.env.sample`, `rel/env.sh.eex` comments, and the README.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `projects`: a project groups only test reports, and deletion is blocked only by test reports (no recipes or pools).
- `test-report-storage`: drop the requirement text and scenarios that refer to recipes and Spry execution.
- `spry-recipes`: removed (all requirements).
- `spry-runs`: removed (all requirements).
- `spry-templates`: removed (all requirements).
- `sprites-credential`: removed (all requirements).
- `sprite-pools`: removed (all requirements).
- `pool-sessions`: removed (all requirements).
- `pool-execs`: removed (all requirements).
- `sprite-transfers`: removed (all requirements).

## Impact

- **Code**: `app/lib/good_flows/{spry,pools}/**`, `spry.ex`, `pools.ex`, `leadership.ex`. On the web side: the pool, recipe, run, and sprites-credential controllers, JSON views, schemas, the `PoolsEnabled` plug, and the `PoolSocket`/`SessionChannel`. Edits to `application.ex`, `endpoint.ex`, `router.ex`, `api_spec.ex`, `api_params.ex`, `fallback_controller.ex`, `changeset_errors.ex`, `body_parsers.ex`, `projects.ex`, and `projects/project.ex`.
- **Tests**: about 50 Spry and pool test files, plus the `fake_sprite`, `fake_exec`, `spry_fixtures`, and `pools_fixtures` support modules. Tests for projects, the OpenAPI document, and parameter filtering need updates.
- **Dependencies**: `sprites` (and its transitive `gun`/`cowlib`) leaves `mix.lock`. The `mix check` cargo build step goes away.
- **Database**: migrations rewritten. Dev, test, and every workie branch database need `mix ecto.reset`.
- **API clients**: any client of the removed endpoints breaks. No known external clients exist.
