# qa-scenario-sets Specification

## Purpose

Stores the `qa-scenarios/2` scenario sets a change request is graded against, keeps every version, lets a person approve an intent set's exact bytes before code exists, and shows what changed between versions with weakening changes first.

## Requirements

### Requirement: Scenario set routes require a key of the account
Every route under `/api/v1/projects/:project/change-requests/:number/scenario-sets` SHALL require a valid key of the project's account. Missing, expired or revoked keys MUST get `401`. Uploading, approving and rejecting MUST require an `sk_` key; a `pk_` key MUST get `403` there. Reading MUST accept `sk_` and `pk_` keys. A `ck_` key MUST get `403` on every route. An unknown project or change request number MUST get `404`.

#### Scenario: Private key uploads a set
- **WHEN** a client with an `sk_` key uploads a valid intent set to change request 42 of project `goodcases`
- **THEN** the API responds `201` and stores version 1 of the intent set of change request 42

#### Scenario: Public key uploads a set
- **WHEN** a client with a `pk_` key uploads a scenario set
- **THEN** the API responds `403` and stores nothing

#### Scenario: Public key reads sets
- **WHEN** a client with a `pk_` key lists the scenario sets of change request 42
- **THEN** the API responds `200`

#### Scenario: Cache key
- **WHEN** a client with a `ck_` key bound to the project lists its scenario sets
- **THEN** the API responds `403`

#### Scenario: Unknown change request
- **WHEN** a client uploads a set to change request 999 and the project has no change request numbered 999
- **THEN** the API responds `404` and stores nothing

### Requirement: Sets change only on live change requests
Uploading a set version, approving or rejecting SHALL be accepted only while the change request is `draft` or `open`. On a `merged` or `closed` change request they MUST respond `409` and store nothing; this check MUST come before the `scenarios.approver` check and body field validation, so a refused approver or an invalid body still gets `409`. Reads are allowed in every state.

#### Scenario: Upload to a closed change request
- **WHEN** a client uploads an intent set to a `closed` change request
- **THEN** the API responds `409` and stores nothing

#### Scenario: Approve on a merged change request
- **WHEN** a client approves the current intent digest of a `merged` change request
- **THEN** the API responds `409` and records no decision

#### Scenario: Refused approver on a closed change request
- **WHEN** `scenarios.approver` is `other_member` and the opener approves the current intent digest of a `closed` change request
- **THEN** the API responds `409`, not `403`, and records no decision

### Requirement: A set is uploaded as the raw Markdown file
`POST /api/v1/projects/:project/change-requests/:number/scenario-sets` SHALL accept a JSON object with exactly `content` (the set file as a string) and `sections` (one entry per scenario). The server MUST store `content` byte for byte and MUST NOT reformat it. A body over 1 MiB MUST get `413`, a non-JSON content type `415`, and an unknown key `422`.

#### Scenario: Content stored as sent
- **WHEN** a client uploads `content` with CRLF line endings and trailing spaces
- **THEN** a later read of that version returns `content` with the same CRLF line endings and trailing spaces

#### Scenario: Unknown body key
- **WHEN** an upload body has a `digest` key besides `content` and `sections`
- **THEN** the API responds `422` with `has an unknown field` on `body` and stores nothing

#### Scenario: Oversized set
- **WHEN** a client uploads a body of 1,048,577 bytes
- **THEN** the API responds `413` and stores nothing

### Requirement: The set digest covers the raw bytes
The set digest SHALL be the lowercase hex SHA-256 of the UTF-8 bytes of `content`. Any change to `content`, including whitespace only, MUST give a different digest. Every version response MUST include `digest`.

#### Scenario: Whitespace edit
- **WHEN** version 1 of an intent set has digest `d1` and the client uploads the same file with one trailing newline added
- **THEN** the API responds `201` with version 2 and a digest different from `d1`

### Requirement: The server parses only the front matter
`content` MUST start with a YAML front matter block between a first line `---` and the next line `---`. The server SHALL parse only that block and MUST NOT interpret the Markdown body. Content without a front matter block, or with front matter that is not a YAML mapping, MUST get `422` on `content`. Validation errors MUST NOT echo submitted values.

#### Scenario: No front matter
- **WHEN** a client uploads `content` that starts with `# QA scenarios`
- **THEN** the API responds `422` with an error on `content` and stores nothing

