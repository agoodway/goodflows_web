# Tasks

## 1. Dependencies and configuration

- [ ] 1.1 Add `cloak_ecto` to `app/mix.exs`, create `GoodFlows.Vault` (AES-GCM) keyed from `CLOAK_KEY`, add it to the supervision tree, set a fixed test key in `config/test.exs` and a dev key, raise in prod `runtime.exs` when `CLOAK_KEY` is missing, and add `CLOAK_KEY` to `.env.sample`; verify `mix compile --warnings-as-errors` passes and the app boots in dev
- [ ] 1.2 Add `config :good_flows, GoodFlows.Spry` (`step_timeout_ms`, `output_limit_bytes`, `sprites_base_url`) with a short test timeout; verify `mix compile` passes

## 2. Templating

- [ ] 2.1 Implement `GoodFlows.Spry.Template.slug/1`, `scan/2` (allowed-name sets for name vs step lines), and `expand/2` (single-pass, unquoted, missing-value errors naming the placeholder); verify with `test/good_flows/spry/template_test.exs` covering every `spry-templates` scenario (slugs, `{{ branch }}`, `{{org}}`, non-recursive values, unquoted values)

## 3. Recipes

- [ ] 3.1 Add the `recipes` migration (account_id FK, `name`, four `{:array, :text}` columns defaulting to `[]`, unique `(account_id, name)`) and the `GoodFlows.Spry.Recipe` schema; verify `mix ecto.migrate` and `mix ecto.rollback` both succeed
- [ ] 3.2 Implement the recipe changeset per design D2 (raw-param validation of phase lists with `phase[index]` errors, the host-step message, `org` rejection, blank-name check, `Template.scan` on name and lines, `{{sprite}}` in name rejected, unique-name constraint); verify with `test/good_flows/spry/recipe_test.exs` covering the `spry-recipes` schema, host-step (map, number, null, nested list), blank-string, org, placeholder, and uniqueness scenarios
- [ ] 3.3 Add `GoodFlows.Spry` context functions `list_recipes/1`, `get_recipe/2`, `create_recipe/2`, `replace_recipe/3`, and `delete_recipe/2` (returning `{:error, :active_run}` once runs exist), all scoped by account; add a `spry_fixtures.ex` in `test/support/fixtures`; verify with context tests including cross-account `:not_found`
- [ ] 3.4 Add `RecipeController`, OpenApiSpex schemas (`Recipe`, `RecipeRequest`, `RecipeResponse`, `RecipeListResponse`), and routes split across the read and write pipelines (uncomment and populate the write scope in `router.ex`); verify with `test/good_flows_web/controllers/api/v1/recipe_controller_test.exs` covering CRUD, `422` bodies, `pk_` → `403` on writes, `pk_` reads, and the other-account `404`, and confirm the operations appear at `/api/v1/openapi`

## 4. Sprites credential

- [ ] 4.1 Add the `sprites_credentials` migration (unique `account_id`, encrypted `token` binary, `last4`) and the `GoodFlows.Spry.SpritesCredential` schema using a Cloak encrypted field with `redact: true`; verify a test that reads the raw column with `Repo.query!` and asserts it does not contain the plaintext token
- [ ] 4.2 Add context functions `get_credential_status/1`, `put_credential/2` (upsert), `delete_credential/1`, and an internal `fetch_token/1`; verify with context tests for set, replace, blank `422`, delete, and delete-when-missing
- [ ] 4.3 Add `SpritesCredentialController` (`GET`/`PUT`/`DELETE /sprites-credential`) with a status schema that has no token field; verify with controller tests for each `sprites-credential` scenario, including that no response body contains the token that `pk_` `PUT` returns `403`, and short tokens return `last4: null`

## 5. Sprites wrapper and planning

