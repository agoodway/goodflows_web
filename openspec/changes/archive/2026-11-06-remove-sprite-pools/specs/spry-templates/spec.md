# Spec Delta

## ADDED Requirements

### Requirement: Expanded sprite names follow the sprite name rule

The expanded sprite name, whether from the recipe name or the request's `sprite` override, MUST match `^[a-z0-9][a-z0-9-]{0,62}$`; otherwise the run request (or dry run) MUST fail with `422` on `sprite_name` (or on `sprite` when the override's literal text can never be valid) and no run is created. No prefix is reserved. `{{branch_slug}}` preserves case, so a branch with uppercase letters, `.`, or `_` yields an invalid name rather than one that aliases another VM.

#### Scenario: Uppercase branch

- **WHEN** the recipe name is `app-{{branch_slug}}` and branch is `Feat/X`
- **THEN** the API responds `422` and the error names `app-Feat-X` as not a valid sprite name

#### Scenario: Invalid override

- **WHEN** a run request sets `sprite` to `Demo`, `demo#1`, or `a..b`
- **THEN** the API responds `422` and no run is created

#### Scenario: Expansion lands on the former pool prefix

- **WHEN** the recipe name is `{{branch_slug}}-app` and branch is `gfp`
- **THEN** the expanded sprite name `gfp-app` is accepted

#### Scenario: Override uses the former pool prefix

- **WHEN** a run request sets `sprite` to `gfp-demo`
- **THEN** the override is accepted as the sprite name

## REMOVED Requirements

### Requirement: Expanded sprite name must be a valid sprite name

**Reason**: The `gfp-` prefix was reserved for pool members, and pools are removed. The rest of the sprite name rule is unchanged.

**Migration**: Replaced by "Expanded sprite names follow the sprite name rule", which accepts `gfp-` names and overrides.
