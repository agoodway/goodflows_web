# Spec Delta

## Purpose

Expands `{{…}}` placeholders in a recipe's sprite name and step lines from the inputs supplied with a run, replacing the CLI's reliance on a local git checkout.

## ADDED Requirements

### Requirement: Placeholder set

The system SHALL expand `{{branch}}`, `{{branch_slug}}`, `{{commit}}`, and `{{remote}}` in the sprite name and step lines, and `{{sprite}}` in step lines only. `branch`, `commit`, and `remote` MUST come from the run request; the server MUST NOT read git.

#### Scenario: All inputs expand

- **WHEN** a run supplies branch `feature/add-dashboard`, commit `abc123def`, and remote `git@github.com:example-org/example-app.git`
- **THEN** `{{branch}}` is `feature/add-dashboard`, `{{branch_slug}}` is `feature-add-dashboard`, `{{commit}}` is `abc123def`, and `{{remote}}` is the supplied URL

#### Scenario: Sprite placeholder in a step

- **WHEN** the resolved sprite name is `myapp-feat-x` and a step line contains `{{sprite}}`
- **THEN** the executed line contains `myapp-feat-x`

### Requirement: Placeholder syntax

Placeholders MUST be case-sensitive and MUST NOT allow interior whitespace. Any other `{{…}}` token, including `{{org}}`, MUST be treated as unknown and rejected naming the placeholder.

#### Scenario: Interior whitespace is unknown

- **WHEN** a string contains `{{ branch }}`
- **THEN** it is rejected as an unknown placeholder

#### Scenario: Org placeholder is unknown

- **WHEN** a string contains `{{org}}`
- **THEN** it is rejected as an unknown placeholder named `org`

### Requirement: Single raw substitution

Expansion MUST be a single, non-recursive substitution. Values MUST NOT be shell-quoted or escaped.

#### Scenario: Values are not re-expanded

- **WHEN** the supplied branch is the literal text `{{remote}}`
- **THEN** the expanded output contains `{{remote}}`

#### Scenario: Values are not quoted

- **WHEN** a step is `git checkout {{branch}}` and branch is `feat x`
- **THEN** the executed line is `git checkout feat x`

### Requirement: Branch slug derivation

`{{branch_slug}}` MUST be derived from the supplied branch by replacing each run of characters outside `[A-Za-z0-9._-]` with a single `-`, then stripping leading and trailing `-`, preserving case. An empty slug MUST be treated as a missing input.

#### Scenario: Slashed branch becomes hyphenated

- **WHEN** the branch is `feature/add-dashboard`
- **THEN** `{{branch_slug}}` is `feature-add-dashboard`

#### Scenario: Adjacent separators collapse

- **WHEN** the branch is `feat//x y`
- **THEN** `{{branch_slug}}` is `feat-x-y`

### Requirement: Missing inputs fail before execution

When a run request is made, every placeholder in the sprite name and in the requested phase's step lines SHALL be resolved before anything runs. A placeholder whose input was not supplied MUST fail the request with `422` naming the placeholder and the request field to supply.

#### Scenario: Name needs branch

- **WHEN** the recipe name is `app-{{branch_slug}}` and the run request has no `branch`
- **THEN** the API responds `422` naming `branch_slug` and the `branch` field, and no run is created

#### Scenario: Later step needs remote

- **WHEN** setup step 2 contains `{{remote}}` and the run request has no `remote`
- **THEN** the API responds `422` and setup step 1 does not run

#### Scenario: No placeholders needs no inputs

- **WHEN** neither the name nor the phase's steps contain placeholders and the request has no `branch`, `commit`, or `remote`
- **THEN** the request is accepted

### Requirement: Expanded sprite name must not contain a slash

If the expanded sprite name contains `/`, the run request MUST fail with `422` and the error MUST suggest `{{branch_slug}}`.

#### Scenario: Raw branch in name

- **WHEN** the recipe name is `{{branch}}` and branch is `feature/add-dashboard`
- **THEN** the API responds `422` and the error mentions `{{branch_slug}}`
