## MODIFIED Requirements

### Requirement: Each kind comes from fixed rules
Each item kind SHALL come only from fixed reasons. `scenario_set_approval`, `diff_only_set`, `diff_set_weakened`, `spec_gap`, `one_way_door`, `unmapped_area` and `undriven_feature` come from the rule of the same name; `failed_scenario` from `should_failed`; `not_run` from `should_not_run`; `unproven_claim` from `proof_below_minimum`; `question` and `open_item` from `open_items`; `sensitive_path` from `path_match`; `size` from `max_changed_files` or `max_changed_lines`.

#### Scenario: Spec gap item
- **WHEN** `scenarios.spec_gaps` is `needs_review` and the graded intent set has a `no_check` row
- **THEN** the packet has a `spec_gap` item with rule `spec_gap`

#### Scenario: Weakened diff set item
- **WHEN** the verdict has `diff_set_weakened` reasons for `S3` and `S5`
- **THEN** the packet has two `diff_set_weakened` items, with subjects `["diff", "S3"]` and `["diff", "S5"]`

### Requirement: Item data per kind
Each item's `data` SHALL carry what a reviewer needs for its kind, from stored inputs at the head. Hunks MUST come only from the claims document's `decisions`; the server MUST NOT serve any other diff content. The kinds are listed in this requirement's scenarios; an item of any other kind MUST NOT be served.

#### Scenario: Scenario set approval item
- **WHEN** the item kind is `scenario_set_approval`
- **THEN** `data` has the set `digest`, `version`, the last approved `digest` or null, and the version comparison by scenario ID with weakening changes (Must removed, Must demoted) listed first

#### Scenario: Diff-only set item
- **WHEN** the item kind is `diff_only_set`
- **THEN** `data` has the diff set `digest`, `revision`, and its scenario IDs with priorities and results from counted runs

#### Scenario: Weakened diff set item
- **WHEN** the item kind is `diff_set_weakened`
- **THEN** `data` has the scenario `id`, the `change` (`removed` or `demoted`), `from_priority` and `to_priority`, the current diff `version` and `digest`, the baseline `version` and `digest`, and `edited_musts`: the IDs of scenarios that are `must` in both the baseline and the current version and whose section digest differs, or `[]`

#### Scenario: Failed scenario item
- **WHEN** the item kind is `failed_scenario` (from a `should_failed` reason)
- **THEN** `data` has the scenario `id` and `priority` `should`, the set `digest`, the counted run's `run_id`, `commit`, `failed_step` and `reason`, and its artifacts

#### Scenario: Not run item
- **WHEN** the item kind is `not_run` (from a `should_not_run` reason)
- **THEN** `data` has the scenario `id`, `priority` `should`, the set `digest`, and the newest counted run's `run_id` and `reason`

#### Scenario: Spec gap item data
- **WHEN** the item kind is `spec_gap` (from a `spec_gap` reason)
- **THEN** `data` has the coverage row's `capability`, `requirement` and `scenario`, the intent set `digest` and `version`, and `covering_claims`: each `safe_because` entry at the head whose `covers` names that row (all below `claims.min_proof_level`, or the gap would be closed) with `fact`, `proof` and `evidence`, or `[]`

#### Scenario: One-way door item
- **WHEN** the item kind is `one_way_door`
- **THEN** `data` has `door_reason`, `reach`, and every claims `decisions` entry with `id`, `path`, `hunk` and `note`

#### Scenario: Unproven claim item
- **WHEN** the item kind is `unproven_claim` (from a `proof_below_minimum` reason)
- **THEN** `data` has `min_proof_level` and every `safe_because` entry below it with `fact`, `location`, `proof`, `evidence` and `covers` (absent ones as null)

#### Scenario: Open item
- **WHEN** the item kind is `open_item`
- **THEN** `data` has the `left_open` entry's `risk`, `location` and `affected`

#### Scenario: Question item
- **WHEN** the item kind is `question`
- **THEN** `data` has the question's `id`, `text`, `options` and `recommendation`

#### Scenario: Sensitive path item
- **WHEN** the item kind is `sensitive_path` (from a `path_match` reason, one item per policy entry)
- **THEN** `data` has the policy `glob`, the matched files with `path`, `old_path`, `additions` and `deletions`, and the claims `decisions` whose `path` is among them

