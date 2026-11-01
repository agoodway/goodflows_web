# projects Specification

## Purpose

Stores account-owned projects, each addressed by a slug unique within its account, and manages them over the JSON API at `/api/v1/projects`. A project groups an account's Spry recipes so each recipe catalog belongs to one project row, and a project cannot be deleted while it still has recipes.

## Requirements

### Requirement: A project belongs to one account
A project SHALL belong to exactly one account and SHALL have a required `slug` of 1 to 64 UTF-8 bytes matching `[a-z0-9][a-z0-9_-]*`. Slugs MUST be unique within an account. Different accounts MAY use the same slug. A project response MUST include `id`, `slug`, `inserted_at`, and `updated_at` under `data` and MUST NOT include `account_id`.

#### Scenario: Create a project
- **WHEN** a client with a private key posts `{"slug": "goodcases"}`
- **THEN** the API responds `201` with that slug and an id, stored under the key's account

#### Scenario: Duplicate slug
- **WHEN** the account already has a project with slug `goodcases` and a client creates that slug again
- **THEN** the API responds `422` with an error on `slug` and does not store a second row

#### Scenario: Same slug in another account
- **WHEN** account A has a project `goodcases` and a client authenticated to account B creates `goodcases`
- **THEN** the API responds `201`

#### Scenario: Invalid slug
- **WHEN** a client creates a project whose slug is `GoodCases`, `-app`, `"abc\n"` (a trailing newline), empty, or longer than 64 bytes
- **THEN** the API responds `422` with an error on `slug` and stores nothing

### Requirement: Project endpoints
The API SHALL provide `POST /api/v1/projects`, `GET /api/v1/projects`, `GET /api/v1/projects/:project`, and `DELETE /api/v1/projects/:project`. Each operation MUST be described in the OpenAPI document. The API MUST NOT provide an update or rename route. Creating and deleting MUST require a private key. Listing and showing MUST accept any valid key for the account. Listing MUST return the account's projects ordered by `slug`. A project belonging to another account MUST respond `404`.

#### Scenario: List projects
- **WHEN** a client lists projects
- **THEN** the API responds `200` with that account's projects only, ordered by `slug`

#### Scenario: Show a project
- **WHEN** a client shows a project of its account
- **THEN** the API responds `200` with that project's `id` and `slug`

#### Scenario: Public key cannot create
- **WHEN** a client with a `pk_` key creates a project
- **THEN** the API responds `403`

#### Scenario: Public key cannot delete
- **WHEN** a client with a `pk_` key deletes a project
- **THEN** the API responds `403` and the project remains

#### Scenario: Public key can list
- **WHEN** a client with a `pk_` key lists projects
- **THEN** the API responds `200`

#### Scenario: Other account's project
- **WHEN** a client shows a slug that exists only on another account
- **THEN** the API responds `404`

#### Scenario: Invalid slug in the path
- **WHEN** a client shows or deletes a project whose path slug is `GoodCases` or `-app`
- **THEN** the API responds `422` and does not write

### Requirement: A project with recipes cannot be deleted
Deleting a project that has any recipe MUST respond `409` and MUST keep the project and its recipes. Deleting a project that has no recipes MUST respond `204`, and a later show MUST respond `404`.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has no recipes
- **THEN** the API responds `204` and a later show of that slug responds `404`

#### Scenario: Delete a project that has a recipe
- **WHEN** a client deletes a project that has a recipe, including a recipe whose runs have finished
- **THEN** the API responds `409` and the project and the recipe remain
