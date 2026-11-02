# Spec Delta

## MODIFIED Requirements

### Requirement: Expanded sprite name must be a valid sprite name

The expanded sprite name, whether from the recipe name or the request's `sprite` override, MUST match `^[a-z0-9][a-z0-9-]{0,62}$` and MUST NOT start with the pool-member prefix `gfp-`; otherwise the run request (or dry run) MUST fail with `422` on `sprite_name` (or on `sprite` when the override's literal text can never be valid) and no run is created. `{{branch_slug}}` preserves case, so a branch with uppercase letters, `.`, or `_` yields an invalid name rather than one that aliases another VM.

#### Scenario: Uppercase branch

- **WHEN** the recipe name is `app-{{branch_slug}}` and branch is `Feat/X`
- **THEN** the API responds `422` and the error names `app-Feat-X` as not a valid sprite name

#### Scenario: Invalid override

- **WHEN** a run request sets `sprite` to `Demo`, `demo#1`, or `a..b`
- **THEN** the API responds `422` and no run is created

#### Scenario: Expansion lands on the reserved prefix

- **WHEN** the recipe name is `{{branch_slug}}-app` and branch is `gfp`
- **THEN** the API responds `422` on `sprite_name` stating that `gfp-` is reserved, and no run is created

#### Scenario: Override uses the reserved prefix

- **WHEN** a run request sets `sprite` to `gfp-demo`
- **THEN** the API responds `422` on `sprite` and no run is created
