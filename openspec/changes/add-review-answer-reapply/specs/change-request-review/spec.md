## ADDED Requirements

### Requirement: Items show their latest earlier answer
Each packet item MUST have `earlier_answer`. It SHALL be null when no current answer to the same item `id` exists at a head other than the packet's head. Otherwise it SHALL be `{"answer", "reapplicable", "not_reapplicable_reason", "changed_since"}`, where `answer` is the most recently stored such answer, in the same shape as an item's `answer` and with its own `head`. A replaced answer is not current.

#### Scenario: Approved at the previous head
- **WHEN** member T approved `open_items:e0f3…` at head `a1b2c3d…` with note `known, tracked in #12`, and head `d4e5f6a…` is now current with the same item
- **THEN** the item's `earlier_answer.answer` is T's `approve` at `a1b2c3d…` with that note

#### Scenario: Two earlier heads
- **WHEN** an item was answered `request_change` at head `H1`, then `approve` at head `H2`, and head `H3` is now current
- **THEN** `earlier_answer.answer` is the `approve` at `H2`

#### Scenario: Never answered
- **WHEN** an item has no answer at any head
- **THEN** its `earlier_answer` is null

### Requirement: Earlier answers never count
An earlier answer MUST NOT count toward the verdict and MUST NOT appear as the item's `answer`. Only an answer stored at the head, given directly or re-applied, SHALL count.

#### Scenario: Shown but not counted
- **WHEN** an item's only answer is an `approve` at the previous head
- **THEN** the item's `answer` is null and the verdict counts the item as not cleared

### Requirement: An earlier answer says whether it can be re-applied
`reapplicable` SHALL be true exactly when the item's kind is neither `scenario_set_approval` nor `diff_set_weakened`, the earlier answer is `approve` or `choose`, for `choose` its `option` is still one of the question's `options` at the head, and the item has no answer at the head. Otherwise `not_reapplicable_reason` SHALL be the first failing check, in that order: `kind`, `answer`, `option_removed` or `answered_at_head`. It SHALL be null when `reapplicable` is true.

#### Scenario: Earlier request change
- **WHEN** an item's earlier answer is `request_change`
- **THEN** `reapplicable` is false and `not_reapplicable_reason` is `answer`

#### Scenario: Option no longer offered
- **WHEN** a question was answered `choose` with option `drop` at the earlier head and the question at the head offers only `keep` and `rename`
- **THEN** `reapplicable` is false and `not_reapplicable_reason` is `option_removed`

#### Scenario: Scenario set approval
- **WHEN** a `scenario_set_approval` item has an earlier `approve`
- **THEN** `reapplicable` is false and `not_reapplicable_reason` is `kind`

### Requirement: An earlier answer says what changed since
`changed_since` SHALL be null when the earlier answer's head is not the `sha` of a commit in the current head's stored `git-facts.commits`. Otherwise it SHALL be `{"commits", "files", "item_paths", "item_paths_changed"}`. `commits` is the number of commits after that one. `files` is the sorted union of their `changed_files` paths, including `old_path`s.

#### Scenario: One later commit
- **WHEN** the earlier answer is at `H1` and the current head `H2`'s commits list `H1` followed by one commit changing `README.md`
- **THEN** `changed_since.commits` is `1` and `changed_since.files` is `["README.md"]`

#### Scenario: After a rebase
- **WHEN** the earlier answer's head is not in the current head's `git-facts.commits`
- **THEN** `changed_since` is null

### Requirement: Changed since names the item's own paths
`item_paths` SHALL be an `open_item`'s `location` without a trailing `:<line>` or `:<line>-<line>` suffix, or a `sensitive_path` item's matched files, and null for every other kind. `item_paths_changed` SHALL be whether `files` contains any of `item_paths`, and null when `item_paths` is null.