#### Scenario: Body is not read
- **WHEN** the Markdown body names a scenario `S9` that the front matter does not list
- **THEN** the API stores the set and its scenarios are only those in the front matter

### Requirement: Front matter follows qa-scenarios/2
The front matter MUST have `format` `qa-scenarios/2`, `source` `intent` or `diff`, and `scenarios`, and MAY have `review` (null, or a string of 1 to 2,048 bytes naming a goodflows change request or a pull or merge request URL, stored as given). Any other `format` MUST get `422` on `content.format`. The server MUST NOT check key order. A key not allowed for the set's `source` MUST get `422` on `content`.

#### Scenario: Unsupported format
- **WHEN** the front matter has `format: qa-scenarios/1`
- **THEN** the API responds `422` with an error on `content.format` and stores nothing

#### Scenario: Review link stored
- **WHEN** a diff set has `review: "https://github.com/acme/web/pull/12"`
- **THEN** the API responds `201` and the parsed front matter has that `review`

#### Scenario: Diff key on an intent set
- **WHEN** an intent set's front matter has `revision`
- **THEN** the API responds `422` with `has an unknown field` on `content` and stores nothing

### Requirement: Scenario entries are validated
`scenarios` MUST hold 1 to 200 entries of `id`, `name` (1 to 200 characters) and `priority` (`must`, `should` or `could`); an intent set's entry MAY also have `covers`. An `id` MUST be an integer of at least 1 or a string; its string form (decimal for an integer) MUST match `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` and be unique in the set. Any other entry key, except the run-result keys refused below, MUST get `422` on `content.scenarios`.

#### Scenario: Integer id
- **WHEN** a set has a scenario with `id: 1`, `name: "Export a report"` and `priority: must`, and `sections` has an entry with `id` `"1"`
- **THEN** the API responds `201` and stores the scenario with ID `"1"`

#### Scenario: Duplicate scenario id
- **WHEN** two `scenarios` entries have `id` `S1`
- **THEN** the API responds `422` with an error on `content.scenarios`

#### Scenario: Duplicate after string conversion
- **WHEN** one scenario has `id: 1` and another has `id: "1"`
- **THEN** the API responds `422` with an error on `content.scenarios`

#### Scenario: Zero id
- **WHEN** a scenario has `id: 0`
- **THEN** the API responds `422` with an error on `content.scenarios`

#### Scenario: Unknown priority
- **WHEN** a scenario has `priority: blocker`
- **THEN** the API responds `422` with an error on `content.scenarios`

#### Scenario: Long name
- **WHEN** a scenario's `name` has 201 characters
- **THEN** the API responds `422` with an error on `content.scenarios`

### Requirement: Scenario IDs are compared as strings
The server SHALL store a scenario ID in its string form and SHALL compare scenario IDs only in that form: in `sections`, coverage row `scenarios`, verify-run `results`, comparisons and verdict subjects. Responses MUST return scenario IDs as strings.

#### Scenario: Run names an integer scenario as a string
- **WHEN** a set has scenario `id: 3` and a verify run has a result with `id` `"3"`
- **THEN** the run's result is matched to scenario `"3"`

### Requirement: Intent scenarios may name what they cover
An intent scenario's `covers`, when present, MUST be a list of 1 to 100 entries, each `{capability, requirement, scenario}` or `{capability, requirement, implied: true}`, with exactly one of `scenario` or `implied` and each string 1 to 200 characters. The server SHALL store `covers` as given and MUST NOT grade it. A diff set scenario with `covers` MUST get `422` on `content.scenarios`.

#### Scenario: Implied coverage
- **WHEN** an intent scenario has `covers: [{capability: exports, requirement: "Export is audited", implied: true}]`
- **THEN** the API responds `201` and stores `covers` as given

#### Scenario: Both scenario and implied
- **WHEN** a `covers` entry has both `scenario` and `implied: true`
- **THEN** the API responds `422` with an error on `content.scenarios`

### Requirement: Intent sets name the change and the specs
An intent set MUST have `change` and `specs`, and MAY have `coverage`. `specs` MUST be `uncommitted` or 7 to 64 lowercase hex characters. The server SHALL store `specs` as given and MUST NOT check it against any commit.

#### Scenario: Uncommitted specs
- **WHEN** an intent set has `specs: uncommitted`
- **THEN** the API responds `201` and stores the set

