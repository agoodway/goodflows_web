# Spec Delta

## MODIFIED Requirements

### Requirement: Recipes, test reports, and workflow runs protect a project from deletion
Deleting a project that has any recipe, test report, workflow run, change request in any state, or verify run in any status MUST respond `409` and keep all of them. Otherwise it MUST respond `204`, and a later show MUST respond `404`. Scenario set versions go with their change requests. Review policy versions, feature index versions, cache entries, reservations and keys MUST NOT block deletion: they are deleted with the project and their objects queued for deletion.

#### Scenario: Delete an empty project
- **WHEN** a client deletes a project that has no recipes, test reports, workflow runs, change requests, or verify runs
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

#### Scenario: Delete a project with only a verify run
- **WHEN** a client deletes a project whose only content is a final verify run
- **THEN** the API responds `409` and the project and the verify run remain

#### Scenario: Delete a project with a verify run whose artifacts expired
- **WHEN** a client deletes a project whose only content is a verify run whose artifacts all have `expired` true
- **THEN** the API responds `409`, because the run document still blocks deletion

#### Scenario: Delete a project with only a feature index
- **WHEN** a client deletes a project whose only content is three feature index versions
- **THEN** the API responds `204` and the feature index versions are deleted

#### Scenario: Uploading verify run
- **WHEN** a client deletes a project whose only content is a verify run with `status` `uploading`
- **THEN** the API responds `409` until the sweep deletes the expired run, after which deletion responds `204`
