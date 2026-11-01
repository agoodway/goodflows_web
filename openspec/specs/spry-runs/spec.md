# spry-runs Specification

## Purpose

Runs a recipe lifecycle phase (`setup`, `start`, `stop`, `teardown`) against a Sprite VM on behalf of an account, asynchronously, and reports each run's progress and output. This replaces the `spry setup`, `spry app start`, `spry app stop`, and `spry teardown` CLI commands.

## Requirements

### Requirement: Start a run

`POST /api/v1/projects/:project/recipes/:id/runs` SHALL accept `phase` (`setup`, `start`, `stop`, or `teardown`), optional `branch`, `commit`, `remote`, and `sprite` (a name template overriding the recipe name, at most 255 characters), and respond `202` with the new run in status `queued`. The URL slug MUST identify the project row the recipe belongs to; any other project, including another project of the same account, MUST respond `404` and create no run. A valid slug with no project row MUST respond `404` and create no run. An invalid project segment MUST be rejected with `422` using the recipe project-slug rule. The unscoped `POST /api/v1/recipes/:id/runs` route MUST NOT be served. The run MUST record the API key that started it (`started_by_api_key_id`), which becomes null if that key is deleted. If the job cannot be enqueued, the API MUST respond `503`, create no run, and log the failure with the run id and reason.

#### Scenario: Setup run accepted

- **WHEN** a client posts `{"phase": "setup", "branch": "feat/x"}` for a recipe named `app-{{branch_slug}}`
- **THEN** the API responds `202` with a run whose `status` is `queued`, `phase` is `setup`, and `sprite_name` is `app-feat-x`

#### Scenario: Sprite override

- **WHEN** a client posts `{"phase": "start", "sprite": "demo"}`
- **THEN** the run's `sprite_name` is `demo` regardless of the recipe name

#### Scenario: Invalid phase

- **WHEN** a client posts `{"phase": "deploy"}`
- **THEN** the API responds `422` with an error on `phase`

#### Scenario: Run records its starting key

- **WHEN** a client starts a run with an `sk_` key
- **THEN** the run's `started_by_api_key_id` is that key's id, and deleting the key keeps the run with a null reference

#### Scenario: Enqueue failure

- **WHEN** the run job cannot be enqueued
- **THEN** the API responds `503`, no run exists, and an error is logged naming the run id and reason

#### Scenario: Wrong project

- **WHEN** a client posts a run for a recipe id under a project other than the one that stores it
- **THEN** the API responds `404` and no run is created

#### Scenario: Missing project

- **WHEN** a client posts a run under a valid slug that has no project row
- **THEN** the API responds `404` and no run is created

#### Scenario: Invalid project segment

- **WHEN** a client posts a run under project `GoodCases`
- **THEN** the API responds `422` with an error on `project` and no run is created

#### Scenario: Dry run under the wrong project

- **WHEN** a client posts `{"phase": "setup", "dry_run": true}` for a recipe id under a project other than the one that stores it
- **THEN** the API responds `404`, no plan is returned, and no Sprites call is made

#### Scenario: Unscoped run route

- **WHEN** a client posts to `POST /api/v1/recipes/:id/runs`
- **THEN** the API responds `404` and no run is created

### Requirement: Phase-specific flags

`no_create` SHALL be accepted only with `phase` `setup`, and `no_destroy` only with `phase` `teardown`. Either flag on another phase MUST be rejected with `422`.

#### Scenario: No-destroy on setup

- **WHEN** a client posts `{"phase": "setup", "no_destroy": true}`
- **THEN** the API responds `422` with an error on `no_destroy`

### Requirement: A Sprites credential is required

Starting a run or a dry run MUST fail with `422` and an error stating that a Sprites credential must be configured when the account has none. The request itself (phase, flags, and inputs) MUST be validated first, so an invalid request reports its validation errors even when no credential is configured.

#### Scenario: No credential

- **WHEN** the account has no Sprites credential and a client starts a run
- **THEN** the API responds `422`, the error mentions configuring the Sprites credential, and no run is created

#### Scenario: Invalid request without a credential

- **WHEN** the account has no Sprites credential and a client posts `{"phase": "deploy"}`
- **THEN** the API responds `422` with an error on `phase`

### Requirement: One active run per sprite

