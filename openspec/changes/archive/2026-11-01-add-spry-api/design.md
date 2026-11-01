# Design

## Context

See proposal.md for why. The GoodFlows app already provides what the API layer needs:

- **API auth**: `GoodFlowsWeb.Plugs.ApiAuth` assigns `current_account` from a Bearer key. The router has `:api_authenticated` (any key) and `:api_write` (`sk_` only) pipelines. The write scope is currently commented out.
- **OpenAPI**: `open_api_spex`. Operations are declared in controllers (`MeController` is the model), and `GoodFlowsWeb.ApiSpec` builds paths from the router.
- **Errors**: `FallbackController` renders changesets as `422` via `ChangesetJSON`, and `:not_found`/`:forbidden`/`:unauthorized` via `ErrorJSON` (`{"errors": {"detail": …}}`).
- **Jobs**: PgFlow runs on the same Postgres (pgmq). It is configured in `config/runtime.exs` with `jobs: []`; no jobs exist yet. `PgFlow.Job` jobs take `max_attempts` and `timeout` (seconds) options.
- **Sprites**: the `sprites` SDK (`Sprites.new(token)`, `get_sprite/2`, `create/3`, `spawn/4`, `destroy/1`) authenticates by token only. It has no org parameter.
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
                    owner_id, pgflow_run_id, started_at, action_started_at,
                    finished_at, reaper_checked_at,
                    started_by_api_key_id (FK api_keys, nilify on delete), timestamps
                    partial unique (account_id, sprite_name) WHERE status IN ('queued','running')
                    partial (status, inserted_at) WHERE status = 'queued'
                    partial (reaper_checked_at NULLS FIRST, action_started_at, id)
                      WHERE status = 'running'
run_steps           id, run_id, index, kind (create|exec|destroy), command,
                    status (pending|running|succeeded|failed|skipped),
                    exit_code, reason, output, output_truncated, started_at, finished_at,
                    timestamps
                    partial (finished_at) WHERE output IS NOT NULL   -- output retention
