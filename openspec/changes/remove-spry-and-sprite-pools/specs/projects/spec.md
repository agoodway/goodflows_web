# Spec Delta

## REMOVED Requirements

### Requirement: A project with recipes, test reports, or pools cannot be deleted
**Reason**: Recipes and pools no longer exist, so only test reports can block deletion. The ADDED requirement below replaces this one.
**Migration**: None. Project deletion is still refused while test reports exist. A `409` for recipes or pools can no longer happen.

## ADDED Requirements

### Requirement: A project with test reports cannot be deleted
Deleting a project that has any stored test report MUST respond `409` and MUST keep the project and its test reports. Deleting a project that has no test reports MUST respond `204`, and a later show MUST respond `404`.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has no test reports
- **THEN** the API responds `204` and a later show of that slug responds `404`

#### Scenario: Delete a project with reports
- **WHEN** a client deletes a project that has a stored test report
- **THEN** the API responds `409` and the project and the report remain
