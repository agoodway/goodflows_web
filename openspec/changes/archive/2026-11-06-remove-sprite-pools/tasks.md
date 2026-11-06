# Tasks

Paths are relative to `app/` unless they start with `../`.

## 1. Preflight

- [x] 1.1 In each dev database that has pool rows, destroy their member sprites with `mix pools.destroy_members POOL_ID` for each pool. Verify with `SELECT count(*) FROM pool_members` (it should be 0), and check that the dev Sprites account lists no `gfp-*` sprites.
- [x] 1.2 Roll each local and worktree database back past the pool migration with `mix ecto.rollback --to 20261102100000`, or note that it will need `mix ecto.reset`. Verify that `mix ecto.migrations` shows `20261102100000` as `down`, or that a reset is planned.

Preflight evidence (2026-11-06): `git worktree list` lists only this checkout.
`good_flows_dev` and `good_flows_test` each contain zero pools, members,
sessions and execs; the development database has zero Sprites credentials.
The available Sprites account's SDK `Sprites.list(client, prefix: "gfp-")`
returned `{:ok, []}`. No remote writes were performed. Rollback on the dev
database stopped at the later irreversible `20261105100000` report purge,
without reverting any migration. Both existing databases will need an
owner-approved `mix ecto.reset`; they are preserved here. Reset and full-gate
validation use the isolated disposable development and test databases selected
by `BRANCH_DB=remove_pools_setup` instead.

## 2. Remove the pool web layer

- [x] 2.1 Delete `lib/good_flows_web/channels/` (`pool_socket.ex`, `session_channel.ex`), and remove the `socket "/api/v1/socket"` block and the pool comment from `lib/good_flows_web/endpoint.ex`. Verify `mix compile --warnings-as-errors` passes.
- [x] 2.2 Delete the six pool controllers and JSON views under `lib/good_flows_web/controllers/api/v1/` (`pool_*.ex`) and `lib/good_flows_web/plugs/pools_enabled.ex`. Remove the `:pools_enabled` pipeline and every pool scope from `lib/good_flows_web/router.ex`. Verify `mix phx.routes | grep -i pool` prints nothing.
- [x] 2.3 Delete the nine pool OpenAPI schemas under `lib/good_flows_web/schemas/` (`pool*.ex`). Remove the "Sprite pools" section and the pool wording in the delete-project text from `lib/good_flows_web/api_spec.ex`. Verify the OpenAPI test passes and the generated spec has no `pool` paths or schemas.
- [x] 2.4 Remove `pool/0` and `pools_disabled/0` from `lib/good_flows_web/api_params.ex`, and the `:has_pools`, `:pool_in_use`, and `:draining` clauses from `controllers/fallback_controller.ex`. Keep the `:admission_contended` clause; Spry returns that error, and only `GoodFlows.Pools.Sessions` returns `:draining`. Remove `workspace_upload?/1` and its use from `plugs/body_parsers.ex`, and rewrite that moduledoc so it describes only the test-report raw body route. Fix the "or pools" docs and 409 text in `controllers/api/v1/project_controller.ex`. Verify the fallback, body-parser and test-report upload tests pass.
- [x] 2.5 Delete the pool web tests: `test/good_flows_web/channels/`, `controllers/api/v1/pool_controller_test.exs`, `pool_session_controller_test.exs`, `pool_report_controller_test.exs`, `pool_protocol_doc_test.exs`, `pool_redaction_test.exs`, `pools_end_to_end_test.exs`, and `test/support/channel_case.ex`. Remove the pool cases from `openapi_test.exs` (around lines 39-45) and `plugs/require_parsed_body_test.exs` (around lines 14-29). Verify `mix test test/good_flows_web` passes.
- [x] 2.6 Delete `../docs/pool-protocol.md`. Remove pool wording from the doc comments in `plugs/require_parsed_body.ex`, `raw_body_headers.ex` and `sentry_scrubber.ex`, and from the raw-body comment in `endpoint.ex` (around lines 60-61; task 2.1 removes only the socket comment). Verify `grep -rni pool ../docs lib/good_flows_web` has no hits about sprite pools. `test_report_admission.ex` mentioning Ecto `pool_size` is expected.

