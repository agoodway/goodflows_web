# Design

## Context

See proposal.md for why. Spry and pools are wired into shared code in a few places:

- `GoodFlows.Application` starts their supervisors, drains, schedulers, and reconciler. It also calls `Spry.Config.validate!/0` and `Pools.Config.validate!/0`, and installs `Spry.Redaction`'s logger filter.
- `config/config.exs` points Sentry's `before_send` at `GoodFlows.Spry.Redaction`. `config/runtime.exs` registers five PgFlow jobs (two Spry, three pool) along with their worker limits and the whole `GoodFlows.Pools` config block.
- `GoodFlows.Projects.Project` has `has_many :recipes`/`:pools` and `no_assoc_constraint` guards. `GoodFlows.Projects.delete_project/2` maps them to `:has_recipes`/`:has_pools`, and `FallbackController` renders those.
- Migration `20261101190000_create_projects` alters `recipes` (adds `project_id`, swaps the unique index) and refuses to run while `recipes` has rows. `20261101200000_create_test_reports` adds a composite FK `(project_id, account_id)` to the `projects (id, account_id)` unique index.
- `GoodFlowsWeb.Plugs.BodyParsers.raw_body_route?/1` skips parsing for test report uploads *and* pool workspace uploads.
- `GoodFlows.Vault`/`Encrypted.Binary` (Cloak) and PgFlow are generic infrastructure, but today only Spry and pools use them.

## Goals / Non-Goals

**Goals:**
- After implementation, maintained application code, routes, configuration, migrations, documentation, and tests have no Spry or sprite-pool references. Generic database pool settings remain. Canonical capability retirement happens during archive; historical change artifacts are retained.
- A fresh `mix ecto.reset` produces a schema with no Spry or pool tables, and `mix check` passes.

**Non-Goals:**
- Removing generic infrastructure that has no users left: PgFlow (its extension/pgmq/pgflow migrations and the supervisor), Cloak (`GoodFlows.Vault`, `Encrypted.Binary`), and named-node release distribution. Each one stays in place, ready for future features.
- Changing test report behavior.
- Editing archived changes under `openspec/changes/archive/`.

## Decisions

**Rewrite the migration history instead of adding a drop migration.** Nothing has been deployed with real data, so a clean history costs nothing and saves future readers from dead `create`-then-`drop` pairs. Delete `create_recipes`, `create_sprites_credentials`, `create_runs`, `create_run_steps`, and `create_sprite_pools`. Rewrite `create_projects` to create only `projects` with its `(account_id, slug)` and `(id, account_id)` unique indexes; the second index stays because `test_reports` references it. Its `down` becomes a plain `drop table`. Keep the migration timestamps so the ordering with `create_test_reports` holds.
*Alternative*: a forward migration dropping the tables. That would be needed if any environment held data, but none does.

**Keep PgFlow with an empty job list.** `config :good_flows, PgFlow` keeps `jobs: []` (and drops `worker_options`), so the pgflow migrations stay valid and a future job only needs a list entry. If PgFlow refuses to start with no jobs, drop the PgFlow child from `Application` but keep the config and migrations.
*Alternative*: remove PgFlow entirely. That means rewriting three more migrations and a dependency for little gain.

**Keep Cloak (`GoodFlows.Vault`).** It is generic encrypted-at-rest infrastructure, and its production key check is cheap. Only the comments that mention Sprites tokens change.

**Keep named-node distribution; drop the Spry enforcement.** `require_named_node` and `Spry.Config.validate!/0` go away with Spry. `rel/env.sh.eex` keeps its defaults, and its comment changes to a generic clustering note.

**Delete `Leadership`.** Its only callers are the Spry reaper scheduler and the pool reconciler. A future scheduler that needs leader election can bring it back from git history.

**Remove the Sentry `before_send` hook and the logger filter.** Both exist only to scrub the Sprites token from SDK process state. The `"token"` entry in `:filter_parameters` stays: it is a generic safeguard, and only its comment changes.

**Projects own the delete rule.** The `projects` spec keeps "a project with test reports cannot be deleted". `test-report-storage` drops its duplicate copy of that rule (see specs). In code, `delete_project/2` preserves `:ok` and `{:error, :not_found}` (including account mismatch and stale deletion); `{:error, :has_test_reports}` is the only remaining association conflict.

**Remove whole capabilities through REMOVED deltas.** Each of the 8 removed specs lists every requirement as REMOVED. Declare `retire_capabilities: true` in `.openspec.yaml`. During spec sync/archive, retire the eight canonical specs using the supported retirement workflow instead of writing empty Requirements sections; remove empty capability directories only after checking they contain no other artifacts. Separately, rewrite the `projects` Purpose in `openspec/specs/projects/spec.md`, because a delta cannot change a Purpose.

## Risks / Trade-offs

- [Existing dev/test/workie databases still have the old tables and `schema_migrations` rows] → Every developer runs `mix ecto.reset` (workie branch databases: drop and recreate them). The tasks call this out, and the PR description must too.
- [Stray references survive in places grep misses, such as OpenAPI tags or test helpers] → The final implementation audit searches maintained application files with `rg --hidden`, allows generic database pool terminology, and runs `mix check`. Canonical specs are audited separately after sync/retirement; historical changes remain intact.
- [Stale transitive locks remain after dependency removal] → `mix check` already runs the unlock task, which removes unused locks; inspect the resulting lockfile. Run `mix deps.unlock --unused` after removing `sprites`.
- [An unknown external client uses the removed API] → Accepted. No known clients exist (see proposal).

## Migration Plan

1. Land the change on a branch, then run `mix ecto.reset` locally and in each workie worktree.
2. No deploy steps: no environment holds data. Rollback means reverting the commit and resetting again.