#### Scenario: Missing specs
- **WHEN** an intent set has no `specs` key
- **THEN** the API responds `422` with an error on `content.specs`

### Requirement: Diff sets name the branch, base and revision
A diff set MUST have `branch` and `base`, each a string of 1 to 255 bytes stored as given, and `revision`, and MAY have `regressions`: at most 200 strings of 1 to 1,000 characters.

#### Scenario: Diff set with regressions
- **WHEN** a diff set has `branch: feat/export`, `base: main`, a `revision` and `regressions: ["Old CSV export still downloads"]`
- **THEN** the API responds `201` and stores the regressions

#### Scenario: Missing base
- **WHEN** a diff set has no `base` key
- **THEN** the API responds `422` with an error on `content.base`

### Requirement: Run results are never part of a set
A set whose front matter has a top-level `run` key, or a scenario entry with `result`, `failed_step`, `evidence` or `reason`, MUST get `422` on `content` with a message saying run results belong in a verify run, and MUST store nothing. A coverage row's `reason` is not a run result.

#### Scenario: Set file with results written in
- **WHEN** a scenario entry has `result: passed`
- **THEN** the API responds `422` on `content` with a message that run results belong in a verify run

#### Scenario: Run block
- **WHEN** the front matter has a top-level `run` key
- **THEN** the API responds `422` on `content` and stores nothing

### Requirement: Intent coverage rows name requirements
An intent set's `coverage`, when present, MUST be a list of entries with `capability`, `requirement` and `scenario` (OpenSpec names, each 1 to 200 characters, never checked against specs), `status` (`covered` or `no_check`), `scenarios` (QA scenario IDs of the set, under the ID rule; empty for `no_check`), and an optional `reason` of at most 1,000 characters. A `covered` row MUST name at least one scenario. `{capability, requirement, scenario}` MUST be unique per set.

#### Scenario: Spec gap row
- **WHEN** an intent set has a coverage row `{capability: exports, requirement: "Export is audited", scenario: "Audit entry written", status: no_check, scenarios: [], reason: "Needs a log reader"}`
- **THEN** the API responds `201` and stores the row

#### Scenario: Removed requirement row
- **WHEN** a coverage row has `scenario: "[Export is audited] removed"`
- **THEN** the API responds `201` and stores the row with that `scenario` as an ordinary string

#### Scenario: Integer scenario IDs in a row
- **WHEN** a `covered` row has `scenarios: [1, 2]` and the set has scenarios with `id` 1 and 2
- **THEN** the API responds `201` and stores the row's scenarios as `"1"` and `"2"`

#### Scenario: Row without a capability
- **WHEN** a coverage row has `requirement` and `scenario` but no `capability`
- **THEN** the API responds `422` with an error on `content.coverage`

#### Scenario: Row names an unknown scenario
- **WHEN** a `covered` row lists scenario `S7` and the set has no scenario `S7`
- **THEN** the API responds `422` with an error on `content.coverage`

### Requirement: Section digests match the scenario IDs
`sections` MUST hold exactly one entry `{id, sha256}` for each scenario ID in the front matter, with `sha256` 64 lowercase hex characters. A missing, extra or duplicate ID MUST get `422` on `sections`. The server SHALL store the section digests as sent and MUST NOT check them against the body.

#### Scenario: Missing section digest
- **WHEN** the front matter lists `S1`, `S2` and `S3` and `sections` has entries only for `S1` and `S2`
- **THEN** the API responds `422` with an error on `sections` and stores nothing

#### Scenario: Uppercase digest
- **WHEN** a `sections` entry has a `sha256` in uppercase hex
- **THEN** the API responds `422` with an error on `sections`

### Requirement: An intent set belongs to the linked OpenSpec change
An intent set's `change` MUST equal the change request's linked OpenSpec change ID. A change request with no linked change MUST get `422` on `content.change` for an intent upload. A change request SHALL have at most one intent set, versioned.

#### Scenario: Wrong change
- **WHEN** change request 42 links `add-export` and a client uploads an intent set with `change: add-import`
- **THEN** the API responds `422` with an error on `content.change` and stores nothing

#### Scenario: No linked change
- **WHEN** change request 43 has no linked OpenSpec change and a client uploads an intent set
- **THEN** the API responds `422` with an error on `content.change`