- [ ] 5.1 Implement `GoodFlows.Spry.Sprites` (`client/1`, `exists?/2`, `create/2`, `exec/3` via `bash -c` with `stderr_to_stdout` and the configured timeout, `destroy/2`), reducing SDK errors to `{:error, %{status, message}}` with no token; confirm the not-found shape of `Sprites.get_sprite/2` against the SDK source and record it in a moduledoc; verify a unit test using a stubbed `Sprites` module
- [ ] 5.2 Implement `GoodFlows.Spry.Plan.build/2` (phase and flag validation, name resolution with the `sprite` override, the `/` check suggesting `{{branch_slug}}`, expansion of every line in the phase) and `Plan.with_vm_state/2` (create, require-exists, and destroy rules per phase); verify with `test/good_flows/spry/plan_test.exs` covering every phase × exists/missing × `no_create`/`no_destroy` combination and the missing-input `422` cases

## 6. Runs

- [ ] 6.1 Add the `runs` migration (including the partial unique index on `(account_id, sprite_name) WHERE status IN ('queued','running')`) and the `run_steps` migration, with `Run` and `RunStep` schemas; verify migrate/rollback and a DataCase test showing a second active run for the same sprite raises the constraint error
- [ ] 6.2 Implement `Spry.dry_run/3` (credential check → `Plan.build` → `Sprites.exists?` → `Plan.with_vm_state`, or a `422` error); verify context tests with `Sprites` stubbed via Mimic for the setup, teardown, `no_destroy`, and "fails where the run would" dry-run scenarios, asserting no create, exec, or destroy calls
- [ ] 6.3 Implement `Spry.start_run/3` (credential check, `Plan.build`, then one transaction that inserts the queued run with its plan snapshot and calls `PgFlow.enqueue(RunJob, %{"run_id" => id})`, mapping the partial-index conflict to `{:error, {:conflict, active_run_id}}`); verify tests for `202`-path success, no credential, `409` against an active run, acceptance after a failed run, a different sprite being accepted, and queued plan snapshots remaining unchanged after recipe edits
- [ ] 6.4 Implement `GoodFlows.Spry.RunJob` (`max_attempts: 1`, a high timeout) per design D7: the conditional `queued → running` claim, existence check, step materialization, fail-fast execution, 64 KiB tail truncation, skipped remainder, rescue to `failed`. Register it in the PgFlow `jobs:` list in `runtime.exs`. Verify job tests via `RunJob.perform/2` with Mimic stubs for each `spry-runs` phase scenario (setup create/existing/`no_create`, start/stop missing and empty, teardown destroy/`no_destroy`/failed step/missing, middle-step failure, timeout, large output, duplicate delivery no-op, recipe edits after enqueue preserving commands, and credential replacement/deletion before claim plus replacement during execution preserving a single client)
- [ ] 6.5 Implement `GoodFlows.Spry.ReapRunsJob` (cron every 5 minutes) per design D8 and register it; verify tests that a stale `running` run and an old `queued` run become `failed` with an abandoned error, and that a new run for the same sprite is then accepted
- [ ] 6.6 Make `delete_recipe/2` return `{:error, :active_run}` → `409` when the recipe has a queued or running run; verify the recipe-delete `409` scenario and that completed runs remain retrievable by id after deleting their recipe in the controller test
- [ ] 6.7 Add `RunController` (`POST /recipes/:id/runs` returning `202` run or `200` plan, `GET /recipes/:id/runs` newest first without output, `GET /runs/:id` with steps), OpenApiSpex schemas (`RunRequest`, `Run`, `RunStep`, `RunPlan`, `ConflictResponse`), and `FallbackController` clauses for `:active_run` → `409`, `{:conflict, id}` → `409` and `{:unprocessable, detail}` → `422`; verify controller tests for each endpoint, `pk_` `POST` → `403`, `pk_` reads, other-account `404`, and that `/api/v1/openapi` validates with `OpenApiSpex.resolve_schema_modules`

## 7. Documentation and integration

- [ ] 7.1 Extend the `GoodFlowsWeb.ApiSpec` description with a "Spry" section (set the credential, create a recipe, start a run, poll it; host steps unsupported; step output is readable by any account key); verify it renders in Swagger UI at `/api/v1/docs`
- [ ] 7.2 Run an end-to-end check in dev with a real Sprites token: set the credential, create a recipe with one setup line and one teardown line, run a setup dry run, setup, start, and teardown, polling each to `succeeded`; confirm the VM was created and destroyed in the Sprites dashboard
- [ ] 7.3 Run `mix precommit` and verify it passes with no warnings, Credo, Dialyzer, or Sobelow findings
