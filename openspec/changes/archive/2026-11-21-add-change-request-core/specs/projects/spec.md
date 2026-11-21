# projects Delta

## MODIFIED Requirements

### Requirement: Recipes, test reports, and workflow runs protect a project from deletion
Deleting a project that has any recipe, test report, workflow run, or change request in any state MUST respond `409` and MUST keep the project and all its content. Deleting a project with none of them MUST respond `204`, and a later show MUST respond `404`. Review policy versions, cache entries, cache reservations and cache keys MUST NOT block deletion: they are deleted with the project, and cache objects are queued for deletion from object storage.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has no recipes, test reports, workflow runs, or change requests
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

#### Scenario: Delete a project with only a change request
- **WHEN** a client deletes a project whose only content is change request `1` in state `closed`
- **THEN** the API responds `409` and the project and change request `1` remain

#### Scenario: Delete a project with only a review policy
- **WHEN** a client deletes a project whose only content is review policy versions `1` and `2`
- **THEN** the API responds `204`, a later show of that slug responds `404`, and the policy versions are gone

#### Scenario: Delete a project with only caches
- **WHEN** a client deletes a project whose only content is committed cache entries and a cache key
- **THEN** the API responds `204`, the cache key gets `401` on its next request, and the entries' objects are deleted by the next sweep
