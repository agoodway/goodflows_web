# Spec Delta

## ADDED Requirements

### Requirement: Recipe names follow the sprite name rule

Replacing each placeholder in the `name` sprite-name template with one valid character MUST yield a name of at most 63 lowercase letters, digits, and hyphens, starting with a letter or digit. Invalid templates MUST return `422` on `name` when saved. No prefix is reserved. Lowercase-only names prevent case aliases of a VM. Recipes SHOULD use `{{branch_slug}}` rather than `{{branch}}`.

#### Scenario: Invalid literal name

- **WHEN** a client saves a recipe whose `name` is `App`, `app#1`, `a..b`, `-app`, or longer than 63 characters
- **THEN** the API responds `422` with an error on `name` describing the sprite name rule

#### Scenario: Template with valid literal parts

- **WHEN** a client saves a recipe whose `name` is `app-{{branch_slug}}`
- **THEN** the API responds `201`

#### Scenario: Former pool prefix is allowed

- **WHEN** a client saves a recipe whose `name` is `gfp-{{branch_slug}}` or `gfp-app`
- **THEN** the API responds `201`

## REMOVED Requirements

### Requirement: Recipe names are valid sprite name templates

**Reason**: The `gfp-` prefix was reserved for pool members, and pools are removed. The rest of the sprite name rule is unchanged.

**Migration**: Replaced by "Recipe names follow the sprite name rule", which accepts `gfp-` names. No existing recipe is affected.
