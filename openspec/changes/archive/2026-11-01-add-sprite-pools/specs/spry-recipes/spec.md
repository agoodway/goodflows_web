# Spec Delta

## MODIFIED Requirements

### Requirement: Recipe names are valid sprite name templates

The `name` is the template for the sprite name, and its literal text MUST be able to form a valid sprite name: lowercase letters, digits, and hyphens, starting with a letter or digit, at most 63 characters when each placeholder is counted as one character. A name violating this MUST be rejected with `422` on `name` when the recipe is saved. A name whose literal text starts with `gfp-` MUST be rejected with `422` on `name`, because that prefix is reserved for pool members. Because the rule is lowercase-only, names differing only by case can never refer to the same VM. Recipes SHOULD use `{{branch_slug}}` rather than `{{branch}}`.

#### Scenario: Invalid literal name

- **WHEN** a client saves a recipe whose `name` is `App`, `app#1`, `a..b`, `-app`, or longer than 63 characters
- **THEN** the API responds `422` with an error on `name` describing the sprite name rule

#### Scenario: Template with valid literal parts

- **WHEN** a client saves a recipe whose `name` is `app-{{branch_slug}}`
- **THEN** the API responds `201`

#### Scenario: Reserved pool prefix

- **WHEN** a client saves a recipe whose `name` is `gfp-{{branch_slug}}` or `gfp-app`
- **THEN** the API responds `422` with an error on `name` stating that `gfp-` is reserved
