# Design

## Context

See proposal.md for why. The GoodFlows app already provides what the API layer needs:

- **API auth**: `GoodFlowsWeb.Plugs.ApiAuth` assigns `current_account` from a Bearer key. The router has `:api_authenticated` (any key) and `:api_write` (`sk_` only) pipelines. The write scope is currently commented out.
- **OpenAPI**: `open_api_spex`. Operations are declared in controllers (`MeController` is the model), and `GoodFlowsWeb.ApiSpec` builds paths from the router.
- **Errors**: `FallbackController` renders changesets as `422` via `ChangesetJSON`, and `:not_found`/`:forbidden`/`:unauthorized` via `ErrorJSON` (`{"errors": {"detail": …}}`).
- **Jobs**: PgFlow runs on the same Postgres (pgmq). It is configured in `config/runtime.exs` with `jobs: []`; no jobs exist yet. `PgFlow.Job` jobs take `max_attempts` and `timeout` (seconds) options.
- **Sprites**: the `sprites` SDK (`Sprites.new(token)`, `get_sprite/2`, `create/3`, `cmd/4`, `destroy/1`) authenticates by token only. It has no org parameter.
- **Data**: binary_id primary keys; tables scoped by `account_id`.

The CLI behavior being reproduced comes from spry's `setup`, `app`, `teardown`, and `templates` specs. Where the web specs differ (rejecting host steps, validating everything up front, async runs), the web specs win.

## Goals / Non-Goals

**Goals:**

- A single `GoodFlows.Spry` context that owns recipes, the credential, runs, templating, and planning. Controllers stay thin.
- Planning (resolve name, expand lines, decide create/destroy) is pure and shared by dry runs, request validation, and the worker, so the three cannot drift.
- The one-active-run rule is enforced by the database, not by a check-then-insert in application code.
- Sprites calls go through one wrapper module so tests can stub them with Mimic and never hit the network.

**Non-Goals:**

- Streaming output while a step runs. Output is stored when the step ends.
- Resuming a run after a crash. A lost run fails; the caller starts a new one, and recipes are expected to be idempotent, as in the CLI.
- Recipe versioning or history.

## Decisions

### D1. Data model

```
recipes             id, account_id, name, setup[], start[], stop[], teardown[], timestamps
                    unique (account_id, name)
sprites_credentials id, account_id (unique), token (encrypted), last4, timestamps
runs                id, account_id, recipe_id, phase, sprite_name, inputs (map),
                    no_create, no_destroy, plan (map), status, error,
                    started_at, finished_at, timestamps
                    partial unique (account_id, sprite_name) WHERE status IN ('queued','running')
run_steps           id, run_id, index, kind (create|exec|destroy), command,
                    status (pending|running|succeeded|failed|skipped),
                    exit_code, reason, output, output_truncated, started_at, finished_at
```

Phase lists are `{:array, :text}`. A run stores its expanded `plan` (the expanded name and lines) when it is created, so editing or deleting a recipe while a run is queued cannot change what runs. `recipe_id` uses `on_delete: :nilify_all`. Deleting a recipe with an active run is rejected with `409` (spec) so normal deletes don't orphan live work.

*Alternative considered:* storing a recipe as one JSONB document. Rejected: four typed array columns validate more simply and read clearly in queries.

### D2. Recipe validation runs on raw params

`Ecto.Changeset.cast/3` would reject a `{host: …}` item with a generic "is invalid" and no item index. The changeset therefore validates each phase list from the raw params first. Every non-string item (including maps, numbers, nulls, and nested lists) gets "host steps are not supported by the API" and an error keyed by phase and index (e.g. `setup[2]`); blank strings get a distinct blank-item error at the same indexed field. Then it casts. Unknown placeholder syntax is checked in the same changeset using the template module (D4). Passing `org` is a changeset error rather than being silently dropped.

### D3. Credential encryption with Cloak