```

`runs.action_started_at` is refreshed by every ownership-conditional worker write (claim, lookup, each step start and finish), so it records when the current action began; the reaper (D8) uses it as its per-action staleness signal. `runs.reaper_checked_at` records the reaper's last investigation of a run it did not finalize (D8). `runs.started_by_api_key_id` records the API key that admitted the run, for audit; it is rendered in run responses and becomes null when the key is deleted. The partial indexes match the reaper's two queries. `timestamps` are `inserted_at`/`updated_at` (`utc_datetime_usec`) on every table.

The recipe `name` is the sprite name template, and it is unique per account (`unique (account_id, name)`). This is deliberate: there is no separate display-name field, so a recipe is identified by the sprites it drives, and two recipes of an account can never share a template. Clients that want a label keep it out of band.

Phase lists are `{:array, :text}`. A run stores its expanded `plan` (the expanded name and lines) when it is created, so editing or deleting a recipe while a run is queued cannot change what runs. `recipe_id` uses `on_delete: :nilify_all`. Deleting a recipe with an active run is rejected with `409` (spec) so normal deletes don't orphan live work.

*Alternative considered:* storing a recipe as one JSONB document. Rejected: four typed array columns validate more simply and read clearly in queries.

### D2. Recipe validation runs on raw params

`Ecto.Changeset.cast/3` would reject a `{host: …}` item with a generic "is invalid" and no item index. The changeset therefore validates each phase list from the raw params first. Every non-string item (including maps, numbers, nulls, and nested lists) gets "host steps are not supported by the API" and an error keyed by phase and index (e.g. `setup[2]`); blank strings get a distinct blank-item error at the same indexed field. Indexed error keys are strings (`"setup[2]"`), not atoms: `traverse_errors/2` and the JSON error body treat them exactly like atom keys, and request data never creates atoms (so no Sobelow `DOS.StringToAtom` skip is needed). Each phase list holds at most 500 items (`maxItems: 500` in `RecipeRequest`); a longer list is a phase-level error. Each item holds at most 10,000 characters (an indexed error) and `name` at most 255, so oversized input is a `422` rather than a database error. The name's literal text must be able to form a valid sprite name (`Template.valid_name_template?/1`: each placeholder counts as one valid character, and the result must match the sprite-name rule in D5), so names such as `App`, `a..b`, or `-app` are rejected on save. Because `PUT` is a full replacement, `name` is cast from the request even when absent, so omitting it is a `422` rather than keeping the old name. Then it casts. Unknown placeholder syntax is checked in the same changeset using the template module (D4). Passing `org` is a changeset error rather than being silently dropped.

### D3. Credential encryption with Cloak

Add `cloak_ecto` with a `GoodFlows.Vault` (AES-GCM) keyed by a new `CLOAK_KEY` env var (base64, 32 bytes), required in prod, persistently configured for dev, and fixed for test. `last4` is stored in plaintext alongside the token for display; for tokens of four or fewer characters it is null so metadata never exposes the complete token.

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
3. Expands it, rejecting a result containing `/` (suggesting `{{branch_slug}}`) and any result that does not match `^[a-z0-9][a-z0-9-]{0,62}$`. The rule is lowercase-only, so names that differ only by case (or by characters the slug keeps, such as `.` and `_`) can never alias the same VM; `{{branch_slug}}` keeps case, so an uppercase branch is a `422`, not a silently lowercased name.
4. Expands every line in the requested phase.

Inputs are substituted unquoted into shell lines (D4), so step 1 also validates each input's character set and length: `branch` and `commit` must match `^[A-Za-z0-9][A-Za-z0-9._/+-]*$` (at most 255 characters), `remote` `^[A-Za-z0-9][A-Za-z0-9._:/@%+-]*$` (at most 1024), and the `sprite` override at most 255 characters with literal text that can form a valid name. Requiring a leading letter or digit means no input can be read as a command-line option, and none can contain shell metacharacters, whitespace, or quotes. A violation is a `422` on that field. Recipes should prefer `{{branch_slug}}` over `{{branch}}` wherever a value reaches a name or a path.

The run endpoint calls it before inserting anything, so all placeholder errors come back as `422` and nothing executes (spec: Missing inputs fail before execution). This deliberately differs from the CLI, which fails at the offending line. On the web, every input is known when the request arrives.

`Plan.with_vm_state(plan, exists?)` adds the `create`/`destroy` actions and decides the outcomes that depend on whether the VM exists:

- Setup creates a missing VM unless `no_create` is set.
- Start, stop, and teardown require an existing VM.
- Teardown destroys unless `no_destroy` is set.

Dry run uses this to produce its response. The worker uses it to materialize `run_steps`.

### D6. Sprites wrapper

`GoodFlows.Spry.Sprites` wraps the SDK with four functions taking a client built from the account's token plus an options list (`:timeout`, and `:output_limit` for exec): `exists?/3`, `create/3`, `exec/4`, and `destroy/3`.

- `exists?` uses `Sprites.get_sprite/2` and maps a not-found error to `false`. That is cheaper than listing every sprite the way the CLI does. The installed SDK returns `{:error, {:not_found, body}}` (`app/deps/sprites/lib/sprites/client.ex:129-137`). Only this result means absent; authentication, transport, and other API errors remain errors.
- `exec` calls `Sprites.spawn(sprite, "bash", ["-c", line], stderr_to_stdout: true)` inside a wrapper-owned supervised task and collects the command's output messages itself. This matches the CLI shell behavior. Output goes into a bounded rolling buffer: once it exceeds twice the output limit it is cut back to the last `output_limit_bytes`, so worker memory stays bounded however much a command prints, and the final tail is trimmed to the limit with `output_truncated` set. The SDK's own `cmd` timeout resets after each output message (`app/deps/sprites/lib/sprites/command.ex:601-621`), which makes it only an inactivity timeout, so it is not used; the wrapper's wall-clock deadline below is the only exec timeout.
- The wrapper enforces an independent monotonic elapsed-time deadline for every create/exec/destroy action and the existence lookup, capped by the remaining total-run budget. On expiry it stops and monitors the local task and associated SDK command processes, returning a normalized timeout without allowing subsequent steps. Tests must cover continuous output exceeding the deadline. This bounds local execution; the SDK does not establish termination of a remote shell after disconnect. A timed-out remote command may continue, and the API must document this limitation rather than promise remote cancellation.

Tests stub this module with Mimic, which is already a test dependency.

### D7. Run lifecycle on PgFlow

```
POST /api/v1/recipes/:id/runs --> Plan.build --> plan.dry_run? --yes--> [credential?] --> exists? (15 s) --> 200 plan
                                                    |no
                                                    v
                                               [credential?] --> Repo.transaction:
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

