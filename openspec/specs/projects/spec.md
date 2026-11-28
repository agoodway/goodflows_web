# projects Specification

## Purpose

Stores account-owned projects, each addressed by a slug unique within its account, and manages them over the JSON API at `/api/v1/projects`. Each project has a `default_branch`, `main` unless set, which names its fallback cache scope. A project groups an account's Spry recipes, stored test reports, stored workflow runs, and caches. A project cannot be deleted while it still has recipes, test reports, stored workflow runs, or stored changes; its caches and cache keys are deleted with it.

## Requirements

### Requirement: A project belongs to one account
A project SHALL belong to exactly one account and SHALL have a required `slug` of 1 to 64 UTF-8 bytes matching `[a-z0-9][a-z0-9_-]*`. Slugs MUST be unique within an account. Different accounts MAY use the same slug. A project SHALL have a `default_branch` of 1 to 256 UTF-8 bytes with no control characters, which defaults to `main` and names the project's fallback cache scope: the scope whose string equals it. It is not validated as a Git branch name. A project response MUST include `id`, `slug`, `default_branch`, `inserted_at`, and `updated_at` under `data` and MUST NOT include `account_id`.

#### Scenario: Create a project
- **WHEN** a client with a private key posts `{"slug": "goodcases"}`
- **THEN** the API responds `201` with that slug, an id, and `default_branch` `main`, stored under the key's account

#### Scenario: Create a project with a default branch
- **WHEN** a client with a private key posts `{"slug": "goodcases", "default_branch": "trunk"}`
- **THEN** the API responds `201` with `default_branch` `trunk`

#### Scenario: Duplicate slug
- **WHEN** the account already has a project with slug `goodcases` and a client creates that slug again
- **THEN** the API responds `422` with an error on `slug` and does not store a second row

#### Scenario: Same slug in another account
- **WHEN** account A has a project `goodcases` and a client authenticated to account B creates `goodcases`
- **THEN** the API responds `201`

#### Scenario: Invalid slug
- **WHEN** a client creates a project whose slug is `GoodCases`, `-app`, `"abc\n"` (a trailing newline), empty, or longer than 64 bytes
- **THEN** the API responds `422` with an error on `slug` and stores nothing

#### Scenario: Invalid default branch
- **WHEN** a client creates a project whose `default_branch` is empty, contains a newline, or is longer than 256 bytes
- **THEN** the API responds `422` with an error on `default_branch` and stores nothing

### Requirement: Project endpoints
The API SHALL provide `POST /api/v1/projects`, `GET /api/v1/projects`, `GET /api/v1/projects/:project`, `PATCH /api/v1/projects/:project`, and `DELETE /api/v1/projects/:project`. Each operation MUST be described in the OpenAPI document. `PATCH` MUST accept only `default_branch`; a body with `slug` or any other key MUST respond `422`, so a project can't be renamed. Creating, updating and deleting MUST require a private key whose membership is owner or admin of the account; a private key of a plain member MUST receive `403` and change nothing. The dashboard's projects page MUST apply the same rule: every member can list projects, and only owners and admins can create, edit, or delete them. Listing and showing MUST accept any valid `sk_` or `pk_` key for the account. Listing MUST return the account's projects ordered by `slug`. A project belonging to another account MUST respond `404`.

#### Scenario: List projects
- **WHEN** a client lists projects
- **THEN** the API responds `200` with that account's projects only, ordered by `slug`

#### Scenario: Show a project
- **WHEN** a client shows a project of its account
- **THEN** the API responds `200` with that project's `id`, `slug`, and `default_branch`

#### Scenario: Change the default branch
- **WHEN** a client with a private key patches a project with `{"default_branch": "trunk"}`
- **THEN** the API responds `200` with `default_branch` `trunk`, and later cache lookups fall back to the `trunk` scope

#### Scenario: Rename is refused
- **WHEN** a client patches a project with `{"slug": "renamed"}`
- **THEN** the API responds `422` and the slug is unchanged

