# Spec Delta

## ADDED Requirements

### Requirement: Scenario rows expand to show their details
Each row of a set's scenario table SHALL have a toggle that opens a details row directly below it and closes it again. The toggle MUST be a button that is reachable by keyboard, has an accessible name naming the scenario ID, and reports whether the row is open. A row a member opened SHALL stay open when the page refreshes on a project event, until the member closes it or leaves the page.

#### Scenario: Open a row
- **WHEN** a member clicks the toggle of diff scenario `3`
- **THEN** a details row for scenario `3` appears below its row and the toggle reports it is open

#### Scenario: Open row survives a refresh
- **WHEN** a member has opened diff scenario `3` and a project event refreshes the page
- **THEN** the details row for scenario `3` is still open

### Requirement: Details show the scenario's text from the set file
The details row SHALL show the scenario's section of the graded version's set file, without its heading line, rendered from Markdown. A section SHALL be the text under the body's `## Scenarios` heading from the scenario's `### <id>. <name>` or `#### <id>. <name>` heading to the next heading of the same or a higher level, ignoring headings in fenced code blocks.

#### Scenario: Steps and Expect lines
- **WHEN** diff scenario `2`'s section reads `### 2. Mark a todo done without changing its title (Must)`, a Why line and four numbered steps each with a nested `- Expect:` item, and its digest matches
- **THEN** the details row shows the Why line as a paragraph and the four steps as a numbered list, each with its Expect line nested under it, and not the heading

#### Scenario: Inline Markdown
- **WHEN** a step reads ``Click **Save** and enter `-1` in **Quantity**.``
- **THEN** `Save` and `Quantity` render bold and `-1` renders as code

#### Scenario: Scenario under a group heading
- **WHEN** a set groups scenarios under `### Signed in as admin` with scenario `4` under `#### 4. Revoke a key (Must)`, and its digest matches
- **THEN** scenario `4`'s details row shows the text under its `####` heading up to the next `####` or `###` heading

### Requirement: Rendered scenario text is sanitized
The rendered HTML MUST contain only the tags and attributes of the html_sanitize_ex Markdown allow list. Raw HTML in a section MUST NOT be passed through, links MUST allow only `http`, `https` and `mailto` URLs, and no script, style or event handler attribute may reach the page.

#### Scenario: Raw HTML in a section
- **WHEN** a section contains `<script>alert(1)</script>` and `<img src=x onerror=alert(1)>`
- **THEN** the details row has no `script` element, no `onerror` attribute, and runs no script

#### Scenario: Script link
- **WHEN** a section contains `[docs](javascript:alert(1))`
- **THEN** the rendered link has no `javascript:` URL

### Requirement: Scenario text is shown only when it matches its digest
The page MUST show a scenario's section only when the SHA-256 of the section, heading line included, equals the digest stored for that scenario in the version's `sections`. Otherwise the details row MUST say the scenario's text could not be matched to the set file and show no text.

#### Scenario: Digest does not match
- **WHEN** a version was uploaded by a client whose section for scenario `S2` hashes differently from the body the server splits
- **THEN** scenario `S2`'s details row says its text could not be matched to the set file and shows no text

### Requirement: Details show the run result of the scenario
The details row SHALL show, from the verify run the row's result came from, the result's failed step as `Failed at <step>` and its reason when either is set, and each artifact the result lists as evidence, in order, with its path, content type and size. An artifact whose object exists SHALL link to its download; an expired artifact MUST show `Expired` and no link. When the row has no result from a counted run, the details row SHALL say that no verify run result exists for the scenario.

#### Scenario: Failed scenario with evidence
- **WHEN** diff scenario `retry-backoff` failed in run `3b9e…` with failed step `3`, reason `Banner read "Saved"` and evidence `shot-3` (`image/png`, 120,000 bytes)
- **THEN** its details row shows `Failed at 3`, the reason, and `shot-3`'s path, `image/png` and its size, linking to its download

#### Scenario: Expired evidence
- **WHEN** a result's evidence artifact was deleted by retention
- **THEN** the artifact is listed with `Expired` and no download link

#### Scenario: No counted run
- **WHEN** the intent set is graded but no counted verify run grades it
- **THEN** each intent scenario's details row shows its text and says no verify run result exists for it

#### Scenario: Merged change request
- **WHEN** a member opens a details row on merged change request 43 whose stored verdict used run `3b9e…`
- **THEN** the row shows the text of the version and the result details of run `3b9e…` from the stored verdict

### Requirement: Members download verify run evidence from the dashboard
`GET /dashboard/accounts/:account_id/projects/:slug/verify-runs/:run_id/artifacts/:artifact_id` SHALL redirect a signed-in member of the account to a short-lived presigned download URL for that artifact of a `final` run. Presigned URLs MUST NOT appear in the detail page's HTML.

#### Scenario: Download evidence
- **WHEN** a member follows the download link of artifact `shot-3` of final run `3b9e…`
- **THEN** the server redirects to a presigned URL whose object has the artifact's declared SHA-256

### Requirement: Evidence downloads refuse what is not there or not theirs
The download route MUST respond `404` when the project, run or artifact does not exist in the account, the run is not `final`, or the artifact is expired. A user who is not a member of the account MUST be redirected to `/dashboard` and a signed-out user to log in, and nothing is presigned for either.

#### Scenario: Expired artifact
- **WHEN** a member requests an artifact that retention deleted
- **THEN** the server responds `404`

#### Scenario: Not a member
- **WHEN** a signed-in user who is not a member of the account requests an artifact URL of that account
- **THEN** the server redirects to `/dashboard` and presigns nothing
