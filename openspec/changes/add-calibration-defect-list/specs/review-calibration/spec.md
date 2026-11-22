# Spec Delta

## ADDED Requirements

### Requirement: The report lists its defects

The report SHALL include `defects`: the defects attributed to change requests merged in the window, whenever recorded, ordered by `recorded_at` then `id`, both descending. Each entry MUST have the defect's `id`, `change_request`, `commit`, `attribution`, `severity`, `ticket` and `recorded_at`.

#### Scenario: Newest first

- **WHEN** two defects of change requests merged in the window were recorded on `2026-11-02` and `2026-11-05`
- **THEN** `defects` lists the `2026-11-05` defect first

### Requirement: Each listed defect carries its calibration context

Each `defects` entry MUST have its change request's `lane`, `policy_version` (its `merge.policy_version`), `rules` (the distinct `rule` values of its `merge.reasons`, sorted) and `globs` (the report's `globs` entries that match the defect's files, sorted).

#### Scenario: Defect with its context

- **WHEN** CR 43 merged in the window in the `reviewed` lane under policy version 7, `path_match` fired on it, and a defect attributed by commit `c3d4e5f` changed `app/priv/repo/migrations/20261101_add.exs` under policy glob `app/priv/repo/migrations/**`
- **THEN** `defects` has an entry with `change_request: 43`, `attribution: "commit"`, `lane: "reviewed"`, `policy_version: 7`, `rules: ["path_match"]` and `globs: ["app/priv/repo/migrations/**"]`

#### Scenario: Gap defect

- **WHEN** CR 46 merged with no reasons and its only defect's files match no policy glob
- **THEN** `gaps` includes `46` and that defect's entry has `rules: []` and `globs: []`

### Requirement: The defect list is capped

`defects` MUST hold at most 500 entries. `defects_truncated` MUST be true when more defects exist and false otherwise. Every count in the report MUST cover all defects, listed or not.

#### Scenario: Truncated list

- **WHEN** 501 defects are attributed to change requests merged in the window
- **THEN** `defects` holds the 500 most recently recorded, `defects_truncated` is true, and the lanes' `defect_count` values sum to 501

### Requirement: Public keys see no tickets in the report

For a `pk_` key, every `defects` entry's `ticket` MUST be null.

#### Scenario: Public key reads the report

- **WHEN** a defect with `ticket: "GOO-512"` is attributed to a change request merged in the window and a client with a `pk_` key reads the report
- **THEN** the API responds `200` and that defect's entry has `ticket: null`

### Requirement: The report counts unattributed defects

The report SHALL include `unattributed_defect_count`: the number of the project's defects with `attribution` `unattributed` whose `recorded_at` is in `[from, to)`. These defects MUST NOT be listed in `defects` and MUST NOT count in any lane, policy version, rule, glob, `gaps` or `unmatched_defect_count`.

#### Scenario: Unattributed inside the window

- **WHEN** an unattributed defect was recorded at `2026-11-10T00:00:00Z` and a client reads the report with `from=2026-11-01T00:00:00Z&to=2026-11-20T00:00:00Z`
- **THEN** `unattributed_defect_count` is `1`, `defects` does not list it, and every lane's `defect_count` is unchanged

#### Scenario: Unattributed at the window's end

- **WHEN** an unattributed defect was recorded exactly at `to`
- **THEN** `unattributed_defect_count` does not include it

## MODIFIED Requirements

### Requirement: Defect and calibration routes are in the OpenAPI document

The OpenAPI document SHALL describe `POST` and `GET /api/v1/projects/:project/defects` and `GET /api/v1/projects/:project/calibration`, with the defect body and response, the `severity` and `attribution` enums, the report schema including `defects`, `defects_truncated` and `unattributed_defect_count`, and the `401`, `403`, `404` and `422` responses.

#### Scenario: OpenAPI lists the severity enum

- **WHEN** a client fetches the OpenAPI document
- **THEN** the defect request schema lists `severity` with values `low`, `medium`, `high` and `critical`

#### Scenario: OpenAPI describes the defect list

- **WHEN** a client fetches the OpenAPI document
- **THEN** the calibration report schema has `defects` entries with `lane`, `policy_version`, `rules` and `globs`, and the fields `defects_truncated` and `unattributed_defect_count`
