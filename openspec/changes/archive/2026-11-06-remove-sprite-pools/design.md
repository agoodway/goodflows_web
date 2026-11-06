# Design

## Context

See proposal.md for why pools are being removed. Pool code is almost entirely in its own modules (`GoodFlows.Pools.*`, the pool controllers and schemas, `GoodFlowsWeb.PoolSocket` and `SessionChannel`, `sprite-transfer/`). It reaches into shared code in a small, known set of places:

```
 application.ex ----- 5 pool children, Reconciler, PoolsConfig.validate!, prep_stop/1
 endpoint.ex -------- socket "/api/v1/socket" (pool sessions only)
 router.ex ---------- :pools_enabled pipeline + pool scopes
 spry/sprites.ex ---- checkpoint / restore / write_file / collect /
                      spawn_streaming / transfer / *_stream (pool-only callers)
 spry/template.ex --- @reserved_prefix "gfp-"  <- recipe.ex, plan.ex
 projects(.ex) ------ has_many :pools, no_assoc_constraint, :has_pools
 fallback, body_parsers, api_params, api_spec -- pool clauses and text
 config/*.exs, .env.sample, .gitignore, mix.exs check alias
 test support ------- DataCase.stop_pool_processes, test_helper Mimic copies
                      and :helper_binary exclusion, ChannelCase, FakeSprite,
                      FakeExec, TarFixtures
```

Nothing else uses the socket, the Rust crate, or the pool tables. Every foreign key into a pool table comes from another pool table. Spry uses only `client`, `exists?`, `create`, `destroy`, `exec` and `error_message` from `GoodFlows.Spry.Sprites`. `GoodFlows.Leadership` is shared with `GoodFlows.Spry.ReaperScheduler`.

## Goals / Non-Goals

**Goals:**
- After the change, the app has no pool modules, routes, tables, processes, config keys, or tests. `mix check` passes without a Rust toolchain.
- `GoodFlows.Spry.Sprites` contains only what Spry calls, plus the private helpers those functions need.

**Non-Goals:**
- Changing Spry runs, recipes, test reports, or the Sprites credential beyond removing the `gfp-` check.
- Removing any Hex dependency. `sprites` stays for Spry.
- Rewriting the archived `2026-11-01-add-sprite-pools` change. It stays as history.

## Decisions

### Delete the migration instead of adding a drop migration

`20261102100000_create_sprite_pools.exs` is deleted, and no new migration is added. The user confirmed that it never ran on a database that must be kept. This keeps the schema history as if pools never existed.

*Alternative:* a `drop_sprite_pools` migration that drops `pool_execs`, `pool_sessions`, `pool_members` and `pools` in that order. That is the safe choice when deployment state is unknown, but here it would leave two migrations that cancel each other out.

*Consequence:* databases that already ran it keep the tables and the `schema_migrations` row. Developers reset them with `mix ecto.reset`, or run `mix ecto.rollback --to 20261102100000` before pulling the change.

### Remove the whole feature instead of leaving it off behind `PoolsEnabled`

The existing flag could hide the routes with no code change. The user chose removal for good, so the flag, the plug and the pipeline go too. Keeping dormant code would leave the supervision tree, config validation and the cargo build step in place for no benefit.

### Drop the `gfp-` reservation

The prefix only kept recipe and run sprite names from colliding with pool members. With pools gone, the rule blocks valid names for no reason. `reserved_prefix/0`, `reserved_sprite_name?/1` and `reserved_prefix_message/0` are deleted from `Template`, along with their callers in `Recipe` (name validation) and `Plan` (the override and expanded-name checks). The other sprite name checks are unchanged.

In the spec deltas, each affected requirement is REMOVED and replaced with an ADDED requirement under a new name. A MODIFIED block cannot drop scenarios, and each of these requirements loses its reserved-prefix scenarios. The same applies to the projects deletion requirement, which loses its two pool scenarios.

### Retire the four pool capabilities at archive

The deltas for `sprite-pools`, `pool-sessions`, `pool-execs` and `sprite-transfers` remove every requirement. The change's `.openspec.yaml` sets `retire_capabilities: true`, so archive deletes those main specs instead of leaving empty files.

### Trim `Sprites` to the Spry surface

The pool-only public functions are deleted: `create_checkpoint/3`, `restore_checkpoint/4`, `write_file/5`, `collect/4`, `spawn_streaming/6`, `transfer/5`, `write_stream/3`, `close_stream_stdin/2` and `stop_stream/1`. Private helpers that only those functions call, the `TransferProtocol` alias, and the pool moduledoc and typedoc text go too. `tail/2` is deleted as well. Production Spry does not call it; `sprites_test.exs` and `run_job_test.exs` do, and those tests are updated in the same step.

`bounded/3`, `safely/2`, and the await and guard helpers stay, because `exists?`, `create`, `destroy` and `exec` go through `bounded/3`. The private `collect/6` stays because `exec` calls it. `finish_output/3` and `drop_continuation_bytes/2` stay too: `tail/2` only wraps `finish_output/3`, and `collect/6` calls both. The compiler's unused-function warnings (`--warnings-as-errors`) are the final check on what remains. If checkpoints are ever needed for Spry, they can be restored from git.

### Keep project deletion protection for recipes and test reports

`Project` loses `has_many :pools` and its `no_assoc_constraint`. `delete_project/2` loses the `:has_pools` branch from its result type and docs, and `FallbackController` loses the `:has_pools`, `:pool_in_use`, and `:draining` clauses. Only `GoodFlows.Pools.Sessions` returns `{:error, :draining}`. The `:admission_contended` clause stays, because Spry returns that error.

## Risks / Trade-offs

- **Pool member sprites left in a Sprites account** → Before removing the code, run `mix pools.destroy_members` against any dev database that provisioned members, or delete `gfp-*` sprites by hand. After this change, nothing in the app will clean them up.
- **A shared helper is deleted with the pool code** → Deleting `Sprites` functions one at a time could miss a shared private helper. Compile with `--warnings-as-errors`, run the Spry and Sprites tests, then run `mix check`.
- **Unexpected callers of the socket or pool routes** → None exist in this repo, and `goodci` never shipped a remote client. Any leftover caller gets `404` or a failed socket connect.
- **A shared test still covers pool behavior** → Some pool assertions live in shared tests (OpenAPI, project, run, recipe, template, runtime config, migration, require-parsed-body). These are listed in tasks. Afterward, search `app/`, `docs/` and the README for `pool`, `gfp-`, `gf-transfer` and `sprite-transfer`. Hits for the Ecto `POOL_SIZE` and the reporting `spool` are expected.

## Migration Plan

1. In any dev database that has pool members, destroy them (`mix pools.destroy_members`), then roll back past `20261102100000` or plan to run `mix ecto.reset`.
2. Merge the change.
3. Developers run `mix ecto.reset` in each local and worktree database.

Rollback is a git revert. It restores the migration file, so `mix ecto.migrate` recreates the tables.