- `Spry.request_run/4` is the only entry point for both dry runs and real runs (there are no separate `dry_run`/`start_run` functions that could drift). It validates with `Plan.build/2` first (pure), so request errors (for example an invalid phase) are reported before a missing credential, for both dry runs and real runs. It then decides between dry run and admission only from the plan's cast `dry_run` value (Ecto `:boolean`, so `true`, `"true"`, and `"1"` all mean dry run); the controller never re-reads the raw parameter. The dry-run existence lookup runs inside the HTTP request, so it uses a fixed 15-second timeout instead of the 30-minute step timeout. A dry run requires a private (`sk_`) key like a real run: it is read-only, but it decrypts the account's stored Sprites credential and spends it on a provider call, which a read-only public key must not be able to trigger.
- The controller passes the authenticated key's id as `started_by_api_key_id`, stored on the admitted run.
- Credential replacement/removal affects subsequent worker claims. An already claimed run keeps its one client for all operations; neither its token nor client is persisted in the plan or job payload. A dry run similarly uses one current credential/client for its read-only lookup.
- The run insert and the enqueue share one `GoodFlows.Repo` transaction because PgFlow uses that repo. Explicitly roll back on every `PgFlow.enqueue/2` error, including `{:flow_not_compiled, slug}`; merely returning an error tuple would commit. Every enqueue failure is logged at error level with the (rolled-back) run id and the reason, and rendered as `503`. A run therefore never exists without its job, and vice versa. Integration tests compile the job definitions without starting background test workers.
- `RunJob` gets an explicit per-node `max_concurrency` in PgFlow's `worker_options` (`SPRY_RUN_MAX_CONCURRENCY`, default 10) and `ReapRunsJob` a concurrency of 1. Runs beyond that capacity stay `queued` with a pending PgFlow job; D8 never fails them for waiting.
- `RunJob` uses `max_attempts: 1`, because steps are not assumed idempotent and a retry would re-run side effects. The wrapper enforces `run_timeout_ms` (default 6 hours) from claim time, including lookups and all actions. Each action receives the smaller of its step timeout and the remaining run budget. On budget exhaustion, fail the run with `run_timeout`, fail any in-progress step, and skip pending steps.
- PgFlow's configured job timeout is a hard task execution limit, not just a queue visibility limit. Set it to at least the total-run budget plus 5 minutes for cleanup/finalization (default 21,900 seconds); startup must reject incompatible configuration. The conditional `queued → running` update guards duplicate delivery.
- Step output is truncated to the last 64 KiB before it is written (`output_truncated`).
- Catchable worker failures mark the run `failed`: everything after the claim, including the credential fetch and its decryption, runs under `rescue` plus `catch` for exits (for example a timed-out `GenServer.call`) and throws, with the token scrubbed from the stored message. External task termination, node loss, or PgFlow hard timeouts can bypass rescue; D8 handles these after verifying ownership has ended. Worker updates must be conditional on the current owner and `running` status, so they cannot overwrite a terminal result.
- The `409` check uses the partial unique index; only a unique-constraint error naming `runs_one_active_per_sprite_index` counts as a conflict, and any other changeset error is returned as a `422`. After that constraint error, first roll back the failed transaction (or its savepoint), then look up the account-scoped active run and return `{:error, {:conflict, active_run_id}}`. If that run has already finished, retry admission (up to 5 attempts); each conflict lookup must happen outside an aborted transaction. A `409` always names the active run (`active_run_id` is non-nullable): if every attempt conflicts with a run that finishes before it can be looked up, admission returns `{:error, :admission_contended}`, rendered as a retryable `503` with `Retry-After`, never a `409` with a null id. Concurrent-insert tests cover this race.
- Run admission and recipe deletion both acquire `FOR UPDATE` on the account-scoped recipe row inside their transactions, and re-read after locking; admission rebuilds its plan from that locked recipe. Persist the execution id returned by enqueue on the run within the same transaction. Deletion checks for active runs under this lock. If admission wins, deletion returns `409`; if deletion wins, admission returns `404`.

*Alternative considered:* `Task.Supervisor` with no queue. Rejected: runs would vanish without a trace on a deploy, and PgFlow is already the project's job system.

