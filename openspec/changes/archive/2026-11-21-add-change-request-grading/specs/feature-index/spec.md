# Spec Delta

## Purpose

Keeps a versioned per-project index of the app's features, each with path globs, synced from the verify skill's feature files, so the server can tell which changed files belong to which feature and which changed areas no feature covers.

## ADDED Requirements

### Requirement: Feature index routes require a key of the account
Every route under `/api/v1/projects/:project/feature-index` SHALL require a valid key of the project's account: missing, expired or revoked keys get `401`. Syncing MUST accept any `sk_` key of the account, whatever its role, and a `pk_` key MUST get `403`. Reading MUST accept `sk_` and `pk_` keys. A `ck_` key MUST get `403`. An unknown project MUST get `404`.

#### Scenario: Member syncs
- **WHEN** an `sk_` key of a `member` membership syncs a valid index
- **THEN** the API responds `201`

#### Scenario: Public key syncs
- **WHEN** a `pk_` key syncs an index
- **THEN** the API responds `403` and stores nothing

#### Scenario: Public key reads
- **WHEN** a `pk_` key reads the current index
- **THEN** the API responds `200` with the features and their `paths`

### Requirement: A sync uploads every feature
`POST /api/v1/projects/:project/feature-index` SHALL accept `{"features": [...]}` with 1 to 500 entries `{id, title, paths}`. `id` MUST match `[a-z0-9][a-z0-9_-]{0,63}` and be unique, `title` MUST be 1 to 200 characters, and `paths` MUST hold 1 to 100 globs of 1 to 512 bytes. Unknown keys, an empty `features` list, or a glob that does not compile MUST get `422` and store nothing.

#### Scenario: Sync two features
- **WHEN** a client syncs `{"features": [{"id": "checkout", "title": "Checkout", "paths": ["app/lib/shop/checkout/**"]}, {"id": "login", "title": "Log in", "paths": ["app/lib/good_flows_web/live/user_live/**"]}]}`
- **THEN** the API responds `201` with `version` 1

#### Scenario: Duplicate feature id
- **WHEN** two entries have `id` `login`
- **THEN** the API responds `422` with an error on `features` and stores nothing

#### Scenario: Feature without paths
- **WHEN** an entry has `paths` `[]`
- **THEN** the API responds `422` with an error on `features`

### Requirement: Globs match like policy globs
Feature globs SHALL use the review policy's glob rules: `**` for any number of path segments, `*` within one segment, `?` for one character, matched against the whole repository-relative path.

#### Scenario: Nested file
- **WHEN** feature `checkout` has `paths` `["app/lib/shop/checkout/**"]`
- **THEN** `app/lib/shop/checkout/steps/pay.ex` maps to `checkout` and `app/lib/shop/cart.ex` does not

### Requirement: Each sync is an immutable version
A sync whose features differ from the newest version's SHALL create the next version, recording the membership, key and time, and become current. A sync equal to the newest version as a JSON value MUST respond `200` with `duplicate` true and create no version. Versions are immutable and kept until the project is deleted.

#### Scenario: Changed globs
- **WHEN** the index is at version 3 and a client syncs with one glob changed
- **THEN** the API responds `201` with `version` 4, and coverage uses version 4

#### Scenario: Unchanged sync
- **WHEN** a client syncs the same features as version 4
- **THEN** the API responds `200` with `duplicate` true and `version` 4

### Requirement: Read the feature index
`GET /api/v1/projects/:project/feature-index` SHALL return the current version with `version`, `inserted_at` and `features`, or `404` when the project has never synced. `GET …/feature-index/versions` SHALL list versions newest first with `version`, `inserted_at` and feature count, keyset-paged. `GET …/feature-index/versions/:version` SHALL return that version or `404`.

#### Scenario: Never synced
- **WHEN** a client reads the index of a project that has never synced
- **THEN** the API responds `404`

#### Scenario: Read an old version
- **WHEN** the index is at version 4 and a client reads `/feature-index/versions/2`
- **THEN** the API responds `200` with version 2's features

### Requirement: Changed files map to features
For a change request's head, the server SHALL map each `git-facts` diff file to every feature of the current index with a glob matching its `path` or, for a rename or copy, its `old_path`. A file matching no feature's glob is an unmapped area. A file whose `path` and, for a rename or copy, `old_path` both match `evidence.ignore_paths` MUST be left out of the mapping, as for run counting.

#### Scenario: File in two features
- **WHEN** `app/lib/shared/money.ex` matches a glob of `checkout` and of `billing`
- **THEN** the file maps to both features

#### Scenario: Unmapped file
- **WHEN** `app/lib/good_flows/new_thing.ex` matches no glob
- **THEN** it is an unmapped area

#### Scenario: Ignored path
- **WHEN** `docs/usage.md` matches no feature and `ignore_paths` is `["docs/**"]`
- **THEN** it is not an unmapped area

#### Scenario: Rename into an ignored path
- **WHEN** a diff file is renamed from `app/x.ex` to `docs/x.md`, no feature matches either path, and `ignore_paths` is `["docs/**"]`
- **THEN** `docs/x.md` is an unmapped area, and a later commit with that rename keeps an earlier run from counting

#### Scenario: Renamed file
- **WHEN** a diff file is renamed from `app/lib/shop/checkout/old.ex` to `app/lib/misc/new.ex`
- **THEN** it maps to `checkout` through its `old_path`

### Requirement: A changed feature needs a counted run that drove it
A feature that a changed file maps to SHALL be driven when at least one run that counts for the change request at its head lists that feature in `features` with `result` `passed`. Every other mapped feature is undriven.

#### Scenario: Driven feature
- **WHEN** a changed file maps to `checkout` and a counted run lists `{id: "checkout", result: "passed"}`
- **THEN** `checkout` is driven

#### Scenario: Driven only by an uncounted run
- **WHEN** the only run listing `checkout` `passed` is dirty
- **THEN** `checkout` is undriven

#### Scenario: Driven but failed
- **WHEN** every counted run lists `checkout` with `result` `failed`
- **THEN** `checkout` is undriven

### Requirement: A new index version recomputes verdicts
A sync that creates a version SHALL recompute the verdict of every `draft` and `open` change request of the project, in that transaction up to a configured count (default 100) and otherwise in a background job.

#### Scenario: Sync maps an unmapped area
- **WHEN** change request 42's verdict has an `unmapped_area` reason for `app/lib/good_flows/new_thing.ex` and a sync adds a feature whose glob matches it
- **THEN** the recomputed verdict has no `unmapped_area` reason for that file

### Requirement: Feature index routes are in the OpenAPI document
Every feature index route SHALL be described in the OpenAPI document with its request body, responses and status codes.

#### Scenario: OpenAPI lists the routes
- **WHEN** a client fetches the OpenAPI document
- **THEN** it describes sync, show current, list versions and show version under `/api/v1/projects/{project}/feature-index`