The system MUST NOT allow two runs that are `queued` or `running` for the same resolved sprite name within an account. Different projects of that account MUST NOT create a second active run for that sprite name. A request that would create a second one MUST respond `409` and identify the active run (a `RunConflictResponse` whose `active_run_id` is required). Only a violation of the one-active-run guard is a conflict; any other validation error is a `422`. A `409` MUST NOT be returned without an active run id: if the conflicting run keeps finishing before it can be identified and bounded admission retries are exhausted, the API MUST respond `503` asking the client to retry, and no run is created.

#### Scenario: Concurrent request

- **WHEN** a setup run for `app-feat-x` is `running` and a client starts a teardown run that resolves to `app-feat-x`
- **THEN** the API responds `409` with the id of the running run and no new run is created

#### Scenario: Different sprite

- **WHEN** a run for `app-feat-x` is `running` and a client starts a run that resolves to `app-feat-y`
- **THEN** the API responds `202`

#### Scenario: Conflicting run cannot be identified

- **WHEN** admission keeps conflicting with runs that finish before they can be looked up, until its retries are exhausted
- **THEN** the API responds `503` with a retry hint, not a `409` without an `active_run_id`

#### Scenario: Previous run finished

- **WHEN** the only run for `app-feat-x` has `status` `failed` and a client starts a new run for it
- **THEN** the API responds `202`

#### Scenario: Same sprite in another project

- **WHEN** a run for sprite `app-feat-x` is `running` under project `goodcases` and a client starts a run under project `other` that resolves to `app-feat-x`
- **THEN** the API responds `409` with the id of the running run and no new run is created

### Requirement: Dry run

A run request with `dry_run: true` SHALL respond `200` with a plan and MUST NOT create a run, create or destroy a VM, or execute a command. It MAY look up the sprite to report whether the VM exists, with a short timeout because the lookup runs within the HTTP request. `dry_run` MUST be interpreted by the same boolean cast that validates the request, so every accepted true form (for example `true`, `"true"`, or `"1"`) is a dry run and never queues a real run; a value that is not a boolean MUST be rejected with `422`.

#### Scenario: String form of dry_run

- **WHEN** a client posts `{"phase": "setup", "branch": "x", "dry_run": "1"}`
- **THEN** the API responds `200` with a plan and no run is created

#### Scenario: Setup dry run with missing VM

- **WHEN** a setup dry run resolves to a sprite that does not exist
- **THEN** the plan lists a `create` action followed by each expanded setup line, and no VM is created

#### Scenario: Teardown dry run

- **WHEN** a teardown dry run resolves to an existing sprite
- **THEN** the plan lists each expanded teardown line followed by a `destroy` action

#### Scenario: Teardown dry run with no-destroy

- **WHEN** a teardown dry run sets `no_destroy: true`
- **THEN** the plan lists the teardown lines and no `destroy` action

#### Scenario: Dry-run lookup timeout

- **WHEN** the dry run's sprite lookup exceeds its short timeout
- **THEN** the API responds `422` with an error stating that checking whether the sprite exists timed out

#### Scenario: Dry run fails where the run would

- **WHEN** a dry run for `start` resolves to a sprite that does not exist, or a setup dry run sets `no_create` and the sprite does not exist
- **THEN** the API responds `422` with the same error the run would report

### Requirement: Steps run in order and fail fast

A run SHALL execute its steps in order. Each step line MUST run inside the VM through a shell. A non-zero exit, error, or timeout MUST mark that step `failed`, mark every later step `skipped`, and end the run as `failed`.

#### Scenario: All steps succeed

- **WHEN** every step of a run exits `0`
- **THEN** every step is `succeeded` and the run is `succeeded`

#### Scenario: Middle step fails

- **WHEN** the second of three steps exits `1`
- **THEN** step 1 is `succeeded`, step 2 is `failed` with `exit_code` `1`, step 3 is `skipped`, and the run is `failed`

### Requirement: Steps have a timeout

Each step, including create and destroy actions, MUST be bounded by a server-configured elapsed-time deadline independent of output activity. A step that exceeds it MUST be marked `failed` with a timeout reason, and the run MUST fail.

#### Scenario: Hung command

- **WHEN** a step runs longer than the step timeout
- **THEN** the step is `failed` with reason `timeout` and later steps are `skipped`

#### Scenario: Continuous output cannot extend a deadline

- **WHEN** a command emits output continuously beyond its configured elapsed-time deadline
- **THEN** the local execution stops waiting, the step fails with reason `timeout`, and no subsequent step is issued

