# Spec Delta

## MODIFIED Requirements

### Requirement: Change request responses carry the record
A change request response MUST include under `data` the `id`, `number`, `title`, `state`, `source_branch`, `target_branch`, `openspec_change` (or null), `links` (or null), `head` (the last reported head, or null), `parent` (the parent change request's number, or null), `dependencies` (the stored change ids, `[]` when none), `opened_by` with the opener's `user_id`, `merge` (null unless merged), `inserted_at` and `updated_at`. It MUST NOT include `account_id` or `project_id`.

#### Scenario: New change request
- **WHEN** a client creates a change request without Git facts
- **THEN** the response has `head` null, `parent` null, `dependencies` `[]`, `merge` null, and `opened_by.user_id` equal to the key owner's user id

## ADDED Requirements

### Requirement: A change request may list the changes it depends on

`PUT /api/v1/projects/:project/change-requests/:number/dependencies` with `{"change_ids": [...]}` SHALL replace the change request's `dependencies` with the given list, in the given order, recompute its verdict in the same transaction, and respond `200` with the change request. An empty list clears it. It requires an `sk_` key of the account (`pk_` and `ck_` `403`) and a change request in `draft` or `open` (else `409` `not_editable`, nothing changed).

#### Scenario: Set dependencies

- **WHEN** CR 42 is `open` and a client puts `{"change_ids": ["add-login", "add-sessions"]}` to its dependencies route
- **THEN** the API responds `200` with `dependencies` `["add-login", "add-sessions"]`, and the list and show responses carry the same list

#### Scenario: Replace and clear

- **WHEN** CR 42's dependencies are `["add-login"]` and a client puts `{"change_ids": ["add-sessions"]}`, then `{"change_ids": []}`
- **THEN** CR 42's dependencies are `["add-sessions"]`, then `[]`

#### Scenario: Merged change request

- **WHEN** CR 42 is `merged` and a client puts `{"change_ids": ["add-login"]}`
- **THEN** the API responds `409` with `error: "not_editable"` and the dependencies are unchanged

### Requirement: Dependency ids follow the change id rule

`change_ids` SHALL be an array of at most 50 distinct strings, each a 1 to 64 byte slug matching `[a-z0-9][a-z0-9-]*`, the rule of `openspec_change`. A body with another key, an id that breaks the rule, a duplicate id, or the change request's own `openspec_change` MUST return `422` on `change_ids` (an invalid entry on `change_ids[<index>]`) and change nothing.

#### Scenario: Invalid id

- **WHEN** a client puts `{"change_ids": ["Add_Login"]}`
- **THEN** the API responds `422` with an error on `change_ids` and the dependencies are unchanged

#### Scenario: Own change

- **WHEN** CR 42 links `add-login` and a client puts `{"change_ids": ["add-login"]}` to CR 42's dependencies route
- **THEN** the API responds `422` with an error on `change_ids`

#### Scenario: Duplicate id

- **WHEN** a client puts `{"change_ids": ["add-login", "add-login"]}`
- **THEN** the API responds `422` with an error on `change_ids`

### Requirement: A change request waits for its dependencies to merge

For each id in a `draft` or `open` change request's `dependencies` that no `merged` change request of the same project links as its `openspec_change`, the verdict SHALL be `pending` with a reason whose `rule` is `dependency_not_merged` and whose `subject` is `[<change id>]`. The reason fires whatever the Git facts, and the change request's other reasons are kept. Its `message` MUST say which case holds and name rebasing onto a commit where the change is archived as a way out: a change request linking the id is `draft` or `open` (naming its numbers), every change request linking it is `closed`, or none links it. The verdict's `inputs.dependencies` SHALL be the stored id list.

#### Scenario: Dependency's change request open

- **WHEN** CR 42 depends on `add-login`, CR 41 links `add-login` and is `open`, and CR 42's other rules would make it `mergeable`
- **THEN** CR 42's verdict is `pending` with reason `dependency_not_merged`, subject `["add-login"]`, and a message naming change request 41

#### Scenario: Every linking change request closed

- **WHEN** CR 42 depends on `add-login` and the only change request linking it, CR 41, is `closed`
- **THEN** CR 42's verdict has `dependency_not_merged` with subject `["add-login"]` and a message saying every change request linking it is closed

#### Scenario: No change request links the id

- **WHEN** CR 42 depends on `add-login` and no change request of the project links it
- **THEN** CR 42's verdict has `dependency_not_merged` with subject `["add-login"]` and a message saying none links it

#### Scenario: One merged linking change request satisfies the dependency

- **WHEN** CR 42 depends on `add-login`, CR 40 linking it is `closed` and CR 41 linking it is `merged`
- **THEN** CR 42's verdict has no `dependency_not_merged` reason

#### Scenario: Another project's change request

- **WHEN** CR 42 depends on `add-login` and only a change request of another project links `add-login`
- **THEN** CR 42's verdict has `dependency_not_merged` with subject `["add-login"]`

#### Scenario: One reason per unmerged id

- **WHEN** CR 42 depends on `add-login` and `add-sessions` and neither is linked by a merged change request
- **THEN** CR 42's verdict has two `dependency_not_merged` reasons, with subjects `["add-login"]` and `["add-sessions"]`, and `inputs.dependencies` `["add-login", "add-sessions"]`

### Requirement: A dependency's merge recomputes its dependents

When a change request that links a change id merges, closes, reopens, or moves between `draft` and `open`, or is created linking it, every `draft` or `open` change request of the project whose `dependencies` include that id SHALL get a recomputed verdict without a new Git facts report. The recompute MAY run after the transaction that made the change commits, and it MUST NOT be lost if that transaction commits. A dependencies update and a state change of a change request linking one of its ids MUST NOT both miss each other's change.

#### Scenario: Dependency merges

- **WHEN** CR 41 links `add-login`, CR 42 depends on `add-login` with an otherwise `mergeable` verdict, and CR 41's merge is reported
- **THEN** CR 42's verdict is recomputed to `mergeable` without CR 42 reporting new Git facts

#### Scenario: Dependent with a lower number

- **WHEN** CR 41 depends on `add-login` and CR 42, which links `add-login`, merges
- **THEN** CR 41's verdict is recomputed without `dependency_not_merged`

#### Scenario: Dependency closes

- **WHEN** CR 41 links `add-login`, CR 42 depends on it, and CR 41 is closed
- **THEN** CR 42's `dependency_not_merged` message says every change request linking `add-login` is closed

### Requirement: The dependencies route and rule are in the OpenAPI document

The OpenAPI document SHALL describe the dependencies `PUT` route with its `403`, `404`, `409` and `422` responses, the change request's `dependencies` field, and `dependency_not_merged` among the verdict reason rules.

#### Scenario: OpenAPI lists dependencies

- **WHEN** a client fetches the OpenAPI document
- **THEN** it has the dependencies route, the change request schema lists `dependencies`, and the reason rule enum includes `dependency_not_merged`
