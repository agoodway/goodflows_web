# review-policy Specification

## Purpose

Stores each project's versioned `review-policy/1` document, the fixed settings that decide which change request verdict outcomes its rules produce, and controls who may read it and who may write a new version.

## Requirements

### Requirement: Review policy routes
The API SHALL provide `GET /api/v1/projects/:project/review-policy` (the current version), `PUT /api/v1/projects/:project/review-policy` (write a new version), `GET /api/v1/projects/:project/review-policy/versions` (history) and `GET /api/v1/projects/:project/review-policy/versions/:version`. An invalid project slug returns `422` on `project` and an unknown slug, including another account's, returns `404`.

#### Scenario: Read the current policy
- **WHEN** a client with an `sk_` key reads the review policy of project `goodcases` of its account
- **THEN** the API responds `200` with the current version

#### Scenario: Other account's project
- **WHEN** a client reads the review policy of a slug that exists only on another account
- **THEN** the API responds `404`

### Requirement: Any sk_ or pk_ key reads the policy
Every `GET` review policy route SHALL accept any valid `sk_` or `pk_` key of the account. For a `pk_` key, each version's `note` and `written_by` MUST be null. `ck_` keys MUST return `403` on every review policy route. Missing, expired or revoked keys MUST return `401`.

#### Scenario: Public key reads
- **WHEN** a client with a `pk_` key reads the review policy history of a project whose version `1` has `note` `Require ci`
- **THEN** the API responds `200` and version `1` has `note` null and `written_by` null

#### Scenario: Cache key
- **WHEN** a client with a `ck_` key bound to project `goodcases` reads that project's review policy
- **THEN** the API responds `403`

#### Scenario: Missing key
- **WHEN** a client with no key, an expired key, or a revoked key reads the review policy
- **THEN** the API responds `401`

### Requirement: Only owners and admins write the policy
`PUT /api/v1/projects/:project/review-policy` MUST require an `sk_` key whose membership is owner or admin of the account. A `pk_` key, a `ck_` key, or an `sk_` key of a plain member MUST receive `403` before the body is read, and no version is stored. The OpenAPI document MUST list `403` for this operation.

#### Scenario: Admin writes a version
- **WHEN** a client with an `sk_` key of an account admin writes a valid policy
- **THEN** the API responds `201` with the new version

#### Scenario: Member cannot write
- **WHEN** a client with an `sk_` key of a plain member writes a policy
- **THEN** the API responds `403`, does not read the body, and the current version is unchanged

#### Scenario: Public key cannot write
- **WHEN** a client with a `pk_` key writes a policy
- **THEN** the API responds `403` and the current version is unchanged

### Requirement: A project without a policy uses version 0
A project with no written version SHALL have current version `0`: a default that is never stored, with `written_by`, `note` and `inserted_at` null, and that appears in no history list. Version 0 MUST NOT need OpenSpec, CI workflows, scenario sets or a feature index: a change request with no linked OpenSpec change becomes `mergeable` with Git facts for its head and a `change-claims/2` file whose claims meet the claims and size settings. Its settings are:

- `scenarios`: `require_approved_intent` false, `should_failures` `needs_review`, `spec_gaps` `ignore`, `approver` `any`, `diff_only` `needs_review`.
- `evidence`: `required_workflows` `[]`, `ignore_paths` `["docs/**", "**/*.md"]`.
- `claims`: `one_way_door` `needs_review`, `min_proof_level` `ran`, `open_items` `needs_review`.
- `paths` `[]`, because sensitive paths depend on the project's language and layout.
- `size`: `max_changed_files` `40`, `max_changed_lines` `1500`.
- `coverage`: `unmapped_areas` and `undriven_features` `ignore`.
- `merge`: `lease_ttl` `10m`, `regrade_merge_result` true.

#### Scenario: New project
- **WHEN** a client reads the review policy of a project that never wrote one
- **THEN** the API responds `200` with `version` `0`, `claims.min_proof_level` `ran`, `size.max_changed_files` `40`, `evidence.required_workflows` `[]`, `paths` `[]`, `scenarios.require_approved_intent` false, and `scenarios.spec_gaps`, `coverage.unmapped_areas` and `coverage.undriven_features` `ignore`

#### Scenario: Change request without OpenSpec
- **WHEN** a project that never wrote a policy has a change request with no `openspec_change`, Git facts for its head changing 3 files, and claims for that head that call it `two_way`, leave nothing open, and prove every fact `ran`
- **THEN** its verdict is `mergeable` with `policy_version` `0` and no reasons

#### Scenario: Empty history
- **WHEN** a client lists the versions of a project that never wrote a policy
- **THEN** the API responds `200` with `data` `[]`

