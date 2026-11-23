# review-calibration Specification

## Purpose

Records defects found after change requests merged and serves a read-only calibration report of merges and defects by lane, policy version, rule and path glob, so admins can judge whether the review policy lets defects through.

## Requirements

### Requirement: Recording a defect requires a private key

`POST /api/v1/projects/:project/defects` SHALL require a valid `sk_` key of the project's account. Missing, expired or revoked keys MUST return `401`, `pk_` and `ck_` keys `403`, and an unknown project `404`. A stored defect SHALL record the membership and key that wrote it and the time, and the API MUST respond `201` with the defect.

#### Scenario: Private key records a defect

- **WHEN** a client with an `sk_` key posts `{"change_request": 42, "severity": "high", "ticket": "GOO-512"}` to `/api/v1/projects/goodcases/defects`
- **THEN** the API responds `201` with `id`, `change_request: 42`, `commit: null`, `severity: "high"`, `ticket: "GOO-512"`, `attribution: "change_request"`, and `recorded_at`

#### Scenario: Public key

- **WHEN** a client with a `pk_` key posts a defect
- **THEN** the API responds `403` and stores nothing

#### Scenario: Cache key

- **WHEN** a client with a `ck_` key bound to the project posts a defect, lists defects, or reads the calibration report
- **THEN** the API responds `403`

### Requirement: A defect names exactly one change request or commit

A defect body SHALL carry exactly one of `change_request` (a change request number of the project) or `commit` (a SHA of 40 or 64 lowercase hex characters). Both or neither MUST return `422` on `body`. A `change_request` number the project does not have MUST return `422` on `change_request`. Unknown keys MUST return `422`.

#### Scenario: Both targets

- **WHEN** a client posts `{"change_request": 42, "commit": "c3d4e5f…"}`
- **THEN** the API responds `422` with an error on `body` and stores nothing

#### Scenario: Neither target

- **WHEN** a client posts `{"severity": "low"}`
- **THEN** the API responds `422` with an error on `body` and stores nothing

#### Scenario: Unknown change request number

- **WHEN** a client posts `{"change_request": 999}` to a project whose highest number is 60
- **THEN** the API responds `422` with an error on `change_request` and stores nothing

#### Scenario: Malformed commit

- **WHEN** a client posts `{"commit": "HEAD~1"}`
- **THEN** the API responds `422` with an error on `commit` and stores nothing

### Requirement: Defect severity and ticket are optional

`severity` SHALL be one of `low`, `medium`, `high` or `critical` when present; any other value MUST return `422` on `severity`. `ticket` SHALL be a non-empty string of at most 200 characters when present. Both default to null and are stored as given.

#### Scenario: Unknown severity

- **WHEN** a client posts a defect with `severity: "blocker"`
- **THEN** the API responds `422` with an error on `severity` and stores nothing

#### Scenario: No severity or ticket

- **WHEN** a client posts `{"change_request": 42}`
- **THEN** the API responds `201` with `severity: null` and `ticket: null`

### Requirement: A commit is attributed to the earliest merged change request that contains it

For a defect naming `commit`, the server SHALL search the `merged_commit` and the commits of the `git-facts` report for the merged head of every `merged` change request of the project, so the commit a squash or rebase merge created on the target branch also matches. One match attributes the defect to that change request; several match the one with the earliest `merged_at`; none stores it with `change_request: null` and `attribution: "unattributed"`. Attribution is fixed when the defect is stored.

#### Scenario: One match

- **WHEN** CR 42 is `merged` and its merged head's `git-facts` lists commit `c3d4e5f`, and a client posts `{"commit": "c3d4e5f…"}`
- **THEN** the API responds `201` with `change_request: 42` and `attribution: "commit"`

#### Scenario: Merged commit of a rebase merge

- **WHEN** CR 42 was rebase merged and reported with `merged_commit` `f6a7b8c`, which its `git-facts` does not list, and a client posts `{"commit": "f6a7b8c…"}`
- **THEN** the API responds `201` with `change_request: 42` and `attribution: "commit"`

#### Scenario: Several matches

- **WHEN** commit `c3d4e5f` is listed in the merged heads' `git-facts` of CR 41 merged at `2026-11-02T10:00:00Z` and CR 42 merged at `2026-11-03T09:00:00Z`
- **THEN** the defect for `c3d4e5f` is stored with `change_request: 41`

#### Scenario: No match

- **WHEN** no merged change request's `git-facts` lists commit `d4e5f6a`
- **THEN** the API responds `201` with `change_request: null` and `attribution: "unattributed"`

#### Scenario: Open change request contains the commit

- **WHEN** commit `e5f6a7b` is listed only in the `git-facts` of CR 57, which is `open`
- **THEN** the defect is stored with `attribution: "unattributed"`

### Requirement: Defects can be listed

`GET /api/v1/projects/:project/defects` SHALL accept any valid `sk_` or `pk_` key of the account, with `ck_` keys getting `403`, and return the project's defects newest first, paged with a keyset `cursor` and `limit` (default 50, at most 200). For a `pk_` key `ticket` MUST be null.

#### Scenario: List with a public key

- **WHEN** a project has a defect with `ticket: "GOO-512"` and a client with a `pk_` key lists defects
- **THEN** the API responds `200` and that defect has `ticket: null`

#### Scenario: Next page

- **WHEN** a project has 60 defects and a client lists with `limit=50`
- **THEN** the response holds 50 defects and a `next_cursor` that returns the remaining 10

