# Spec Delta

## RENAMED Requirements

- FROM: `### Requirement: A project with recipes cannot be deleted`
- TO: `### Requirement: A project with recipes or test reports cannot be deleted`

## MODIFIED Requirements

### Requirement: A project with recipes or test reports cannot be deleted
Deleting a project that has any recipe or test report MUST respond `409` and MUST keep the project and its recipes and test reports. Deleting a project that has neither recipes nor test reports MUST respond `204`, and a later show MUST respond `404`.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has neither recipes nor test reports
- **THEN** the API responds `204` and a later show of that slug responds `404`

#### Scenario: Delete a project that has a recipe
- **WHEN** a client deletes a project that has a recipe, including a recipe whose runs have finished
- **THEN** the API responds `409` and the project and the recipe remain

#### Scenario: Delete a project with reports and no recipes
- **WHEN** a client deletes a project that has a stored test report and no recipes
- **THEN** the API responds `409` and the project and the report remain