### Requirement: Setup creates a missing VM

A setup run SHALL create the VM when it does not exist, then run the setup steps. With `no_create: true`, a missing VM MUST fail the run without creating it. An existing VM MUST NOT be recreated. Empty `setup` still creates a missing VM.

#### Scenario: Missing VM is created

- **WHEN** a setup run's sprite does not exist
- **THEN** the run's first step is a `create` step for that name, followed by the setup lines

#### Scenario: Existing VM

- **WHEN** a setup run's sprite already exists
- **THEN** no `create` step runs and the setup lines run

#### Scenario: No-create with missing VM

- **WHEN** a setup run sets `no_create: true` and the sprite does not exist
- **THEN** the run is `failed` with an error stating the sprite does not exist and no VM is created

### Requirement: Start and stop require an existing VM

Start and stop runs SHALL run only their own phase's steps against an existing VM. A missing VM MUST fail the run without creating one. An empty phase list on an existing VM MUST succeed.

#### Scenario: Missing VM

- **WHEN** a start run's sprite does not exist
- **THEN** the run is `failed`, no VM is created, and no steps run

#### Scenario: Start does not run stop

- **WHEN** a start run succeeds
- **THEN** only `start` lines were executed

#### Scenario: Empty stop

- **WHEN** the recipe `stop` list is empty and the sprite exists
- **THEN** the stop run is `succeeded` with no steps

### Requirement: Teardown runs steps then destroys the VM

A teardown run SHALL require an existing VM, run the teardown steps, then destroy the VM unless `no_destroy` is set. A missing VM MUST fail the run. A failed teardown step MUST leave the VM in place. Empty `teardown` still destroys.

#### Scenario: Teardown then destroy

- **WHEN** a teardown run's sprite exists and every teardown step succeeds
- **THEN** the last step is a `destroy` step and the VM no longer exists

#### Scenario: No-destroy

- **WHEN** a teardown run sets `no_destroy: true`
- **THEN** the teardown steps run and no `destroy` step runs

#### Scenario: Failed teardown step

- **WHEN** a teardown step fails
- **THEN** the `destroy` step is `skipped` and the VM still exists

#### Scenario: Missing VM

- **WHEN** a teardown run's sprite does not exist
- **THEN** the run is `failed` and no steps or destroy run

### Requirement: Run status and steps are retrievable

`GET /api/v1/runs/:id` SHALL return the run's `status` (`queued`, `running`, `succeeded`, `failed`), phase, resolved sprite name, inputs, flags, timestamps, any run-level error, and its steps. Each step MUST include its index, kind (`create`, `exec`, or `destroy`), status, exit code, and timestamps, and, for private (`sk_`) keys only, its expanded command and output. Public (`pk_`) keys MUST NOT receive a step's `command` or `output`. Worker bookkeeping (owner id, PgFlow execution id, action and reaper timestamps) and the stored plan snapshot MUST NOT appear in any response. Every run response (start, list, and get) MUST include `project`, the slug of the run's recipe's project, so a client can address the recipe at `/api/v1/projects/{project}/recipes/{recipe_id}`; `project` MUST be `null` once the recipe is deleted, like `recipe_id`. The slug MUST NOT be stored on the run, and rendering a page of runs MUST NOT query the project once per run.

#### Scenario: Poll a finished run

- **WHEN** a client with an `sk_` key fetches a `succeeded` setup run that created its VM
- **THEN** the response includes a `create` step followed by `exec` steps, each with `command`, `exit_code`, and `output`

#### Scenario: Public key reads a run

- **WHEN** a client with a `pk_` key fetches a run whose steps printed output
- **THEN** each step includes its status and exit code but no `command` or `output`

#### Scenario: Internal fields stay internal

- **WHEN** a client fetches or lists runs
- **THEN** no response includes `owner_id`, `pgflow_run_id`, `plan`, `action_started_at`, or `reaper_checked_at`

#### Scenario: Run names its project

- **WHEN** a client starts, lists, or fetches a run of a recipe in project `goodcases`
- **THEN** each run in the response has `project` `goodcases` and the recipe's `recipe_id`

#### Scenario: Run of a deleted recipe

- **WHEN** a client fetches a finished run whose recipe has since been deleted
- **THEN** the response has `project` and `recipe_id` both `null`

