# Proposal

## Why

Sprite pools were built so `goodci` could run jobs on pre-built Sprite VMs. The `goodci` remote client was never built, so nothing uses pools. The feature is a large part of the app: a context with 27 modules, a socket and channel, six controllers, a Rust helper crate, four tables, and the processes it supervises. Removing it for good drops that maintenance cost and makes `GoodFlows.Spry.Sprites` small again.

## What Changes

- **BREAKING** Remove the pool API: `/api/v1/projects/:project/pools` (CRUD and members), pool sessions, workspace upload, report download, and the Phoenix socket at `/api/v1/socket` with its `pool_session:*` channel. These routes respond `404` afterward.
- Remove pool member lifecycle and capacity management: provisioning, golden checkpoints, reset after lease, the reconciler, stale and broken handling, and shutdown drain.
- Remove the `gf-transfer` helper: the `sprite-transfer/` Rust crate, its packaged binaries, and the chunked transfer protocol.
- Delete the `create_sprite_pools` migration and its four tables (`pools`, `pool_members`, `pool_sessions`, `pool_execs`). The migration has never run on any database that must be kept, so no drop migration is added.
- Stop reserving the `gfp-` sprite name prefix. Recipe names, expanded sprite names, and `sprite` overrides may start with `gfp-` again. This loosens a rule, so existing recipes are unaffected.
- Project deletion no longer considers pools. A project is protected only by its recipes and test reports.
- Remove pool runtime configuration, the `mix pools.destroy_members` task, the `cargo build` step in `mix check`, and pool documentation (`docs/pool-protocol.md`, the README helper section, the OpenAPI pool description).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `sprite-pools`: all requirements removed; the capability is retired.
- `pool-sessions`: all requirements removed; the capability is retired.
- `pool-execs`: all requirements removed; the capability is retired.
- `sprite-transfers`: all requirements removed; the capability is retired.
- `projects`: deletion protection covers recipes and test reports only.
- `spry-recipes`: recipe names may start with `gfp-`.
- `spry-templates`: expanded sprite names and `sprite` overrides may start with `gfp-`.

## Impact

- **Code removed:** `GoodFlows.Pools` and everything under `lib/good_flows/pools/`, `GoodFlowsWeb.PoolSocket` and `SessionChannel`, the pool controllers, JSON views and OpenAPI schemas, the `PoolsEnabled` plug, and the `mix pools.destroy_members` task.
- **Code trimmed:**
  - `application.ex`: pool children, config validation, `prep_stop/1`.
  - `GoodFlows.Spry.Sprites`: checkpoint, restore, file write, collect, streaming and transfer functions.
  - Router, endpoint socket, fallback controller clauses, body parsers and API params.
  - Project deletion, and the `gfp-` checks in `Template`, `Recipe` and `Plan`.
- **Config:** pool keys in `config/runtime.exs`, `dev.exs`, `test.exs` and `.env.sample`; the PgFlow pool jobs; the `priv/gf-transfer` entry in `.gitignore`.
- **Tests:** pool test files, `ChannelCase`, `FakeSprite`, `FakeExec`, `TarFixtures`, pool fixtures, the `gf-transfer` fixture binaries, and the pool sections of shared tests, test helpers and `DataCase`.
- **Repo:** the `sprite-transfer/` crate and `docs/pool-protocol.md` are deleted. The archived `2026-11-01-add-sprite-pools` change is kept as history.
- **Databases:** local and worktree databases that ran the pool migration need `mix ecto.reset`. Pool member sprites (`gfp-*`) in a dev Sprites account should be destroyed before the code is removed.
- **Dependencies:** no Hex dependency is removed. `sprites` stays for Spry, and Phoenix channels are part of Phoenix.