### Requirement: A diff set names a revision
A diff set's `revision` MUST be 7 to 64 lowercase hex characters: a full commit or a prefix of one, as the goodstack template writes a short SHA. The server SHALL store a diff set whatever its `revision`; whether it names the head is a verdict rule. A change request SHALL have at most one diff set, versioned.

#### Scenario: Diff set for an older commit
- **WHEN** the head of change request 42 is `bbbb…` and a client uploads a diff set with `revision` `aaaa…`
- **THEN** the API responds `201` and stores the version

#### Scenario: Short SHA revision
- **WHEN** a diff set has `revision: abc1234`
- **THEN** the API responds `201` and stores `revision` as `abc1234`

#### Scenario: Revision too short
- **WHEN** a diff set has `revision: abc12`
- **THEN** the API responds `422` with an error on `content.revision`

### Requirement: Every version of a set is kept
Each accepted upload with a digest different from the current version's SHALL create the next version (1, 2, …) of that change request's intent or diff set, recording the membership, key and time. The newest version is current. An upload whose digest equals the current version's MUST respond `200` with `duplicate` true and create no version. Versions are immutable and no route deletes one.

#### Scenario: New version
- **WHEN** the intent set of change request 42 is at version 2 and a client uploads an edited file
- **THEN** the API responds `201` with `version` 3, and versions 1 and 2 are still readable

#### Scenario: Exact retry
- **WHEN** a client uploads the file of the current version again
- **THEN** the API responds `200` with `duplicate` true and the same `version` and `digest`

#### Scenario: Return to an older file
- **WHEN** version 1 had digest `d1`, version 2 has digest `d2`, and a client uploads the file of version 1
- **THEN** the API responds `201` with `version` 3 and `digest` `d1`

### Requirement: Read scenario set versions
`GET …/scenario-sets` SHALL return, for `intent` and `diff`, the current version and a list of versions with `version`, `digest`, `inserted_at`, `approved` and `accepted`. `GET …/scenario-sets/:source/versions/:version` SHALL return that version with `content`, the parsed front matter, `sections`, `digest`, `approved`, `accepted` and the decisions on its digest. An unknown version MUST get `404`.

#### Scenario: Read a version
- **WHEN** a client reads `/scenario-sets/intent/versions/2`
- **THEN** the API responds `200` with version 2's `content`, `digest`, scenarios and section digests

#### Scenario: Missing version
- **WHEN** the diff set has one version and a client reads `/scenario-sets/diff/versions/2`
- **THEN** the API responds `404`

#### Scenario: Accepted diff version
- **WHEN** diff version 2's digest has a latest decision of `approve` and a client reads `/scenario-sets/diff/versions/2`
- **THEN** the version has `accepted` true, `approved` false, and that decision

### Requirement: Public keys see scenario sets without content
For a `pk_` key, every scenario set read SHALL return `content`, `front_matter` and `sections` null. `source`, `version`, `digest`, `inserted_at`, `approved`, `accepted`, and each scenario's `id` and `priority` MUST be as stored; decisions follow their own redaction. A field absent from a response MUST NOT be added, and stored versions MUST NOT change.

#### Scenario: Public key reads a version
- **WHEN** a client with a `pk_` key reads `/scenario-sets/intent/versions/2`
- **THEN** the API responds `200` with `content`, `front_matter` and `sections` null, and version 2's `source`, `version`, `digest`, `approved` and scenario IDs with priorities as stored, and a later `sk_` read returns `content`, `front_matter` and `sections`

#### Scenario: Public key lists sets
- **WHEN** a client with a `pk_` key lists the scenario sets of change request 42
- **THEN** each version has its `version`, `digest`, `approved` and `accepted` as stored

### Requirement: Approve or reject an intent set digest
`POST …/scenario-sets/intent/approvals` with `{"digest": "<sha256>"}` SHALL record an `approve` decision, and `POST …/scenario-sets/intent/rejections` with `{"digest": "<sha256>", "note": "<1 to 10,000 bytes>"}` a `reject` decision, on that digest when it is the current intent version's digest, responding `201`. A digest of an older version, or of no version, MUST get `409`. Both routes under `…/scenario-sets/diff/` MUST get `404`; diff digests take decisions only through `diff_set_weakened` answers.

#### Scenario: Approve the current version
- **WHEN** the current intent version has digest `d2` and a client approves `d2`
- **THEN** the API responds `201` and version 2 reads as `approved` true

