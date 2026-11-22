## MODIFIED Requirements

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

## ADDED Requirements

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