#### Scenario: Size item
- **WHEN** the item kind is `size` (one item per `max_changed_files` or `max_changed_lines` reason)
- **THEN** `data` has `limit` (`max_changed_files` or `max_changed_lines`, the item's rule), `changed_files`, `changed_lines`, `max_changed_files` and `max_changed_lines`

#### Scenario: Unmapped area item
- **WHEN** the item kind is `unmapped_area`
- **THEN** `data` has the changed paths that match no feature's globs and the feature index version

#### Scenario: Undriven feature item
- **WHEN** the item kind is `undriven_feature`
- **THEN** `data` has the feature `id`, `title`, and the changed paths that map to it

### Requirement: Each kind allows fixed answers
An item's `answers` SHALL be `["approve", "reject"]` for `scenario_set_approval` and `diff_set_weakened`, `["choose", "request_change"]` for `question`, and `["approve", "request_change"]` for every other kind. `accept_as_known` MUST NOT exist.

#### Scenario: Allowed answers in the packet
- **WHEN** a packet has a `question`, a `one_way_door` and a `scenario_set_approval` item
- **THEN** their `answers` are `["choose", "request_change"]`, `["approve", "request_change"]` and `["approve", "reject"]`

#### Scenario: Weakened diff set answers
- **WHEN** a packet has a `diff_set_weakened` item
- **THEN** its `answers` are `["approve", "reject"]`

### Requirement: Who may answer
Any `sk_` key of the account SHALL answer any item except `scenario_set_approval` and `diff_set_weakened`. Answers on those two kinds MUST follow the policy's `scenarios.approver`: `any` allows any `sk_` key, `other_member` requires a membership other than the one that opened the change request, and `admin` requires an owner or admin. A refused answer MUST return `403` and store nothing. `pk_` and `ck_` keys MUST return `403`.

#### Scenario: Author approves under other_member
- **WHEN** `scenarios.approver` is `other_member` and the membership that opened the change request answers `approve` on its `scenario_set_approval` item
- **THEN** the API responds `403` and stores nothing

#### Scenario: Author accepts a weakened diff set under other_member
- **WHEN** `scenarios.approver` is `other_member` and the membership that opened the change request answers `approve` on its `diff_set_weakened` item
- **THEN** the API responds `403` and stores nothing

#### Scenario: Non-admin answers a one-way door
- **WHEN** `scenarios.approver` is `admin` and a member who is not admin answers `approve` on a `one_way_door` item
- **THEN** the API responds `201`

#### Scenario: Public key answers
- **WHEN** a client with a `pk_` key posts an answer
- **THEN** the API responds `403` and stores nothing

## ADDED Requirements

### Requirement: Weakened diff set answers bind to the diff digest
A `diff_set_weakened` answer SHALL count, clear its item and appear in the packet only while the diff digest that was current when it was given is still current. Storing a new diff version MUST make every earlier `diff_set_weakened` answer stop counting, at every head, so a new diff version at the same head needs new answers.

#### Scenario: Re-upload at the same head
- **WHEN** at head H on diff digest `d2` the `diff_set_weakened` item for `S3` is answered `approve`, and diff version 3 with digest `d3`, naming H and still demoting `S3`, is uploaded
- **THEN** the item for `S3` has `answer` null and the verdict is `needs_review`

#### Scenario: Earlier answer does not complete a later version
- **WHEN** on digest `d2` `S3` was answered `approve`, then `d3` is uploaded at the same head with weakened `S3` and `S5`, and only `S5` is answered `approve`
- **THEN** no decision is recorded on `d3` and the verdict stays `needs_review`

### Requirement: Weakened diff set answers act on the digest
When an `approve` answer leaves every `diff_set_weakened` item answered `approve` on the current diff digest, the server MUST also record an `approve` decision on that digest, with the membership and key of that answer. A `reject` answer MUST record a `reject` decision with its note on that digest and create a task. These MUST commit in one transaction with the answer.

#### Scenario: Accept the only weakening
- **WHEN** the only item is `diff_set_weakened` for `S3` on diff digest `d2` and an allowed member answers `approve`
- **THEN** `d2` is accepted, version 2 becomes the baseline, and the verdict has no `diff_set_weakened` reason

#### Scenario: One of two weakenings accepted
- **WHEN** `diff_set_weakened` items exist for `S3` and `S5` on digest `d2` and only `S3` is answered `approve`
- **THEN** no decision is recorded on `d2`, the verdict stays `needs_review`, and its `review` is `{"items": 2, "cleared": 1}`

#### Scenario: Decision records the completing answer
- **WHEN** member M approves the item for `S3` and member N then approves the item for `S5` on digest `d2`
- **THEN** one `approve` decision on `d2` exists, made by N with N's key and `channel` `cli`

#### Scenario: Next push after acceptance
- **WHEN** `d2` was accepted and the agent uploads diff version 3 for a new head that keeps every scenario of version 2
- **THEN** the new head's packet has no `diff_set_weakened` item

#### Scenario: Reject a weakening
- **WHEN** an allowed member answers `reject` with note `S3 must stay a Must` on the `diff_set_weakened` item for digest `d2`
- **THEN** a `reject` decision on `d2` with that note is stored, a task with that note is created, and the item stays open

#### Scenario: Reject twice with the same note
- **WHEN** membership M answers `reject` with note `S3 must stay a Must` on the same `diff_set_weakened` item of digest `d2` twice at the same head
- **THEN** both answers respond `201` and one `reject` decision row exists on `d2`