Add `cloak_ecto` with a `GoodFlows.Vault` (AES-GCM) keyed by a new `CLOAK_KEY` env var (base64, 32 bytes), required in prod and generated for dev and test. `last4` is stored in plaintext alongside the token for display; for tokens of four or fewer characters it is null so metadata never exposes the complete token.

*Alternative considered:* deriving a key from `SECRET_KEY_BASE` with `Plug.Crypto`. Rejected: rotating `SECRET_KEY_BASE` (a routine action) would silently make every stored token unreadable, and Cloak supports key rotation through its cipher list.

### D4. Templating is a port of spry's `template.rs`

`GoodFlows.Spry.Template` provides:

- `scan/2`: accepts a string and its allowed-name context (name or step), lists placeholders, and reports unknown ones. Used at save time and for run-time name overrides.
- `expand/2`: does a single-pass, non-recursive substitution against a map of resolved values. A missing value is an error naming the placeholder.
- `slug/1`: implements the branch-slug rule.

Allowed names depend on context: the name allows `branch`, `branch_slug`, `commit`, and `remote`; step lines additionally allow `sprite`.

### D5. Plan builder

`GoodFlows.Spry.Plan.build(recipe, params)` → `{:ok, plan} | {:error, reason}` is pure. It:

1. Validates the phase and flags.
2. Resolves the name template (the `sprite` override or the recipe name).
3. Expands it, rejecting a result containing `/`.
4. Expands every line in the requested phase.

The run endpoint calls it before inserting anything, so all placeholder errors come back as `422` and nothing executes (spec: Missing inputs fail before execution). This deliberately differs from the CLI, which fails at the offending line. On the web, every input is known when the request arrives.

`Plan.with_vm_state(plan, exists?)` adds the `create`/`destroy` actions and decides the outcomes that depend on whether the VM exists:

- Setup creates a missing VM unless `no_create` is set.
- Start, stop, and teardown require an existing VM.
- Teardown destroys unless `no_destroy` is set.

Dry run uses this to produce its response. The worker uses it to materialize `run_steps`.

### D6. Sprites wrapper

`GoodFlows.Spry.Sprites` wraps the SDK with four functions taking a client built from the account's token: `exists?/2`, `create/2`, `exec/3`, and `destroy/2`.

- `exists?` uses `Sprites.get_sprite/2` and maps a not-found error to `false`. That is cheaper than listing every sprite the way the CLI does. The not-found error shape must be confirmed against the SDK during implementation.
- `exec` calls `Sprites.cmd(sprite, "bash", ["-c", line], stderr_to_stdout: true, timeout: step_timeout)`. This matches the CLI, which runs lines through a shell via `sprite exec -c`.

Tests stub this module with Mimic, which is already a test dependency.

### D7. Run lifecycle on PgFlow

```
POST /api/v1/recipes/:id/runs --> Plan.build --> [credential?] --> Repo.transaction:
                                                  insert run(queued)   -- 409 on partial-unique conflict
                                                  PgFlow.enqueue(RunJob, %{run_id})
           <-- 202 run

RunJob(run_id):
  UPDATE runs SET status='running' WHERE id=? AND status='queued'   -- 0 rows -> no-op (duplicate delivery)
  fetch current credential once (missing -> fail before VM calls); keep client in memory
  exists? --> Plan.with_vm_state --> insert run_steps (pending)
  for step in steps: mark running -> call Sprites -> store exit/output -> stop on failure
  mark remaining skipped; run succeeded|failed
```

- Credential replacement/removal affects subsequent worker claims. An already claimed run keeps its one client for all operations; neither its token nor client is persisted in the plan or job payload. A dry run similarly uses one current credential/client for its read-only lookup.
- The run insert and the enqueue share one transaction because pgmq is in the same database. A run therefore never exists without its job, and vice versa.
- `RunJob` uses `max_attempts: 1`, because steps are not assumed idempotent and a retry would re-run side effects. Its job `timeout` is set high, to cover a long run. The conditional `queued → running` update is the guard against duplicate delivery.
- Step output is truncated to the last 64 KiB before it is written (`output_truncated`).
- Any exception in the worker is caught, so the run is marked `failed` with the error rather than left `running`.
- The `409` check is a race-free unique-constraint error on the partial index. The context maps it to `{:error, {:conflict, active_run_id}}`, and the controller renders it as `409` with the active run's id.