#### Scenario: Approve a stale digest
- **WHEN** the current intent version has digest `d3` and a client approves `d2`
- **THEN** the API responds `409` and records no decision

#### Scenario: Reject without a note
- **WHEN** a client rejects the current digest with no `note`
- **THEN** the API responds `422` with an error on `note`

#### Scenario: Approve a diff set
- **WHEN** a client posts an approval to `/scenario-sets/diff/approvals`
- **THEN** the API responds `404`

### Requirement: A digest is approved when its latest decision is approve
Decisions SHALL be kept per change request and digest, oldest first. A digest is approved for the change request only when its latest decision is `approve`. A rejection MUST make an approved digest unapproved until a later `approve` decision on the same digest.

#### Scenario: Reject after approve
- **WHEN** membership M approves `d2` and membership N then rejects `d2`
- **THEN** the current version with `d2` reads as `approved` false

#### Scenario: Approve after reject
- **WHEN** `d2` was rejected and a client then approves `d2`
- **THEN** the version reads as `approved` true

### Requirement: Decisions record who decided and how
Each decision SHALL store `decision` (`approve` or `reject`), the membership, the key, the digest, the `note` (null for approvals), the time, and the `channel`. A decision with the `decision` and `note` of the digest's latest decision, when that was made by the same membership, MUST respond `200` and add no row. Decision responses MUST include `decision`, `digest`, `note`, `decided_by` (with `user_id`), `decided_at` and `channel`.

#### Scenario: Approval record
- **WHEN** membership M approves digest `d2` with key K
- **THEN** the response has `decision` `approve`, `digest` `d2`, `decided_by.user_id` M's user id and `channel` `cli`, and the stored row names key K

#### Scenario: Repeated approval
- **WHEN** membership M approves `d2` twice
- **THEN** the first responds `201`, the second `200`, and one decision row exists

#### Scenario: Approval again after another member's rejection
- **WHEN** membership M approves `d2`, membership N rejects `d2`, and M approves `d2` again
- **THEN** the third decision responds `201`, three decision rows exist, and `d2` reads as approved

#### Scenario: Rejection with a different note
- **WHEN** membership M rejects `d2` with note `first`, again with note `first`, then with note `second`
- **THEN** the responses are `201`, `200` and `201`, and two decision rows exist

#### Scenario: Rejection record
- **WHEN** membership M rejects `d2` with note `S2 tests the wrong path`
- **THEN** the response has `decision` `reject` and that `note`, and the row names M, the key, `d2`, the time and `channel` `cli`

#### Scenario: Public key reads decisions
- **WHEN** a client with a `pk_` key reads a version with a rejection
- **THEN** that decision has `note` null and `decided_by.user_id` null

### Requirement: The approver setting decides who may decide
The approval and rejection routes SHALL apply `scenarios.approver` from the project's current review policy when the decision is made: `any` allows any `sk_` key of the account, `other_member` allows a membership other than the one that opened the change request, and `admin` allows an owner or admin membership. A refused key MUST get `403` and record nothing.

#### Scenario: Author approves under other_member
- **WHEN** the policy has `approver = "other_member"` and the membership that opened change request 42 approves its intent set
- **THEN** the API responds `403` and records no approval

#### Scenario: Teammate approves under other_member
- **WHEN** the policy has `approver = "other_member"` and another member's `sk_` key approves
- **THEN** the API responds `201`

#### Scenario: Member approves under admin
- **WHEN** the policy has `approver = "admin"` and a key of a `member` role approves
- **THEN** the API responds `403`

#### Scenario: Default approver
- **WHEN** the project has no policy and the author's own key approves
- **THEN** the API responds `201`, because version 0 has `approver = "any"`

### Requirement: An approval binds to the digest, not the head
A digest's decisions SHALL apply to every intent or diff version of that change request with that digest, whatever the head. A new head MUST NOT clear them. A version with a different digest MUST read as `approved` false, or for a diff version `accepted` false, until that digest is approved or accepted.

#### Scenario: Push after approval
- **WHEN** digest `d1` is approved and the client reports `git-facts` for a new head
- **THEN** the intent set still reads as `approved` true

#### Scenario: Edit after approval
- **WHEN** digest `d1` is approved and a client uploads version 2 with digest `d2`
- **THEN** version 2 reads as `approved` false

