# Spec Delta

## MODIFIED Requirements

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