## 3. Remove the pool core and data model

- [x] 3.1 In `lib/good_flows/application.ex`, remove the `PoolsConfig` alias and `validate!()` call, the five pool children (`ShutdownDrain`, `Spool`, `TransferSemaphore`, `CoordinatorSupervisor`, `ExecSupervisor`), `GoodFlows.Pools.Reconciler`, and `prep_stop/1`. Verify the app boots with `mix run -e 'IO.puts(:ok)'`.
- [x] 3.2 Remove the pool PgFlow jobs and worker options and the `GoodFlows.Pools` block from `config/runtime.exs`, along with the prod `fingerprint_secret`/`require_helper_manifest` lines. Remove the pool keys from `config/dev.exs` and `config/test.exs`, and the pool variables from `.env.sample` (keep `POOL_SIZE`). Delete the pool cases in `test/good_flows/runtime_config_test.exs` (around lines 34-98). Verify `grep -n -i "pools\|gf_transfer\|POOL_" config .env.sample` returns only `POOL_SIZE`, Ecto `pool_size`, and the stock DBConnection comment in `config/runtime.exs` about multiple pools of `pool_size`, and that the runtime config test passes.
- [x] 3.3 Delete `lib/good_flows/pools.ex`, `lib/good_flows/pools/`, and `lib/mix/tasks/pools.destroy_members.ex`. Verify `mix compile --warnings-as-errors` passes.
- [x] 3.4 Remove `has_many :pools`, the `no_assoc_constraint(:pools, ...)` and the pool docs from `lib/good_flows/projects/project.ex`. Remove the `:has_pools` branch, its spec type and its docs from `delete_project/2` in `lib/good_flows/projects.ex`. Delete the pool deletion test in `project_controller_test.exs` (around lines 130-145). Verify the projects and project controller tests pass, including the 204/409 cases for recipes and test reports.
- [x] 3.5 Delete `priv/repo/migrations/20261102100000_create_sprite_pools.exs` and `test/good_flows/migrations/create_sprite_pools_migration_test.exs`. Remove the pool parts of `create_projects_migration_test.exs` (around lines 16-28, 67 and 101-102). Verify `mix ecto.reset && mix test test/good_flows/migrations` passes and `\dt pool*` in `psql` lists nothing.
- [x] 3.6 Delete the pool core tests: `test/good_flows/pools/`, `test/good_flows/pools_test.exs`, `test/mix/tasks/pools_destroy_members_test.exs`, `test/support/fixtures/pools_fixtures.ex`, `test/support/fake_sprite.ex`, `test/support/fake_exec.ex`, `test/support/fixtures/tar_fixtures.ex`, and `test/support/fixtures/gf-transfer/`. Remove `stop_pool_processes` and its setup from `test/support/data_case.ex`. In `test/test_helper.exs`, remove the `Pools` Mimic copies and the `:helper_binary` exclusion. Leave the `Sprites.Checkpoint` and `Sprites.Filesystem` copies until task 4.2: `sprites_test.exs` still stubs them, and it still aliases `GoodFlows.Pools.TransferProtocol`, so a full `mix test` cannot pass yet. Verify `mix compile --warnings-as-errors` passes and `test_helper.exs` no longer mentions `Pools` or `helper_binary`.
- [x] 3.7 Remove the pool references from the doc comments in `lib/good_flows/changeset_errors.ex` and `lib/good_flows/leadership.ex`. `Leadership` stays because `ReaperScheduler` uses it. Verify `grep -rn "Pools" lib` prints nothing. `test/` still mentions `Pools` until task 4.2.

## 4. Trim `GoodFlows.Spry.Sprites`