### Requirement: OpenSpec settings are opt-in
Only the scenario settings SHALL depend on OpenSpec, and version 0 turns each of them off. `scenarios.require_approved_intent` true holds a change request `pending` until it has an approved intent set, which needs a linked OpenSpec change, or a diff scenario set. `scenarios.spec_gaps` reads the intent set's coverage of OpenSpec scenarios. `scenarios.diff_only` applies only under `require_approved_intent`. `scenarios.should_failures` applies to any uploaded scenario set, intent or diff. A project that uses OpenSpec opts in by writing a version that sets `require_approved_intent` true and, if wanted, `spec_gaps` `needs_review`.

#### Scenario: Project opts in to OpenSpec gating
- **WHEN** an admin writes a policy with `scenarios.require_approved_intent` true and a change request has no `openspec_change` and no diff scenario set
- **THEN** its verdict has a `scenario_set_missing` reason with outcome `pending`

### Requirement: Writing creates a new immutable version
A valid write SHALL store a new version numbered one above the current one, starting at `1`, and respond `201`. Each version MUST store the document, the membership, the key, the time, the `previous_version` and the optional `note` (1 to 1,024 UTF-8 bytes). Versions MUST NOT be updated or deleted through the API, and their numbers are never reused.

#### Scenario: First version
- **WHEN** an admin writes the first policy of a project with `note` `Require ci`
- **THEN** the API responds `201` with `version` `1`, `previous_version` `0`, `note` `Require ci`, and `written_by.user_id` equal to the admin's user id

#### Scenario: Show an old version
- **WHEN** a project has versions `1` and `2` and a client shows version `1`
- **THEN** the API responds `200` with the document as written in version `1`

#### Scenario: Unknown version
- **WHEN** a client shows version `9` of a project whose current version is `2`
- **THEN** the API responds `404`

### Requirement: Writes name the version they replace
The write body MUST contain `previous_version` (a nonnegative integer), `policy` (the document) and optionally `note`, and no other key. When `previous_version` is not the current version, the write MUST respond `409` and store nothing. A write whose `previous_version` is one below the current version and whose `policy` and `note` equal the current version's MUST respond `200` with the current version.

#### Scenario: Concurrent writes
- **WHEN** two admins both write with `previous_version` `1` and different documents
- **THEN** one responds `201` with `version` `2` and the other responds `409`, and exactly one version `2` exists

#### Scenario: Retried write
- **WHEN** an admin's write with `previous_version` `1` created version `2` and the same request is sent again
- **THEN** the API responds `200` with `version` `2` and no version `3` exists

#### Scenario: Stale previous version
- **WHEN** the current version is `3` and an admin writes with `previous_version` `1` and a new document
- **THEN** the API responds `409` and the current version stays `3`

### Requirement: The policy document has fixed sections
`policy` MUST be a JSON object with `format` `review-policy/1` and only the sections `scenarios`, `evidence`, `claims`, `paths`, `size`, `coverage` and `merge`, each holding only the keys the next requirement lists. Every section and key other than `format` MAY be omitted and then takes its version 0 value. An unknown section or key, or a null, MUST return `422` on that key. The stored document MUST be kept as given.

#### Scenario: Partial document
- **WHEN** an admin writes `{"format": "review-policy/1", "size": {"max_changed_files": 10}}`
- **THEN** the API responds `201` and the version's effective `size.max_changed_lines` is `1500`

#### Scenario: Unknown section
- **WHEN** an admin writes a policy with a `rules` section
- **THEN** the API responds `422` with `has an unknown field` on `policy` and stores nothing

#### Scenario: Wrong format
- **WHEN** an admin writes a policy with `format` `review-policy/2`
- **THEN** the API responds `422` with an error on `policy.format` and stores nothing

### Requirement: Each section holds fixed keys
The allowed keys SHALL be: `scenarios`: `require_approved_intent`, `should_failures`, `spec_gaps`, `approver`, `diff_only`; `evidence`: `required_workflows`, `ignore_paths`; `claims`: `one_way_door`, `min_proof_level`, `open_items`; `paths`: a list of `{glob, outcome}`; `size`: `max_changed_files`, `max_changed_lines`; `coverage`: `unmapped_areas`, `undriven_features`; `merge`: `lease_ttl`, `regrade_merge_result`. Any other key MUST return `422` on that key.

#### Scenario: Unknown key in a section
- **WHEN** an admin writes a policy with `claims.max_open_items` `3`
- **THEN** the API responds `422` with `has an unknown field` on `policy.claims` and stores nothing

#### Scenario: Unknown key in a paths entry
- **WHEN** an admin writes a `paths` entry `{"glob": "app/priv/**", "outcome": "blocked", "note": "db"}`
- **THEN** the API responds `422` on `policy.paths[<index>]` and stores nothing

