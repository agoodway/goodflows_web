# Spec Delta

## Purpose

Runs a recipe lifecycle phase (`setup`, `start`, `stop`, `teardown`) against a Sprite VM on behalf of an account, asynchronously, and reports each run's progress and output. This replaces the `spry setup`, `spry app start`, `spry app stop`, and `spry teardown` CLI commands.

## ADDED Requirements

### Requirement: Start a run

`POST /api/v1/recipes/:id/runs` SHALL accept `phase` (`setup`, `start`, `stop`, or `teardown`), optional `branch`, `commit`, `remote`, and `sprite` (a name template overriding the recipe name), and respond `202` with the new run in status `queued`.

#### Scenario: Setup run accepted

- **WHEN** a client posts `{"phase": "setup", "branch": "feat/x"}` for a recipe named `app-{{branch_slug}}`
- **THEN** the API responds `202` with a run whose `status` is `queued`, `phase` is `setup`, and `sprite_name` is `app-feat-x`

#### Scenario: Sprite override

- **WHEN** a client posts `{"phase": "start", "sprite": "demo"}`
- **THEN** the run's `sprite_name` is `demo` regardless of the recipe name

#### Scenario: Invalid phase

- **WHEN** a client posts `{"phase": "deploy"}`
- **THEN** the API responds `422` with an error on `phase`

### Requirement: Phase-specific flags

`no_create` SHALL be accepted only with `phase` `setup`, and `no_destroy` only with `phase` `teardown`. Either flag on another phase MUST be rejected with `422`.

#### Scenario: No-destroy on setup

- **WHEN** a client posts `{"phase": "setup", "no_destroy": true}`
- **THEN** the API responds `422` with an error on `no_destroy`

### Requirement: A Sprites credential is required

Starting a run or a dry run MUST fail with `422` and an error stating that a Sprites credential must be configured when the account has none.

#### Scenario: No credential

- **WHEN** the account has no Sprites credential and a client starts a run
- **THEN** the API responds `422`, the error mentions configuring the Sprites credential, and no run is created

### Requirement: One active run per sprite

The system MUST NOT allow two runs that are `queued` or `running` for the same resolved sprite name within an account. A request that would create a second one MUST respond `409` and identify the active run.

#### Scenario: Concurrent request

- **WHEN** a setup run for `app-feat-x` is `running` and a client starts a teardown run that resolves to `app-feat-x`
- **THEN** the API responds `409` with the id of the running run and no new run is created

#### Scenario: Different sprite

- **WHEN** a run for `app-feat-x` is `running` and a client starts a run that resolves to `app-feat-y`
- **THEN** the API responds `202`

#### Scenario: Previous run finished

- **WHEN** the only run for `app-feat-x` has `status` `failed` and a client starts a new run for it
- **THEN** the API responds `202`

### Requirement: Dry run

A run request with `dry_run: true` SHALL respond `200` with a plan and MUST NOT create a run, create or destroy a VM, or execute a command. It MAY list the account's sprites to report whether the VM exists.

#### Scenario: Setup dry run with missing VM

- **WHEN** a setup dry run resolves to a sprite that does not exist
- **THEN** the plan lists a `create` action followed by each expanded setup line, and no VM is created

#### Scenario: Teardown dry run

- **WHEN** a teardown dry run resolves to an existing sprite
- **THEN** the plan lists each expanded teardown line followed by a `destroy` action

#### Scenario: Teardown dry run with no-destroy

- **WHEN** a teardown dry run sets `no_destroy: true`
- **THEN** the plan lists the teardown lines and no `destroy` action

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

Each step MUST be bounded by a server-configured timeout. A step that exceeds it MUST be marked `failed` with a timeout reason, and the run MUST fail.

#### Scenario: Hung command

- **WHEN** a step runs longer than the step timeout
- **THEN** the step is `failed` with reason `timeout` and later steps are `skipped`

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

`GET /api/v1/runs/:id` SHALL return the run's `status` (`queued`, `running`, `succeeded`, `failed`), phase, resolved sprite name, inputs, flags, timestamps, any run-level error, and its steps. Each step MUST include its index, kind (`create`, `exec`, or `destroy`), expanded command, status, exit code, output, and timestamps.

#### Scenario: Poll a finished run

- **WHEN** a client fetches a `succeeded` setup run that created its VM
- **THEN** the response includes a `create` step followed by `exec` steps, each with `exit_code` and `output`

### Requirement: Step output is captured and bounded

Each step's combined stdout and stderr SHALL be stored once the step finishes. Output beyond 64 KiB MUST be truncated to its last 64 KiB and the step MUST report `output_truncated: true`.

#### Scenario: Large output

- **WHEN** a step writes 1 MiB of output
- **THEN** the stored output is its last 64 KiB and `output_truncated` is `true`

### Requirement: List runs for a recipe

`GET /api/v1/recipes/:id/runs` SHALL return that recipe's runs, newest first, without step output.

#### Scenario: List runs

- **WHEN** a recipe has three runs and a client lists them
- **THEN** the API responds `200` with three runs ordered by creation time, newest first

### Requirement: Abandoned runs end as failed

A run that stops making progress because its worker was lost MUST eventually be marked `failed` with an abandonment error, so that it no longer blocks new runs for its sprite.

#### Scenario: Server restart mid-run

- **WHEN** the server restarts while a run is `running` and the run is not resumed
- **THEN** the run becomes `failed` with an error stating it was abandoned, and a new run for the same sprite is accepted

### Requirement: Run access control

Starting a run, including a dry run, MUST require a private (`sk_`) key. Reading runs SHALL accept any valid API key. Runs and recipes of another account MUST respond `404`.

#### Scenario: Public key cannot start a run

- **WHEN** a client with a `pk_` key posts a run
- **THEN** the API responds `403`

#### Scenario: Other account's run

- **WHEN** a client fetches a run id owned by another account
- **THEN** the API responds `404`

### Requirement: Run plans are immutable snapshots

A run MUST store its expanded name and commands when accepted. Later recipe edits MUST NOT change the queued or running plan. Deleting a recipe after its runs finish MUST retain those runs and their steps for account-scoped retrieval by run id.

#### Scenario: Recipe edited after enqueue

- **WHEN** a run is queued and the recipe's name or phase lines are replaced before the worker starts
- **THEN** the worker executes the run's original expanded name and commands

#### Scenario: Completed run survives recipe deletion

- **WHEN** a completed run's recipe is deleted
- **THEN** `GET /api/v1/runs/:id` still returns that run and its steps to the owning account
