# Spec Delta

## ADDED Requirements

### Requirement: Only the dashboard reads a set's body
The dashboard MAY split a stored version's Markdown body into scenario sections for display. That split MUST NOT change what an upload accepts, what is stored, or any digest, and uploads SHALL keep parsing only the front matter.

#### Scenario: Body without a Scenarios heading
- **WHEN** a client uploads a set whose body has no `## Scenarios` heading, with valid front matter and sections
- **THEN** the API responds `201` and stores the set as sent
