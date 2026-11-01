# Spec Delta

## Purpose

Stores Spry recipes per account and manages them over the JSON API. A recipe describes how a Sprite VM is named and which in-VM commands each lifecycle phase runs.

## ADDED Requirements

### Requirement: Recipe schema

A recipe SHALL have a required `name` (a sprite name template, non-empty after trimming) and four optional lists, `setup`, `start`, `stop`, and `teardown`. Each list item MUST be a non-empty string that runs inside the VM. An omitted list MUST be stored as an empty list.

#### Scenario: Valid recipe with all fields

- **WHEN** a client creates a recipe with `name` `myapp-{{branch_slug}}` and string lists for all four phases
- **THEN** the API responds `201` with the stored recipe, including all four lists in order

#### Scenario: Valid recipe with only a name

- **WHEN** a client creates a recipe with only `name` `demo`
- **THEN** the API responds `201` and `setup`, `start`, `stop`, and `teardown` are empty lists

#### Scenario: Missing name

- **WHEN** a client creates a recipe without `name`, or with a blank `name`
- **THEN** the API responds `422` with an error on `name`

#### Scenario: Empty step string

- **WHEN** a phase list contains an empty or whitespace-only string
- **THEN** the API responds `422` with an error identifying the phase and item index

### Requirement: Host steps are rejected

A recipe MUST NOT contain host steps. Any phase list item that is not a string, including a `{host: …}` object, MUST be rejected with `422` and an error stating that host steps are not supported by the API.

#### Scenario: Host map in setup

- **WHEN** a client creates a recipe whose `setup` contains `{"host": "gh repo deploy-key add ..."}`
- **THEN** the API responds `422`, the error identifies `setup` and the item index, and states host steps are not supported

#### Scenario: Host map on update

- **WHEN** a client updates an existing recipe and adds a `{host: …}` item to `teardown`
- **THEN** the API responds `422` and the stored recipe is unchanged

### Requirement: Org is not a recipe field

A recipe SHALL NOT have an `org` field. The Sprites organization is determined by the account's Sprites credential. A request body containing `org` MUST be rejected with `422`.

#### Scenario: Org supplied

- **WHEN** a client creates a recipe with `org` `acme`
- **THEN** the API responds `422` with an error on `org`

### Requirement: Placeholders are validated on save

The `name` and every step line SHALL be checked for placeholder syntax when a recipe is created or updated. An unknown placeholder, or `{{sprite}}` in `name`, MUST be rejected with `422` naming the placeholder and the field.

#### Scenario: Unknown placeholder in a step

- **WHEN** a `start` item contains `{{foo}}`
- **THEN** the API responds `422` and the error names `foo` and `start`

#### Scenario: Sprite placeholder in name

- **WHEN** `name` is `app-{{sprite}}`
- **THEN** the API responds `422` because `name` cannot refer to itself

### Requirement: Recipe names are unique per account

Within one account, no two recipes SHALL share the same `name` template. Recipes in different accounts MAY share a name.

#### Scenario: Duplicate name in the same account

- **WHEN** an account already has a recipe named `myapp-{{branch_slug}}` and a client creates another with the same name
- **THEN** the API responds `422` with an error on `name`

#### Scenario: Same name in another account

- **WHEN** account A has a recipe named `demo` and a client authenticated to account B creates a recipe named `demo`
- **THEN** the API responds `201`

### Requirement: Recipe CRUD endpoints

The API SHALL provide `POST /api/v1/recipes`, `GET /api/v1/recipes`, `GET /api/v1/recipes/:id`, `PUT /api/v1/recipes/:id` (full replacement), and `DELETE /api/v1/recipes/:id`. Each operation MUST be described in the OpenAPI document.

#### Scenario: List recipes

- **WHEN** a client lists recipes
- **THEN** the API responds `200` with the account's recipes only

#### Scenario: Replace a recipe

- **WHEN** a client sends `PUT` with a body that omits `stop`
- **THEN** the stored recipe's `stop` becomes an empty list

#### Scenario: Delete a recipe

- **WHEN** a client deletes a recipe that has no queued or running run
- **THEN** the API responds `204` and later `GET` of that id responds `404`

#### Scenario: Delete a recipe with an active run

- **WHEN** a client deletes a recipe that has a queued or running run
- **THEN** the API responds `409` and the recipe is kept

### Requirement: Recipe access control

Reading recipes SHALL accept any valid API key for the account. Creating, replacing, and deleting recipes MUST require a private (`sk_`) key. A recipe belonging to another account MUST respond `404`.

#### Scenario: Public key cannot create

- **WHEN** a client with a `pk_` key creates a recipe
- **THEN** the API responds `403`

#### Scenario: Public key can read

- **WHEN** a client with a `pk_` key lists recipes
- **THEN** the API responds `200`

#### Scenario: Other account's recipe

- **WHEN** a client requests a recipe id owned by a different account
- **THEN** the API responds `404`