#### Scenario: Revert to the approved file
- **WHEN** `d1` was approved, version 2 has `d2`, and version 3 is uploaded with `d1`
- **THEN** version 3 reads as `approved` true without a new approval

#### Scenario: Push after diff acceptance
- **WHEN** diff digest `d2` is accepted and the client reports `git-facts` for a docs-only new head
- **THEN** the diff version with `d2` still reads as `accepted` true

### Requirement: Compare set versions by scenario ID
`GET …/scenario-sets/:source/compare` SHALL compare version `to` (default current) with version `from` (default: for `intent`, the newest approved version; for `diff`, the previous version) and return `changes` entries of `id`, `change` (`removed`, `demoted`, `changed`, `added`), `weakening`, `from_priority` and `to_priority`. It MUST compare only section digests and priorities.

#### Scenario: Edited section
- **WHEN** scenario `S2` has a different section digest in `to` than in `from` and the same priority
- **THEN** `changes` has `{id: "S2", change: "changed", weakening: false}`

#### Scenario: Added scenario
- **WHEN** `to` has scenario `S6` and `from` does not
- **THEN** `changes` has `{id: "S6", change: "added", weakening: false}`

#### Scenario: Nothing to compare against
- **WHEN** the intent set has no approved version and the client omits `from`
- **THEN** the API responds `200` and every scenario of `to` is listed as `added`

#### Scenario: Unchanged scenario
- **WHEN** `S1` has the same section digest and priority in both versions
- **THEN** `changes` has no entry for `S1`

### Requirement: Weakening changes are listed first
A Must scenario removed, or demoted from `must` to `should` or `could`, SHALL have `weakening` true. `changes` MUST list weakening entries first, then other removals, then `changed` (a new section digest or a non-weakening priority change), then `added`, each group ordered by `id`.

#### Scenario: Removed Must first
- **WHEN** `to` adds `S6`, changes `S2`, and drops Must scenario `S4`
- **THEN** `changes` lists `S4` (`removed`, `weakening` true) first, then `S2`, then `S6`

#### Scenario: Demoted Must
- **WHEN** `S3` is `must` in `from` and `should` in `to`
- **THEN** `changes` has `{id: "S3", change: "demoted", weakening: true, from_priority: "must", to_priority: "should"}` before any non-weakening entry

#### Scenario: Should demoted to Could
- **WHEN** `S5` is `should` in `from` and `could` in `to`
- **THEN** `S5` is listed as `changed` with `weakening` false

### Requirement: Scenario set routes are in the OpenAPI document
Every scenario set route SHALL be described in the OpenAPI document with its request body, responses and status codes.

#### Scenario: OpenAPI lists the routes
- **WHEN** a client fetches the OpenAPI document
- **THEN** it describes upload, list, show version, approve, reject and compare under `/api/v1/projects/{project}/change-requests/{number}/scenario-sets`

### Requirement: Diff digests take decisions only through review answers
A diff digest's decisions SHALL be recorded only by `diff_set_weakened` answers, under the decision rules of intent digests: kept oldest first, one equal to the same membership's latest decision on the digest adds no row, and the digest's latest decision decides. A diff version is `accepted` when its digest's latest decision is `approve`; its `approved` MUST stay false. An intent version's `accepted` MUST equal its `approved`.

#### Scenario: Diff routes stay closed
- **WHEN** a client posts `{"digest": "<current diff digest>"}` to `/scenario-sets/diff/approvals`
- **THEN** the API responds `404` and records no decision

#### Scenario: Acceptance recorded through an answer
- **WHEN** an allowed member's answer accepts the weakened diff digest `d2`
- **THEN** reading the diff version with `d2` shows `accepted` true and a decision `approve` with `channel` `cli`

#### Scenario: Intent version accepted
- **WHEN** an intent version's digest is approved
- **THEN** that version reads `approved` true and `accepted` true

### Requirement: Decisions record their channel
A decision's `channel` SHALL be `cli` for every decision made through the API, and `dashboard`, with the key null, for a decision recorded by a review answer made in the dashboard.

#### Scenario: Approval from the dashboard
- **WHEN** membership M approves the `scenario_set_approval` item for digest `d2` in the dashboard
- **THEN** `d2` reads as approved, and its decision names M, has no key, and has `channel` `dashboard`