#### Scenario: Public key cannot create
- **WHEN** a client with a `pk_` key creates a project
- **THEN** the API responds `403`

#### Scenario: Public key cannot update
- **WHEN** a client with a `pk_` key patches a project
- **THEN** the API responds `403` and the project is unchanged

#### Scenario: Public key cannot delete
- **WHEN** a client with a `pk_` key deletes a project
- **THEN** the API responds `403` and the project remains

#### Scenario: Plain member cannot write
- **WHEN** a client with an `sk_` key of a plain member of the account creates, patches, or deletes a project
- **THEN** the API responds `403` and no project is created, changed, or deleted

#### Scenario: Plain member can list
- **WHEN** a client with an `sk_` key of a plain member lists projects
- **THEN** the API responds `200`

#### Scenario: Public key can list
- **WHEN** a client with a `pk_` key lists projects
- **THEN** the API responds `200`

#### Scenario: Other account's project
- **WHEN** a client shows a slug that exists only on another account
- **THEN** the API responds `404`

#### Scenario: Invalid slug in the path
- **WHEN** a client shows, updates, or deletes a project whose path slug is `GoodCases` or `-app`
- **THEN** the API responds `422` and does not write

### Requirement: Recipes, test reports, and workflow runs protect a project from deletion
Deleting a project that has any recipe, test report, workflow run, change request in any state, verify run in any status, or stored change MUST respond `409` and keep all of them. Otherwise it MUST respond `204`, and a later show MUST respond `404`. Scenario set versions go with their change requests. Review policy versions, feature index versions, cache entries, reservations and keys MUST NOT block deletion: they are deleted with the project and their objects queued for deletion.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has no recipes, test reports, workflow runs, change requests, verify runs, or stored changes
- **THEN** the API responds `204` and a later show of that slug responds `404`

#### Scenario: Delete a project that has a recipe
- **WHEN** a client deletes a project that has a recipe, including a recipe whose runs have finished
- **THEN** the API responds `409` and the project and the recipe remain

#### Scenario: Delete a project with reports and no recipes
- **WHEN** a client deletes a project that has a stored test report and no recipes
- **THEN** the API responds `409` and the project and the report remain

#### Scenario: Delete a project with only a workflow run
- **WHEN** a client deletes a project whose only content is a stored workflow run
- **THEN** the API responds `409` and the project and the workflow run remain

#### Scenario: Delete a project with only a change request
- **WHEN** a client deletes a project whose only content is change request `1` in state `closed`
- **THEN** the API responds `409` and the project and change request `1` remain

#### Scenario: Delete a project with only a review policy
- **WHEN** a client deletes a project whose only content is review policy versions `1` and `2`
- **THEN** the API responds `204`, a later show of that slug responds `404`, and the policy versions are gone

#### Scenario: Delete a project with only caches
- **WHEN** a client deletes a project whose only content is committed cache entries and a cache key
- **THEN** the API responds `204`, the cache key gets `401` on its next request, and the entries' objects are deleted by the next sweep

#### Scenario: Delete a project with only a verify run
- **WHEN** a client deletes a project whose only content is a final verify run
- **THEN** the API responds `409` and the project and the verify run remain

#### Scenario: Delete a project with a verify run whose artifacts expired
- **WHEN** a client deletes a project whose only content is a verify run whose artifacts all have `expired` true
- **THEN** the API responds `409`, because the run document still blocks deletion

#### Scenario: Delete a project with only a feature index
- **WHEN** a client deletes a project whose only content is three feature index versions
- **THEN** the API responds `204` and the feature index versions are deleted

#### Scenario: Uploading verify run
- **WHEN** a client deletes a project whose only content is a verify run with `status` `uploading`
- **THEN** the API responds `409` until the sweep deletes the expired run, after which deletion responds `204`

#### Scenario: Delete a project with only a stored change
- **WHEN** a client deletes a project whose only content is a stored change with two versions
- **THEN** the API responds `409` and the project and the stored change remain; after the stored change is deleted, deleting the project responds `204`