### Requirement: Step output is captured and bounded

Each step's combined stdout and stderr SHALL be stored once the step finishes. Output beyond 64 KiB MUST be truncated to its last 64 KiB and the step MUST report `output_truncated: true`. Stored output MUST be cleared once the step finished longer ago than a server-configured retention period (default 30 days); the step itself is kept.

#### Scenario: Large output

- **WHEN** a step writes 1 MiB of output
- **THEN** the stored output is its last 64 KiB and `output_truncated` is `true`

#### Scenario: Output past retention

- **WHEN** a step finished longer ago than the output retention period
- **THEN** a later reaper sweep clears its `output`, and steps within the period keep theirs

### Requirement: List runs for a recipe

`GET /api/v1/projects/:project/recipes/:id/runs` SHALL return that recipe's runs, newest first, without steps, one page at a time. The URL slug MUST identify the project row the recipe belongs to; any other project MUST respond `404`. A valid slug with no project row MUST respond `404`. An invalid project segment MUST be rejected with `422` using the recipe project-slug rule. The unscoped `GET /api/v1/recipes/:id/runs` route MUST NOT be served. `limit` MUST default to 50 and accept 1 to 200; pages MUST use keyset pagination on creation time and id, returning a `next_cursor` to pass as `cursor` (null on the last page). An invalid `limit` or `cursor` MUST be rejected with `422`. Both query parameters MUST be documented in the OpenAPI document.

#### Scenario: List runs

- **WHEN** a recipe has three runs and a client lists them
- **THEN** the API responds `200` with three runs ordered by creation time, newest first, and `next_cursor` null

#### Scenario: Paging

- **WHEN** a recipe has five runs and a client lists them with `limit=2`, following `next_cursor`
- **THEN** the pages hold two, two, and one runs newest first, a run started meanwhile does not shift later pages, and the last page's `next_cursor` is null

#### Scenario: Invalid page parameters

- **WHEN** a client lists runs with `limit=0`, `limit=201`, or a malformed `cursor`
- **THEN** the API responds `422`

#### Scenario: List under the wrong project

- **WHEN** a client lists runs for a recipe id under a project other than the one that stores it
- **THEN** the API responds `404`

#### Scenario: List under a missing project

- **WHEN** a client lists runs under a valid slug that has no project row
- **THEN** the API responds `404`

### Requirement: Abandoned runs end as failed

A run that stops making progress because its worker was lost MUST eventually be marked `failed` with an abandonment error once termination of its execution owner is established, so that it no longer blocks new runs for its sprite. Stale timestamps alone MUST NOT release a running run's active guard. A live owner MUST be stopped and its termination confirmed before release; an unreachable or unknown owner MUST retain the guard pending investigation until the run's claim time plus the PgFlow hard job timeout plus finalization overhead has passed, after which that owner MUST be treated as terminated. Worker transitions MUST be conditional on ownership and MUST NOT overwrite terminal states. An orderly server shutdown MUST fail the node's running runs with "interrupted by server shutdown". A `queued` run MUST NOT be failed while its PgFlow job is still pending (for example waiting for worker capacity); it is failed as never claimed only once its job is missing or finished, and only after a configurable age that defaults to at least the run budget plus finalization overhead.

#### Scenario: Server restart mid-run

- **WHEN** the server restarts while a run is `running` and the run is not resumed
- **THEN** the run becomes `failed` with an error stating it was abandoned, and a new run for the same sprite is accepted

#### Scenario: Orderly shutdown mid-run

- **WHEN** the server shuts down in an orderly way while this node runs a run
- **THEN** the run's execution is stopped and the run becomes `failed` with "interrupted by server shutdown", its running step fails, and pending steps are skipped

#### Scenario: Queued run waiting for capacity

- **WHEN** a run has been `queued` past the reap age but its PgFlow job is still pending
- **THEN** the reaper leaves it `queued`

#### Scenario: Queued run whose job is gone

- **WHEN** a run is still `queued` past the reap age and its PgFlow job is missing or finished
- **THEN** the reaper fails it with an error stating it was never claimed

#### Scenario: Unreachable owner past its hard deadline

- **WHEN** a running run's owner cannot be reached and the run's claim time plus the PgFlow hard job timeout plus overhead has passed
- **THEN** the reaper finalizes it as abandoned, and a still-live stale worker cannot write to it or issue another VM action