*Alternative considered:* `Task.Supervisor` with no queue. Rejected: runs would vanish without a trace on a deploy, and PgFlow is already the project's job system.

### D8. Abandoned-run reaper

A cron `PgFlow.Job` (`ReapRunsJob`, every 5 minutes) marks a run `failed` with "abandoned" in two cases:

- It is `running` and its newest step `started_at`, or its own `started_at`, is older than `step_timeout + 5 min`.
- It is `queued` and older than a generous threshold (1 hour).

Its running step becomes `failed` and its pending steps become `skipped`. This frees the partial unique index for that sprite.

### D9. API surface

Three controllers under `GoodFlowsWeb.Api.V1` (`RecipeController`, `RunController`, `SpritesCredentialController`), with OpenApiSpex schemas in `GoodFlowsWeb.Schemas`.

```
read  (:api_authenticated)          write (:api_authenticated, :api_write)
GET  /recipes                       POST   /recipes
GET  /recipes/:id                   PUT    /recipes/:id
GET  /recipes/:id/runs              DELETE /recipes/:id
GET  /runs/:id                      POST   /recipes/:id/runs   (202 run | 200 plan when dry_run)
GET  /sprites-credential            PUT    /sprites-credential
                                    DELETE /sprites-credential
```

- `FallbackController` gains `{:error, :active_run}` → `409` for recipe deletion, plus clauses for `{:error, {:conflict, run_id}}` → `409`, and `{:error, {:unprocessable, detail}}` → `422` for plan errors that aren't changeset errors.
- The `POST /api/v1/recipes/:id/runs` operation documents both `200` (plan) and `202` (run) responses.
- Records owned by another account are looked up scoped by `account_id` and return `:not_found`.

### D10. Configuration

`config :good_flows, GoodFlows.Spry, step_timeout_ms: 30 * 60_000, output_limit_bytes: 65_536, sprites_base_url: nil` (nil uses the SDK default). Tests lower the timeout.

## Risks / Trade-offs

- **[Risk] PgFlow's job `timeout` is a visibility timeout.** A run longer than it could make pgmq deliver the message again. → Mitigation: set it well above the expected run length. The `queued → running` guard makes a redelivery a no-op. With `max_attempts: 1` there are no retries to begin with.
- **[Risk] `Sprites.cmd` buffers all output in memory**, so a command producing hundreds of MB could balloon worker memory. → Mitigation: accept this for v1 (typical setup output is small) and note it. A later move to `Sprites.spawn` with a rolling 64 KiB buffer fixes it without an API change.
- **[Risk] Customer tokens are used server-side**, so a leak through logs or errors would be serious. → Mitigation: the token never appears in schemas' `inspect` (`redact: true`) or in run errors. Sprites SDK errors are reduced to a status and message before they're stored.
- **[Risk] Step lines can print secrets** into stored output that any `pk_` key can read. → Accepted. It matches what the CLI prints to the terminal. Document it in the API description.
- **[Trade-off] Validating every placeholder up front** rejects a recipe whose later lines need inputs that only an earlier step would produce. That isn't possible anyway, since inputs come only from the request.
- **[Trade-off] Using `get_sprite` instead of listing** for existence differs from the CLI's list-and-match, but its observable behavior is the same.

## Migration Plan

All changes add new tables, routes, and a dependency. Deploy steps:

1. Set `CLOAK_KEY` in production secrets.
2. Deploy. Migrations create the four tables, and the PgFlow job definitions are compiled.

Rollback: revert the deploy and drop the four tables. No existing data is touched.

## Open Questions

- Should `create` pass any Sprites config (region, size)? v1 uses the SDK defaults. A later recipe field can add it without changing these specs.
- What exact error does `Sprites.get_sprite/2` return for a missing sprite? This is confirmed while writing the wrapper (D6) and doesn't affect the API.
