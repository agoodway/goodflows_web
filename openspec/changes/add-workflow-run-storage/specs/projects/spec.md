# Spec Delta

## RENAMED Requirements

- FROM: `### Requirement: A project with recipes, test reports, or pools cannot be deleted`
- TO: `### Requirement: A project with recipes, test reports, workflow runs, or pools cannot be deleted`

## MODIFIED Requirements

### Requirement: A project with recipes, test reports, workflow runs, or pools cannot be deleted
Deleting a project that has any recipe, test report, workflow run, or pool (including a pool still being deleted) MUST respond `409` and MUST keep the project and its recipes, test reports, workflow runs, and pools. Deleting a project that has no recipes, test reports, workflow runs, or pools MUST respond `204`, and a later show MUST respond `404`.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has no recipes, test reports, workflow runs, or pools
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

#### Scenario: Delete a project with only a pool
- **WHEN** a client deletes a project whose only content is a pool
- **THEN** the API responds `409` and the project and the pool remain

#### Scenario: Delete a project whose pool is being deleted
- **WHEN** a client deletes a project whose only pool was deleted (`202`) but whose member sprites are still being destroyed
- **THEN** the API responds `409` and the project remains
