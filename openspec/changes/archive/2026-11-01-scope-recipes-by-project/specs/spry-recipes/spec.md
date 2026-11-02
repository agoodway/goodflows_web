# Spec Delta

## RENAMED Requirements

- FROM: `### Requirement: Recipe names are unique per account`
- TO: `### Requirement: Recipe names are unique per project`

## MODIFIED Requirements

### Requirement: Recipe schema

A recipe SHALL have a required `name` (a sprite name template, non-empty after trimming, at most 255 characters) and four optional lists, `setup`, `start`, `stop`, and `teardown`. Each list item MUST be a non-empty string of at most 10,000 characters that runs inside the VM. Each list MUST hold at most 500 items. An omitted list MUST be stored as an empty list. Oversized values MUST be rejected with `422`, never a server error. The recipe SHALL belong to the project row identified by the URL slug. Every recipe response MUST include `project_id` and `project` (that project's slug). Replacing a recipe MUST NOT change its project.

#### Scenario: Valid recipe with all fields

- **WHEN** a client creates a recipe with `name` `myapp-{{branch_slug}}` and string lists for all four phases
- **THEN** the API responds `201` with the stored recipe, including all four lists in order

#### Scenario: Valid recipe with only a name

- **WHEN** a client creates a recipe with only `name` `demo`
- **THEN** the API responds `201` and `setup`, `start`, `stop`, and `teardown` are empty lists

#### Scenario: Missing name

- **WHEN** a client creates a recipe without `name`, or with a blank `name`
- **THEN** the API responds `422` with an error on `name`

#### Scenario: Too many items

- **WHEN** a phase list contains more than 500 items
- **THEN** the API responds `422` with an error on that phase

#### Scenario: Oversized name or line

- **WHEN** `name` is longer than 255 characters, or a phase item is longer than 10,000 characters
- **THEN** the API responds `422` with an error on `name` or on that phase and item index

#### Scenario: Empty step string

- **WHEN** a phase list contains an empty or whitespace-only string
- **THEN** the API responds `422` with an error identifying the phase and item index

#### Scenario: Response includes project

- **WHEN** a client creates a recipe at `/api/v1/projects/goodcases/recipes`
- **THEN** the API responds `201`, the recipe's `project` is `goodcases`, and `project_id` is that project's id

#### Scenario: Replace keeps project

- **WHEN** a client replaces a recipe under the project URL that stored it
- **THEN** the recipe's `project` is unchanged

### Requirement: Recipe names are unique per project

Within one project, no two recipes SHALL share the same `name` template. The same account MAY use that name in a different project. Recipes in different accounts MAY share a name. The name doubles as the sprite name template by design; there is no separate display name.

#### Scenario: Duplicate name in the same account

- **WHEN** an account already has a recipe named `myapp-{{branch_slug}}` in project `goodcases` and a client creates another with the same name in `goodcases`
- **THEN** the API responds `422` with an error on `name`

#### Scenario: Same name in another account

- **WHEN** account A has a recipe named `demo` and a client authenticated to account B creates a recipe named `demo`
- **THEN** the API responds `201`

#### Scenario: Same name in another project

- **WHEN** an account has a recipe named `demo` in project `goodcases` and a client creates a recipe named `demo` in project `other`
- **THEN** the API responds `201`

### Requirement: Recipe CRUD endpoints

The API SHALL provide `POST /api/v1/projects/:project/recipes`, `GET /api/v1/projects/:project/recipes`, `GET /api/v1/projects/:project/recipes/:id`, `PUT /api/v1/projects/:project/recipes/:id` (full replacement), and `DELETE /api/v1/projects/:project/recipes/:id`. Each operation MUST be described in the OpenAPI document. The unscoped `/api/v1/recipes` routes MUST NOT be served. Show, replace, and delete MUST apply only when the URL slug identifies the project row the recipe belongs to.

#### Scenario: List recipes

- **WHEN** a client lists recipes for a project
- **THEN** the API responds `200` with that project's recipes only

#### Scenario: Replace a recipe

- **WHEN** a client sends `PUT` with a body that omits `stop`
- **THEN** the stored recipe's `stop` becomes an empty list

#### Scenario: Replace without a name

- **WHEN** a client sends `PUT` with a body that omits `name`
- **THEN** the API responds `422` with an error on `name` and the stored recipe is unchanged

#### Scenario: Delete a recipe

- **WHEN** a client deletes a recipe that has no queued or running run
- **THEN** the API responds `204` and later `GET` of that id responds `404`

#### Scenario: Delete a recipe with an active run

- **WHEN** a client deletes a recipe that has a queued or running run
- **THEN** the API responds `409` and the recipe is kept

#### Scenario: Deletion races run admission

- **WHEN** deletion and a new run request concurrently target the same recipe
- **THEN** they serialize on the account-scoped recipe row: an admitted run makes deletion return `409`, or a completed deletion makes run admission return `404`

#### Scenario: Other project omitted from the list

- **WHEN** the account has a recipe in project `other` and the client lists project `goodcases`
- **THEN** the response does not include that recipe

#### Scenario: Unscoped recipe route

- **WHEN** a client requests `GET /api/v1/recipes` or `POST /api/v1/recipes`
- **THEN** the API responds `404`

### Requirement: Recipe access control

Reading recipes SHALL accept any valid API key for the account. Creating, replacing, and deleting recipes MUST require a private (`sk_`) key. A recipe belonging to another account MUST respond `404`. A recipe addressed under a different project of the same account MUST respond `404`.

#### Scenario: Public key cannot create

- **WHEN** a client with a `pk_` key creates a recipe
- **THEN** the API responds `403`

#### Scenario: Public key can read

- **WHEN** a client with a `pk_` key lists recipes
- **THEN** the API responds `200`

#### Scenario: Other account's recipe

- **WHEN** a client requests a recipe id owned by a different account
- **THEN** the API responds `404`

#### Scenario: Other project of the same account

- **WHEN** a client requests a recipe id under a project other than the one that stores it
- **THEN** the API responds `404`

## ADDED Requirements

### Requirement: Project slugs are validated

The `:project` path segment on recipe routes and on run routes nested under a recipe SHALL be a lowercase slug of 1 to 64 UTF-8 bytes matching `[a-z0-9][a-z0-9_-]*`. A segment that violates this MUST be rejected with `422` and an error on `project`, and MUST NOT read or write a recipe or a run. A valid slug MUST resolve to a project row of the authenticated account. When no such row exists the API MUST respond `404` and MUST NOT create a project, recipe, or run. An existing project with no recipes MUST list as `200` with an empty list.

#### Scenario: Invalid project slug

- **WHEN** a client lists recipes with project `GoodCases`, `-app`, or a slug longer than 64 bytes
- **THEN** the API responds `422` with an error on `project` and stores nothing

#### Scenario: Valid project with no recipes

- **WHEN** a client lists recipes for an existing project that has none
- **THEN** the API responds `200` with an empty list

#### Scenario: Missing project

- **WHEN** a client creates or lists recipes for a valid slug that has no project row
- **THEN** the API responds `404` and stores nothing

### Requirement: Project is not a recipe body field

A recipe create or replace request body containing `project` MUST be rejected with `422` and an error on `project`. The stored project comes only from the URL, and a rejected body MUST leave storage unchanged.

#### Scenario: Project supplied in the body

- **WHEN** a client creates a recipe whose JSON body includes `project`
- **THEN** the API responds `422` with an error on `project` and stores nothing

#### Scenario: Project supplied on replace

- **WHEN** a client replaces a recipe with a body that includes `project`
- **THEN** the API responds `422` with an error on `project` and the stored recipe is unchanged
