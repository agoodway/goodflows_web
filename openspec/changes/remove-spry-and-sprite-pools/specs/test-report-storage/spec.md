# Spec Delta

## MODIFIED Requirements

### Requirement: Successful responses acknowledge storage without returning report contents
201 and 200 responses SHALL return a stable server id, external report id, complete/incomplete status and whether the request was a duplicate. The API MUST NOT return the stored event document in acknowledgements.

#### Scenario: Storage-only ingestion
- **WHEN** a report is accepted
- **THEN** the response acknowledges it without running a job, displaying a dashboard or calculating test groups

## REMOVED Requirements

### Requirement: A test report blocks project deletion
**Reason**: With recipes gone, this rule duplicates the `projects` requirement "A project with test reports cannot be deleted", which now owns it.
**Migration**: None. Behavior is unchanged: deleting a project that has a test report still returns `409`.