### D8. Abandoned-run reaper

A `PgFlow.Job` (`ReapRunsJob`, every 5 minutes) investigates running runs whose current action exceeds its deadline plus 5 minutes, or whose total-run budget plus 5 minutes has expired. Age is a candidate signal, never sufficient proof that ownership ended.

- Scheduling: PgFlow cron jobs need `pg_cron`, which is not available in every database this app runs against, so `GoodFlows.Spry.ReaperScheduler` enqueues the job from the app. Every node starts a scheduler, but only the holder of a cluster-wide `:global` leader name enqueues; on each tick a scheduler claims the name if it is free, so when the leader's node goes away another node takes over on its next tick. A healed netsplit with two leaders unregisters both (`:global.random_notify_name/3`) and the next tick re-elects one. Sweeps stay idempotent, so a rare overlap during handover is harmless.
- Sweep bounds: candidates are investigated concurrently (`Task.async_stream`, at most 10 at a time, each bounded to 20 seconds, overridable per sweep for tests, and treated as retained on timeout), and a sweep takes at most 50 running candidates. The worst case (5 rounds of 20 seconds) stays well inside the 300-second `ReapRunsJob` timeout; remaining candidates wait for the next sweep. A run that is investigated but not finalized is stamped with `reaper_checked_at`, and candidates are ordered `reaper_checked_at NULLS FIRST`, then oldest action, so never-checked runs always come before re-checks and a backlog of retained runs cannot starve newer candidates. Queued candidates (at most 200 per sweep) rotate the same way.
- The claim records an opaque owner identifier tied to the supervised execution process and its PgFlow execution id. An application-owned execution registry/supervisor provides owner lookup and stop-and-confirm behavior; do not assume PgFlow exports per-task cancellation.
- Corroborate candidates with PgFlow execution state and the recorded owner. For a reachable live owner, request termination of its supervised execution and local SDK tasks and confirm their termination before finalizing. A failed/completed PgFlow row alone does not prove its old owner is dead.
- If owner death cannot be established (including an unreachable node), retain the active guard and retry investigation, until the bounded fallback below. Before that deadline, operations must establish node termination or restore contact before clearing such runs. Availability yields to preventing a second live local executor.
- Owner ids have the form `"<node>|<boot_id>|<uuid>"`. `boot_id` is random per VM boot (kept in `:persistent_term`), and the node is recovered with `String.to_existing_atom/1` (owner ids never create atoms). An owner is local only when both its node and its boot id match this VM; an id naming this node with another boot (a previous incarnation, or another undistributed instance, since every undistributed VM is `:nonode@nohost`) cannot be asked and is retained as `:foreign_boot`, so non-clustered instances never finalize each other's live runs. Remote owners are asked on their node with `:erpc`; a node that restarted under the same name reports `:not_running` for the old boot's id.
- Node names must be distributed, stable, and unique: `rel/env.sh.eex` sets `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=good_flows@<RELEASE_HOST or hostname -f>` unless overridden (documented in `.env.sample`), and in production `GoodFlows.Spry.Config.validate!/0` refuses to start PgFlow workers on `:nonode@nohost` (`require_named_node`, set in `runtime.exs` for prod only, so dev and test are unaffected).
- Bounded fallback: an owner that cannot be asked (`:unknown_owner_node`, `:foreign_boot`, or an unreachable node) retains the guard only until `started_at` plus the PgFlow hard job timeout plus the 5-minute overhead (`Config.owner_deadline_ms/0`, about 6 hours 10 minutes by default). By then the owner's own node has hard-killed its PgFlow task and the worker's run budget has expired, so the reaper treats it as terminated and finalizes the run (logging why). Should a stale worker survive anyway, it is fenced: every worker write, and therefore every next VM action, is conditional on its owner id and `running` status. A reachable owner whose kill is not confirmed (`{:error, :not_confirmed}`) is never released by this fallback. Runs from before a node-name change are therefore released automatically after the deadline instead of being retained forever.
- The operator path is `GoodFlows.Spry.force_abandon(run_id)` (delegating to `Reaper.force_abandon/1`), available as `mix spry.force_abandon RUN_ID` or, in a release, `bin/good_flows rpc 'GoodFlows.Spry.force_abandon("RUN_ID")'` (which runs inside the live node and can reach owners on connected nodes). The mix task does not boot the application: it uses `@requirements ["app.config"]` and starts only Postgrex/Ecto, the repo, the execution registry, and token redaction, so it never starts PgFlow workers or the endpoint. `force_abandon` intentionally overrides the reaper's confirmation rule: it still stops a reachable live owner first, but if that owner's termination cannot be confirmed it finalizes anyway and logs a warning that a live owner may still be running its current VM action (fenced from further run writes). It then runs the same conditional finalization as the reaper (only a `running` run under the owner it read is changed), with an error stating that an operator released it. It is not exposed over the API, and must only be used after establishing that the old owner is gone.
- Every worker action checks ownership and `running` status before issuing its next VM operation, and all completion/failure writes are conditional. Reaper finalization atomically changes only the matching `running` owner to `failed`, fails its running step, and skips pending steps. It cannot overwrite a completed run, and a late worker cannot overwrite abandonment.
- Queued runs older than `queued_reap_after_ms` (default the run budget plus 5 minutes, so never less than the time a run ahead of it may legitimately take) are checked against their PgFlow job with `PgFlow.get_run/1`. A pending (`started`) job means the run is waiting for worker capacity and it stays queued; only a missing or terminal (`completed`/`failed`) job fails the run, with an abandonment error, through a conditional `queued → failed` update. That update races safely with the worker's `queued → running` claim: only one succeeds, and a late delivery of a failed queued run performs no VM operations. An unreadable job state leaves the run for the next sweep.
- Output retention: the same sweep clears `run_steps.output` for steps finished longer ago than `output_retention_ms` (default 30 days), at most 5,000 steps per sweep, keeping the steps themselves.
- Shutdown drain: `GoodFlows.Spry.ShutdownDrain` traps exits and is started after the repo and execution registry but before PgFlow, so it terminates after PgFlow's workers. Its `terminate/2` stops every execution still registered by this boot and finalizes every `running` run whose owner id has this node and boot as `failed` with "interrupted by server shutdown" (the same owner-conditional finalization). Crashes without an orderly shutdown are still recovered by the reaper.