- [x] 4.1 Delete `create_checkpoint/3`, `restore_checkpoint/4`, `write_file/5`, `collect/4`, `spawn_streaming/6`, `transfer/5`, `write_stream/3`, `close_stream_stdin/2`, `stop_stream/1` and `tail/2`, with the private helpers that only those functions call, the `TransferProtocol` alias, and the pool moduledoc and typedoc text. Keep `bounded`, `safely`, the await and guard helpers, the private `collect/6` that `exec` calls, and `finish_output/3` and `drop_continuation_bytes/2` (`collect/6` calls them; `tail/2` only wraps `finish_output/3`). Verify `mix compile --warnings-as-errors` reports no unused functions.
- [x] 4.2 Delete the checkpoint, restore, write-file, collect, streaming, transfer, and `tail/2` describes from `test/good_flows/spry/sprites_test.exs`. In `test/good_flows/spry/run_job_test.exs` (around line 419), stop calling `Wrapper.tail/2` and build the truncated output inline in the exec stub. In `test/test_helper.exs`, remove the `Sprites.Checkpoint` and `Sprites.Filesystem` `Mimic.copy` lines. Verify `mix test test/good_flows/spry` passes and `grep -rn "Pools" test` prints nothing.

## 5. Drop the `gfp-` reservation

- [x] 5.1 Remove `@reserved_prefix`, `reserved_prefix/0`, `reserved_sprite_name?/1` and `reserved_prefix_message/0` from `lib/good_flows/spry/template.ex`, along with the callers in `recipe.ex` (name validation) and `plan.ex` (the override and expanded-name checks). Verify `mix compile --warnings-as-errors` passes.
- [x] 5.2 Replace the reserved-prefix tests in `template_test.exs` (around lines 106-112), `recipe_controller_test.exs` (around lines 89-93) and `run_controller_test.exs` (around lines 231-266) with tests showing that a `gfp-app` recipe name returns `201`, a `{{branch_slug}}-app` name with branch `gfp` expands to `gfp-app`, and a `sprite` override of `gfp-demo` is accepted. These cover the new spry-recipes and spry-templates requirements. Verify those tests pass.

## 6. Remove the transfer helper and build wiring

- [x] 6.1 Delete `../sprite-transfer/`, remove the `cargo build` step and its comment from the `check` alias in `mix.exs`, and remove the `priv/gf-transfer` lines from `.gitignore`. Delete `priv/gf-transfer/` locally if it exists. Verify `mix help check` no longer lists cargo.
- [x] 6.2 Remove the "package the transfer helper" section from `README.md` (around lines 12-33). Verify `grep -n -i "gf-transfer\|sprite-transfer\|package.sh" README.md` prints nothing.

## 7. Integration check

- [x] 7.1 Run `mix ecto.reset && mix check` in `app/` on a machine without `cargo` on `PATH`. Verify it passes: compile, credo, dialyzer, sobelow and the full test suite including `:slow`.
- [x] 7.2 Search `app/`, `../docs` and the README for `pool`, `gfp-`, `gf-transfer` and `sprite-transfer`, and check every hit. Verify the only hits left are Ecto `POOL_SIZE`/`pool_size`, the reporting `spool`, the `gfp-` acceptance tests, and unrelated library text.
- [x] 7.3 Run `openspec validate remove-sprite-pools --strict` from the repo root. Verify it reports the change as valid. Archive will then retire `sprite-pools`, `pool-sessions`, `pool-execs` and `sprite-transfers` (`retire_capabilities: true`), and the purpose of `openspec/specs/projects/spec.md` must be edited to drop "and sprite pools" and "or pools".

Integration evidence (2026-11-06): with `BRANCH_DB=remove_pools_setup` and a
PATH explicitly excluding Cargo, `mix precommit` and the final
`mix ecto.reset && mix check` both passed: 735 tests, zero failures, including
`:slow`; Dialyzer reported zero errors and Credo found no issues. Both fresh
validation databases have no pool tables. The generated OpenAPI has no pool
paths or schemas, and direct endpoint calls to the removed pool, session,
workspace, report and socket URLs all returned 404. The reference audit found
only Ecto connection settings, dependency text and `gfp-` acceptance tests.
Strict OpenSpec validation passed. Archive and main-spec retirement are left
for the separate archive stage.
