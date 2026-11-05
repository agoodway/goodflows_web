# Spec Delta

## ADDED Requirements

### Requirement: Recipe names follow the sprite name rule

The `name` is the template for the sprite name, and its literal text MUST be able to form a valid sprite name: lowercase letters, digits, and hyphens, starting with a letter or digit, at most 63 characters when each placeholder is counted as one character. A name violating this MUST be rejected with `422` on `name` when the recipe is saved. No prefix is reserved. Because the rule is lowercase-only, names differing only by case can never refer to the same VM. Recipes SHOULD use `{{branch_slug}}` rather than `{{branch}}`.

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
