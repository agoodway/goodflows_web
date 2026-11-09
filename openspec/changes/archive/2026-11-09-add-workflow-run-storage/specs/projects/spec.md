# Spec Delta

## RENAMED Requirements

- FROM: `### Requirement: Recipes and test reports protect a project from deletion`
- TO: `### Requirement: Recipes, test reports, and workflow runs protect a project from deletion`

## MODIFIED Requirements

### Requirement: Recipes, test reports, and workflow runs protect a project from deletion
Deleting a project that has any recipe, test report, or workflow run MUST respond `409` and MUST keep the project and its recipes, test reports, and workflow runs. Deleting a project that has no recipes, test reports, or workflow runs MUST respond `204`, and a later show MUST respond `404`.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has no recipes, test reports, or workflow runs
- **THEN** the API responds `204` and a later show of that slug responds `404`

#### Scenario: Delete a project that has a recipe
- **WHEN** a client deletes a project that has a recipe, including a recipe whose runs have finished
- **THEN** the API responds `409` and the project and the recipe remain

#### Scenario: Delete a project with reports and no recipes
- **WHEN** a client deletes a project that has a stored test report and no recipes
- **THEN** the API responds `409` and the project and the report remain

#### Scenario: Delete a project with only a workflow run
- **WHEN** a client deletes a project whose only content is a stored workflow run
- **THEN** the API responds `409` and the project and the workflow run remain