Release the partial-index guard only after these conditions hold. Already-issued remote commands may outlive a disconnected client as described in D6; this is a known remote-execution limitation, not a guarantee of remote cancellation.

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

- `FallbackController` gains `{:error, :active_run}` → `409` for recipe deletion, plus clauses for `{:error, {:conflict, run_id}}` → `409` (always with a non-null `active_run_id`), `{:error, :admission_contended}` → `503` with `Retry-After`, and `{:error, {:unprocessable, detail}}` → `422` for plan errors that aren't changeset errors.
- The `POST /api/v1/recipes/:id/runs` operation documents both `200` (plan) and `202` (run) responses. Its `409` uses `RunConflictResponse` (`detail` and `active_run_id` both required); recipe deletion's `409` keeps `ConflictResponse` (`detail` only).
- `PUT`/`DELETE /sprites-credential` additionally require the key's user to be an account owner or admin (`AccountUser.admin?/1`), returning `403` otherwise and documenting it in OpenAPI. The credential controls every VM operation (and spend) of the account, so ordinary members must not swap or remove it.
- `GET /recipes/:id/runs` loads only the rendered columns (never the plan snapshot) and is paginated: `limit` (default 50, at most 200) and an opaque `cursor` encoding the last row's `(inserted_at, id)` for keyset pagination, with `next_cursor` in the response; both parameters are documented on the operation.
- Step `command` and `output` are rendered only for private (`sk_`) keys. Public keys get every other step field. Worker bookkeeping (`owner_id`, `pgflow_run_id`, `action_started_at`, `reaper_checked_at`) and the `plan` snapshot are never rendered.
- Records owned by another account are looked up scoped by `account_id` and return `:not_found`.

### D10. Configuration

`config :good_flows, GoodFlows.Spry, step_timeout_ms: 30 * 60_000, run_timeout_ms: 6 * 60 * 60_000, output_limit_bytes: 65_536, sprites_base_url: nil` (nil uses the SDK default). Optional: `queued_reap_after_ms` (default `nil`, meaning the run budget plus 5 minutes), `output_retention_ms` (default 30 days), and `require_named_node` (set to `true` for production in `runtime.exs`). Tests lower both deadlines. The PgFlow job timeout must cover the configured total-run budget plus 5 minutes; validate this, positive integer settings, and the named-node requirement at startup. `SPRY_RUN_MAX_CONCURRENCY` sets `RunJob`'s per-node PgFlow concurrency.