### Requirement: Run access control

Starting a run, including a dry run, MUST require a private (`sk_`) key. Reading runs SHALL accept any valid API key. Runs and recipes of another account MUST respond `404`. Starting or listing runs under a different project of the same account MUST respond `404`.

#### Scenario: Public key cannot start a run

- **WHEN** a client with a `pk_` key posts a run
- **THEN** the API responds `403`

#### Scenario: Other account's run

- **WHEN** a client fetches a run id owned by another account
- **THEN** the API responds `404`

#### Scenario: Other project's run list

- **WHEN** a client lists runs for a recipe under a project other than the one that stores it
- **THEN** the API responds `404`

### Requirement: Run plans are immutable snapshots

A run MUST store its expanded name and commands when accepted. Later recipe edits MUST NOT change the queued or running plan. Deleting a recipe after its runs finish MUST retain those runs and their steps for account-scoped retrieval by run id.

#### Scenario: Recipe edited after enqueue

- **WHEN** a run is queued and the recipe's name or phase lines are replaced before the worker starts
- **THEN** the worker executes the run's original expanded name and commands

#### Scenario: Completed run survives recipe deletion

- **WHEN** a completed run's recipe is deleted
- **THEN** `GET /api/v1/runs/:id` still returns that run and its steps to the owning account

### Requirement: Total run execution is bounded

A run MUST have a server-configured total elapsed-time budget from worker claim, including lookups and actions (default 6 hours). Exhaustion MUST fail the run with reason `run_timeout`, fail any current step, and skip remaining steps. The PgFlow hard timeout MUST allow this budget plus finalization overhead. The API documentation MUST explain that local timeout or disconnect does not guarantee termination of an already-issued remote shell command.

#### Scenario: Combined steps exceed the run budget

- **WHEN** individually valid steps together exhaust the total-run budget
- **THEN** the run fails with reason `run_timeout` and no subsequent step is issued

#### Scenario: Worker killed externally

- **WHEN** PgFlow terminates a worker before it can finalize its run
- **THEN** abandoned-run recovery finalizes it after confirming the execution owner has terminated

### Requirement: Abandonment recovery preserves execution ownership

Reaper and worker transitions MUST allow only one owner to issue subsequent VM actions for an active run. Pending steps MUST be skipped when confirmed abandonment is finalized. Reaping a queued run MUST be conditional on it still being queued.

#### Scenario: Live stale worker

- **WHEN** a running run has stale timestamps but its owner is still live
- **THEN** its active guard remains held until the owner and its local action tasks are confirmed stopped

#### Scenario: Unreachable owner

- **WHEN** the reaper cannot establish termination of a run's owner before its hard deadline
- **THEN** it retains the active guard and retries investigation

#### Scenario: Unconfirmed kill of a reachable owner

- **WHEN** the reaper reaches a run's owner but cannot confirm that it terminated
- **THEN** the run keeps its active guard, even past the owner's hard deadline

#### Scenario: Another instance under the same node name

- **WHEN** a run's owner id names this node but a different boot (a previous incarnation, or another undistributed instance sharing the node name)
- **THEN** the reaper does not treat the owner as local and retains the guard until the hard deadline

#### Scenario: Retained runs do not starve others

- **WHEN** more runs are retained than one sweep investigates and a newer candidate becomes stale
- **THEN** a later sweep investigates the never-checked candidate before re-checking retained runs

#### Scenario: Operator releases an uninvestigable run

- **WHEN** a run's owner names a node that no longer exists (for example after a redeploy changed node names) and an operator, having established that node is gone, force-abandons the run
- **THEN** the run becomes `failed` with an abandonment error, its running step fails, pending steps are skipped, and a new run for the same sprite is accepted

#### Scenario: Operator overrides an unconfirmed owner

- **WHEN** an operator force-abandons a run whose owner is reachable but whose termination cannot be confirmed
- **THEN** the run is finalized anyway and a warning is logged that a live owner may still be running its current VM action

#### Scenario: Reaper races completion

- **WHEN** a worker completes while the reaper investigates its run
- **THEN** conditional transitions preserve the first valid terminal outcome and a stale worker cannot start another step

#### Scenario: Queued reaping races claim

- **WHEN** a worker attempts to claim an old queued run while the reaper attempts to fail it
- **THEN** only one transition succeeds and delivery of an already failed run performs no VM operations
