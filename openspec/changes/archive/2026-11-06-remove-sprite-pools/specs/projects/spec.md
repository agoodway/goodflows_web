# Spec Delta

## ADDED Requirements

### Requirement: Recipes and test reports protect a project from deletion
Deleting a project that has any recipe or test report MUST respond `409` and MUST keep the project and its recipes and test reports. Deleting a project that has no recipes or test reports MUST respond `204`, and a later show MUST respond `404`.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has no recipes or test reports
- **THEN** the API responds `204` and a later show of that slug responds `404`

#### Scenario: Delete a project that has a recipe
- **WHEN** a client deletes a project that has a recipe, including a recipe whose runs have finished
- **THEN** the API responds `409` and the project and the recipe remain

#### Scenario: Delete a project with reports and no recipes
- **WHEN** a client deletes a project that has a stored test report and no recipes
- **THEN** the API responds `409` and the project and the report remain

## REMOVED Requirements

### Requirement: A project with recipes, test reports, or pools cannot be deleted

**Reason**: Sprite pools are removed, so a pool can no longer block project deletion. The rule for recipes and test reports is unchanged.

**Migration**: Replaced by "Recipes and test reports protect a project from deletion". Clients need no change, because no pool can exist.