## Risks / Trade-offs

- **[Risk] PgFlow hard timeouts can terminate a worker without finalization.** → Mitigation: enforce the smaller application total-run budget, reserve finalization overhead in the job timeout, use the claim guard for duplicate delivery, and recover externally killed workers through D8. A queue visibility deadline and the worker execution deadline are distinct mechanisms.
- **[Resolved] Unbounded command output in worker memory.** `Sprites.cmd` would buffer all output; the wrapper uses `Sprites.spawn` with a bounded rolling buffer (at most twice `output_limit_bytes` held at once), so memory stays bounded regardless of output volume (D6).
- **[Risk] Customer tokens are used server-side**, so a leak through logs or errors would be serious. → Mitigation: the token never appears in schemas' `inspect` (`redact: true`) or in run errors. Sprites SDK errors are reduced to a status and message before they're stored. `config :phoenix, :filter_parameters, ["password", "token"]` keeps the `PUT /sprites-credential` body out of request logs, and the credential upsert passes `log: false` because Ecto's debug query log prints parameters before the encrypted type dumps them.
- **[Risk] The Sprites SDK keeps the token in its own process state** (`%Sprites.Client{token: …}`, the command process's `token` field and `authorization: Bearer …` headers), and the app cannot change the SDK. A crash of an SDK process can put that state into an OTP crash report or a Sentry event. → Mitigation: `GoodFlows.Spry.Redaction` is installed as a primary `:logger` filter at startup (before handlers, including `Sentry.LoggerHandler`), redacting values under `token`/`authorization` keys, `%Sprites.Client{}` tokens, and inspected `token: "…"`/`Bearer …` text in messages, reports, and `crash_reason` metadata; it is also Sentry's `before_send` hook. **Residual risk:** redaction recognizes these shapes only. A token formatted some other way (for example inside an opaque binary, a differently named field in a future SDK version, or tooling that reads process state directly such as `:sys.get_state/1`, observer, or a remote shell) is not covered. The token also lives in the BEAM's memory for the duration of a run.
- **[Mitigated] Step lines can print secrets** into stored output. Step `command` and `output` are hidden from public (`pk_`) keys (D9), so only private keys of the account can read them, and stored output is cleared after the retention period (D8). Residual: any `sk_` key of the account can still read them, as the CLI's terminal would show them; the API description says to avoid printing secrets.
- **[Risk] Account deletion while a run is active.** The app has no account-deletion path today (accounts can only be suspended). If an `accounts` row is deleted anyway (for example by hand), `on_delete: :delete_all` cascades to recipes, the credential, runs, and run steps while a worker may still be executing. The worker's next ownership-conditional write then affects zero rows, so it reports `lost` and issues no further VM action, but the VM it created or was driving is left as is in the customer's Sprites organization, and an already-issued remote command may finish (D6). Any future account-deletion feature must first refuse (or stop and finalize) accounts with queued or running runs.
- **[Trade-off] Bounded fallback for unreachable owners** (D8) trades a theoretical double executor for availability: past the PgFlow hard deadline the owner's node has killed it, and a survivor is fenced by owner-conditional writes, so the only residual exposure is an in-flight remote command, which D6 already cannot cancel.
- **[Trade-off] Validating every placeholder up front** rejects a recipe whose later lines need inputs that only an earlier step would produce. That isn't possible anyway, since inputs come only from the request.
- **[Trade-off] Using `get_sprite` instead of listing** for existence differs from the CLI's list-and-match, but its observable behavior is the same.

## Migration Plan

All changes add new tables, routes, and a dependency. Deploy steps:

1. Set `CLOAK_KEY` in production secrets.
2. Deploy. Migrations create the four tables, and the PgFlow job definitions are compiled.

Rollback: revert the deploy and drop the four tables. No existing data is touched.

## Open Questions

- Should `create` pass any Sprites config (region, size)? v1 uses the SDK defaults. A later recipe field can add it without changing these specs.
- Missing-sprite error shape is resolved in D6 from the installed SDK source; other errors must not become a false missing result.