#### Scenario: Diff-only key accepted
- **WHEN** an admin writes a policy with `scenarios.diff_only` `weakening`
- **THEN** the API responds `201` and the stored `policy` has `scenarios.diff_only` `weakening`

### Requirement: Outcome settings are validated
`claims.one_way_door`, `claims.open_items`, `coverage.unmapped_areas`, `coverage.undriven_features`, and each `paths[].outcome` MUST be `needs_review`, `blocked` or `ignore`. `scenarios.should_failures` and `scenarios.spec_gaps` MUST be `needs_review` or `ignore`. `scenarios.diff_only` MUST be `needs_review`, `weakening` or `ignore`. `scenarios.approver` MUST be `any`, `other_member` or `admin`. `claims.min_proof_level` MUST be `stated`, `pointed`, `walked` or `ran`. A violation MUST return `422` on that key.

#### Scenario: Pending is not a policy outcome
- **WHEN** an admin writes a policy with `claims.one_way_door` `pending`
- **THEN** the API responds `422` with an error on `policy.claims.one_way_door`

#### Scenario: Unknown proof level
- **WHEN** an admin writes a policy with `claims.min_proof_level` `tested`
- **THEN** the API responds `422` with an error on `policy.claims.min_proof_level`

#### Scenario: Diff-only cannot block
- **WHEN** an admin writes a policy with `scenarios.diff_only` `blocked`
- **THEN** the API responds `422` with an error on `policy.scenarios.diff_only` and stores nothing

### Requirement: Other settings are validated
`evidence.required_workflows` MUST hold at most 32 distinct workflow names under the workflow-run name rule. `evidence.ignore_paths` MUST hold at most 100 globs and `paths` at most 100 entries of only `glob` and `outcome`, with distinct globs. `size.max_changed_files` and `size.max_changed_lines` MUST be positive integers. `scenarios.require_approved_intent` and `merge.regrade_merge_result` MUST be booleans.

#### Scenario: Duplicate required workflow
- **WHEN** an admin writes `evidence.required_workflows` `["ci", "ci"]`
- **THEN** the API responds `422` with an error on `policy.evidence.required_workflows`

#### Scenario: Zero file limit
- **WHEN** an admin writes `size.max_changed_files` `0`
- **THEN** the API responds `422` with an error on `policy.size.max_changed_files`

#### Scenario: Duplicate path glob
- **WHEN** an admin writes two `paths` entries with `glob` `app/priv/**`
- **THEN** the API responds `422` with an error on `policy.paths`

#### Scenario: Non-boolean approval requirement
- **WHEN** an admin writes `scenarios.require_approved_intent` `"yes"`
- **THEN** the API responds `422` with an error on `policy.scenarios.require_approved_intent`

### Requirement: The lease TTL is a bounded duration
`merge.lease_ttl` MUST be a string `<n>s`, `<n>m` or `<n>h`, where `<n>` is a positive integer, from `1m` to `1h` inclusive. Any other value MUST return `422` on `policy.merge.lease_ttl`.

#### Scenario: Lease in seconds
- **WHEN** an admin writes `merge.lease_ttl` `90s`
- **THEN** the API responds `201`

#### Scenario: Lease too long
- **WHEN** an admin writes `merge.lease_ttl` `2h` or `2d`
- **THEN** the API responds `422` with an error on `policy.merge.lease_ttl`

#### Scenario: Lease too short
- **WHEN** an admin writes `merge.lease_ttl` `30s`
- **THEN** the API responds `422` with an error on `policy.merge.lease_ttl`