#### Scenario: Untouched open item
- **WHEN** an `open_item` with location `app/todos.py:32` has an earlier answer and only `README.md` changed since
- **THEN** `item_paths` is `["app/todos.py"]` and `item_paths_changed` is false

#### Scenario: Touched open item
- **WHEN** a commit since also changed `app/todos.py`
- **THEN** `item_paths_changed` is true

#### Scenario: Kind without paths
- **WHEN** a `one_way_door` item's earlier answer is at an ancestor of the head
- **THEN** `item_paths` and `item_paths_changed` are null and `commits` and `files` are set

### Requirement: Re-apply earlier answers
`POST /api/v1/projects/:project/change-requests/:number/review/reapply` SHALL accept a JSON body with `head` (required string) and `item_ids` (1 to 200 unique strings), and no other key. It SHALL follow the answer route's key, project and change request checks, and return `409` without `errors.head` for a `merged` or `closed` change request, before body validation. A `head` that is not the current head MUST return `409` with the current head in `errors.head` and store nothing.

#### Scenario: Stale head
- **WHEN** the client posts `head` `H1` after `H2` was reported
- **THEN** the API responds `409` with `head` `H2` and stores nothing

#### Scenario: Closed change request
- **WHEN** a client posts to the route for a `closed` change request
- **THEN** the API responds `409` with no `head` in `errors` and stores nothing

#### Scenario: Public key
- **WHEN** a `pk_` client posts to the route
- **THEN** the API responds `403` and stores nothing

#### Scenario: Unknown key
- **WHEN** a client posts a body containing `note`
- **THEN** the API responds `422` with `has an unknown field` on `body` and stores nothing

### Requirement: Reapply is all or nothing
Each id MUST be an item at the head whose `earlier_answer.reapplicable` is true, or the route returns `422` with an error on `item_ids[<index>]` and stores nothing. Otherwise the route SHALL store, in one transaction, one answer per item at the head. Each answer copies the earlier answer's `answer`, `option` and `note`, with the request's membership, key and channel `cli`. The route SHALL recompute the verdict once and return `201` with `data`: the stored answers in `item_ids` order.

#### Scenario: Re-apply two approvals
- **WHEN** both `open_item`s of change request 1 were approved at `H1`, `H2` is current, and an `sk_` client posts `{"head": "H2", "item_ids": [<both ids>]}`
- **THEN** the API responds `201` with two `approve` answers at `H2`, and the packet shows both items cleared

#### Scenario: One id not re-applicable
- **WHEN** the client posts two ids and the second item's earlier answer is `request_change`
- **THEN** the API responds `422` with an error on `item_ids[1]` and stores no answer

### Requirement: Re-applied answers name their source
Every answer SHALL have `reapplied_from`, null for an answer given directly. A re-applied answer's `reapplied_from` SHALL be `{"answer_id", "head", "answered_by": {"user_id", "key_id"}, "inserted_at"}` of the earlier answer it copied. A re-applied answer SHALL otherwise behave as an answer given directly at the head: it counts, a later answer replaces it, and it never carries to another head.

#### Scenario: Re-applied by another member
- **WHEN** member M re-applies T's approval from `H1` at `H2`
- **THEN** the answer at `H2` is answered by M and its `reapplied_from` names T, `H1` and T's answer id

#### Scenario: Re-applied answer at the next head
- **WHEN** that re-applied answer is at `H2` and `H3` is reported
- **THEN** the item's `answer` at `H3` is null and its `earlier_answer.answer` is the re-applied answer at `H2`

### Requirement: The reapply route is in the OpenAPI document
`/api/v1/openapi` SHALL describe the reapply route with its request body, its response schema, and responses `201`, `401`, `403`, `404`, `409` and `422`. It SHALL also describe `earlier_answer` on items and `reapplied_from` on answers.

#### Scenario: OpenAPI lists the reapply route
- **WHEN** a client reads `/api/v1/openapi`
- **THEN** it describes `POST /api/v1/projects/{project}/change-requests/{number}/review/reapply`
