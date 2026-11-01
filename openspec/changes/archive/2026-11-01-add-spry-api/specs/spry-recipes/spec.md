# Spec Delta

## Purpose

Stores Spry recipes per account and manages them over the JSON API. A recipe describes how a Sprite VM is named and which in-VM commands each lifecycle phase runs.

## ADDED Requirements

### Requirement: Recipe schema

A recipe SHALL have a required `name` (a sprite name template, non-empty after trimming, at most 255 characters) and four optional lists, `setup`, `start`, `stop`, and `teardown`. Each list item MUST be a non-empty string of at most 10,000 characters that runs inside the VM. Each list MUST hold at most 500 items. An omitted list MUST be stored as an empty list. Oversized values MUST be rejected with `422`, never a server error.

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

### Requirement: Recipe names are valid sprite name templates

The `name` is the template for the sprite name, and its literal text MUST be able to form a valid sprite name: lowercase letters, digits, and hyphens, starting with a letter or digit, at most 63 characters when each placeholder is counted as one character. A name violating this MUST be rejected with `422` on `name` when the recipe is saved. Because the rule is lowercase-only, names differing only by case can never refer to the same VM. Recipes SHOULD use `{{branch_slug}}` rather than `{{branch}}`.

#### Scenario: Invalid literal name

- **WHEN** a client saves a recipe whose `name` is `App`, `app#1`, `a..b`, `-app`, or longer than 63 characters
- **THEN** the API responds `422` with an error on `name` describing the sprite name rule

#### Scenario: Template with valid literal parts

- **WHEN** a client saves a recipe whose `name` is `app-{{branch_slug}}`
- **THEN** the API responds `201`

### Requirement: Recipe names are unique per account

Within one account, no two recipes SHALL share the same `name` template. Recipes in different accounts MAY share a name. The name doubles as the sprite name template by design; there is no separate display name.

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