### Requirement: The calibration report covers a time window

`GET /api/v1/projects/:project/calibration` SHALL accept any valid `sk_` or `pk_` key of the account (`ck_` keys get `403`) and optional ISO 8601 `from` and `to` (default `to` now, `from` 90 days before `to`). It covers change requests whose `merged_at` is in `[from, to)` and the defects attributed to them, whenever recorded. `from` not before `to` MUST return `422`.

#### Scenario: Default window

- **WHEN** a client requests the report on `2026-11-21T00:00:00Z` with no parameters
- **THEN** the report's `from` is `2026-08-23T00:00:00Z` and `to` is `2026-11-21T00:00:00Z`

#### Scenario: Defect recorded after the window

- **WHEN** CR 42 merged inside the window and a defect attributed to CR 42 was recorded after `to`
- **THEN** the report counts that defect for CR 42

#### Scenario: Reversed window

- **WHEN** a client requests `from=2026-11-10T00:00:00Z&to=2026-11-01T00:00:00Z`
- **THEN** the API responds `422` with an error on `from`

### Requirement: Merged change requests fall into exactly one lane

Each merged change request SHALL be in one lane, checked in this order: `bypass` when `merge.merged_without_mergeable_verdict` or `merge.merged_without_lease` is true; `reviewed` when at least one review item at the merged head had an answer; `auto` otherwise. The report MUST give each lane's `merged_count`, `defect_count`, `defective_count` and `defect_rate` (`defective_count / merged_count`, null when `merged_count` is 0).

#### Scenario: Auto lane

- **WHEN** CR 42 merged with a `mergeable` verdict, under a lease, and no answered items at its merged head
- **THEN** CR 42 counts in the `auto` lane

#### Scenario: Reviewed lane

- **WHEN** CR 43 merged under a lease with a `mergeable` verdict after one `approve` answer at its merged head
- **THEN** CR 43 counts in the `reviewed` lane

#### Scenario: Bypass wins over reviewed

- **WHEN** CR 44 had an answered item at its merged head and is flagged `merged_without_lease`
- **THEN** CR 44 counts in the `bypass` lane only

#### Scenario: Defect rate

- **WHEN** the `auto` lane has 20 merged change requests, two of them with one defect and one with three defects
- **THEN** the `auto` lane reports `merged_count: 20`, `defect_count: 5`, `defective_count: 3`, `defect_rate: 0.15`

### Requirement: The report breaks lanes down by policy version

The report SHALL give, for each policy version that judged a merged change request in the window and for each lane, `merged_count`, `defect_count`, `defective_count` and `defect_rate`. A change request's policy version is the `merge.policy_version` stored with its merge.

#### Scenario: Two policy versions

- **WHEN** CR 42 merged under policy version 6 and CR 45 under version 7, both in the `auto` lane, and CR 45 has one defect
- **THEN** version 6 `auto` reports `merged_count: 1, defect_count: 0` and version 7 `auto` reports `merged_count: 1, defect_count: 1`

### Requirement: The report breaks defects down by rule

For each `rule` in the `merge.reasons` of a change request merged in the window, the report SHALL give `fired_count` (change requests where it fired) and `fired_with_defects_count` (those with at least one defect). It MUST also report `gaps`: the numbers of defective change requests whose `merge.reasons` was empty.

#### Scenario: Rule fired on a defective change

- **WHEN** rule `path_match` fired on CR 42 and CR 43, and only CR 43 has a defect
- **THEN** the `path_match` entry reports `fired_count: 2` and `fired_with_defects_count: 1`

#### Scenario: Gap

- **WHEN** CR 46 merged with no reasons in its verdict and has a `critical` defect
- **THEN** `gaps` includes `46`

### Requirement: The report breaks defects down by path glob

For each `paths` glob of the policy versions that judged change requests in the window, the report SHALL count defects whose files match the glob. A defect's files are its commit's `changed_files` when attributed by a commit its `git-facts` lists, else the merged head's diff files. Defects with no file matching any glob MUST be counted as `unmatched_defect_count`.

#### Scenario: Matched glob

- **WHEN** a defect is attributed by commit `c3d4e5f`, whose `changed_files` include `app/priv/repo/migrations/20261101_add.exs`, and the policy has glob `app/priv/repo/migrations/**`
- **THEN** that glob's `defect_count` includes the defect

#### Scenario: Unmatched files

- **WHEN** a defect's files are only `app/lib/good_flows/caches/sweep.ex` and no policy glob matches it
- **THEN** `unmatched_defect_count` includes the defect

### Requirement: Calibration never changes the policy

Reading the calibration report or recording a defect SHALL NOT create a policy version, change any policy setting, or recompute any verdict. The report is computed on read from stored data and is not stored.

#### Scenario: High bypass defect rate

- **WHEN** the `bypass` lane reports `defect_rate: 0.6` and a client reads the report
- **THEN** the project's current policy version is unchanged

### Requirement: Defect and calibration routes are in the OpenAPI document

The OpenAPI document SHALL describe `POST` and `GET /api/v1/projects/:project/defects` and `GET /api/v1/projects/:project/calibration`, with the defect body and response, the `severity` and `attribution` enums, the report schema, and the `401`, `403`, `404` and `422` responses.

#### Scenario: OpenAPI lists the severity enum

- **WHEN** a client fetches the OpenAPI document
- **THEN** the defect request schema lists `severity` with values `low`, `medium`, `high` and `critical`