### Requirement: Globs use a fixed syntax
A glob MUST be 1 to 1,024 bytes, relative, without control characters. `**` matches any number of whole path segments and MUST stand alone as a segment, `*` matches within one segment, and `?` matches one character other than `/`. `[`, `]`, `{`, `}` and `\` MUST be rejected with `422`. A glob MUST match the whole repository-relative path.

#### Scenario: Double star across segments
- **WHEN** a `paths` glob is `app/priv/repo/migrations/**` and the diff has `app/priv/repo/migrations/2026/a.exs`
- **THEN** the glob matches

#### Scenario: Single star stays in one segment
- **WHEN** a `paths` glob is `lib/*.ex` and the diff has `lib/good_flows/a.ex`
- **THEN** the glob does not match

#### Scenario: Whole path only
- **WHEN** a `paths` glob is `lib` and the diff has `lib/a.ex`
- **THEN** the glob does not match

#### Scenario: Brace glob
- **WHEN** an admin writes a `paths` glob `lib/{a,b}.ex`
- **THEN** the API responds `422` with an error on `policy.paths[<index>].glob`

#### Scenario: Double star inside a segment
- **WHEN** an admin writes a `paths` glob `lib/**.ex`
- **THEN** the API responds `422` with an error on `policy.paths[<index>].glob`

### Requirement: Policy responses show the effective settings
A policy version response MUST include under `data` the `version`, `previous_version`, the `policy` as written, the `effective` document with every default filled in, `note`, `written_by` (`user_id`, or null for version 0), `inserted_at`, and `active_settings`: the dotted setting names that take effect in this server version.

#### Scenario: Version response fields
- **WHEN** an `sk_` client reads version `1`
- **THEN** `data` has `version`, `previous_version`, `policy`, `effective`, `note`, `written_by`, `inserted_at` and `active_settings`

### Requirement: Active settings grow by phase
With `add-change-request-core`, `active_settings` SHALL hold every setting except `scenarios.*`, `evidence.ignore_paths`, `coverage.*` and `merge.*`. `add-change-request-grading` MUST add `scenarios.*`, `evidence.ignore_paths` and `coverage.*`, and `add-change-request-merge` MUST add `merge.*`, so a server that implements all four phases lists every setting. A setting missing from `active_settings` MUST NOT change any verdict.

#### Scenario: Later-phase settings are inactive
- **WHEN** a server that implements `add-change-request-core` and `add-change-request-grading` but not `add-change-request-merge` serves a version that sets `merge.regrade_merge_result` true
- **THEN** `active_settings` contains `claims.one_way_door`, `evidence.required_workflows` and `coverage.undriven_features` and does not contain `merge.regrade_merge_result`

#### Scenario: Inactive settings do not change verdicts
- **WHEN** a server that does not implement `add-change-request-merge` holds a leased change request whose lease `base` differs from its `merge_base`, and an admin writes a version that only sets `merge.regrade_merge_result` true
- **THEN** every recomputed verdict has the same `state` and `reasons` as before, with the new `policy_version`

#### Scenario: Merge settings are active
- **WHEN** a server that implements `add-change-request-merge` serves a policy version
- **THEN** `active_settings` contains every setting, including `merge.lease_ttl` and `merge.regrade_merge_result`

### Requirement: List policy versions
`GET /api/v1/projects/:project/review-policy/versions` SHALL return the project's stored versions newest first, keyset-paged with `limit` (1 to 200, default 50) and `cursor` (the previous page's `next_cursor`, null on the last page). A `limit` or `cursor` that breaks its rule MUST return `422` on that parameter.

#### Scenario: Paged history
- **WHEN** a project has versions `1` to `3` and a client lists with `limit=2`, then with the returned cursor
- **THEN** the first page has versions `3` and `2` and a `next_cursor`, and the second has version `1` and `next_cursor` null

### Requirement: Verdicts use the current policy version
Every verdict SHALL be computed with the project's current policy version at computation time and MUST record that version as `policy_version`. A change request cannot supply or override the policy.

#### Scenario: Version recorded
- **WHEN** a project's current policy version is `4` and a change request's verdict is computed
- **THEN** the verdict has `policy_version` `4`

### Requirement: Policy write bodies are strict JSON
The write body MUST follow the workflow-run upload rules with a 256 KiB default limit: over the limit returns `413`, a non-JSON Content-Type or a Content-Encoding other than `identity` returns `415`, malformed JSON returns `400`, and duplicate keys, U+0000 in a string, and non-integer numbers return `422`. Validation errors MUST NOT echo submitted values.

#### Scenario: Duplicate key
- **WHEN** an admin writes a body containing the key `policy` twice
- **THEN** the API responds `422` with `has a duplicate key` on `body` and stores nothing

#### Scenario: Malformed JSON
- **WHEN** an admin writes the body `{`
- **THEN** the API responds `400` and stores nothing

### Requirement: Review policy routes are in the OpenAPI document
Every review policy route SHALL be described in the OpenAPI document served at `/api/v1/openapi`, with its request body, success responses, and each error status it can return (`400`, `401`, `403`, `404`, `409`, `413`, `415` and `422` where they apply).

#### Scenario: Spec lists the routes
- **WHEN** a client fetches `/api/v1/openapi`
- **THEN** it describes reading the current policy, writing a version with `403` and `409`, listing versions, and showing a version

### Requirement: Diff-only outcome defaults to needs_review
When a policy omits `scenarios.diff_only`, including policy version 0, its `effective` document SHALL have `scenarios.diff_only` `needs_review`, so a policy written before this setting existed keeps its verdicts. `active_settings` MUST contain `scenarios.diff_only`.

#### Scenario: Older policy
- **WHEN** a client reads a policy version whose `scenarios` section has only `require_approved_intent` true
- **THEN** `effective.scenarios.diff_only` is `needs_review` and `policy` has no `diff_only` key

#### Scenario: Version 0
- **WHEN** a client reads the review policy of a project that never wrote one
- **THEN** `effective.scenarios.diff_only` is `needs_review` and `active_settings` contains `scenarios.diff_only`
