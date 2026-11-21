# Spec Delta

## MODIFIED Requirements

### Requirement: Change request routes require a key of the account
Every route under `/api/v1/projects/:project/change-requests` SHALL require a valid API key for the project's account. Missing, expired or revoked keys MUST return `401`. `ck_` keys MUST return `403` on every route. `pk_` keys MUST be allowed, with redaction, on `GET` routes except `.../review` and `.../tasks` (`sk_` only), and MUST return `403` on every other route. An invalid project slug returns `422` on `project`; an unknown slug returns `404`.

#### Scenario: Private key opens a change request
- **WHEN** a client with an `sk_` key posts a valid change request to project `goodcases` of its account
- **THEN** the API responds `201`

#### Scenario: Public key reads
- **WHEN** a client with a `pk_` key lists the change requests of project `goodcases`
- **THEN** the API responds `200`

#### Scenario: Public key cannot write
- **WHEN** a client with a `pk_` key creates a change request, reports Git facts, uploads claims, or changes a state
- **THEN** the API responds `403`, does not read the body, and stores nothing

#### Scenario: Public key and review routes
- **WHEN** a client with a `pk_` key reads `.../change-requests/1/review` or `.../change-requests/1/tasks`
- **THEN** the API responds `403`

#### Scenario: Cache key
- **WHEN** a client with a `ck_` key bound to project `goodcases` lists that project's change requests
- **THEN** the API responds `403`

#### Scenario: Missing key
- **WHEN** a client with no key, an expired key, or a revoked key shows change request `1`
- **THEN** the API responds `401`

#### Scenario: Other account's project
- **WHEN** a client lists change requests of a slug that exists only on another account
- **THEN** the API responds `404`

### Requirement: The verdict has four states
A change request's verdict SHALL have `state` `pending` (an input is missing at the head), `blocked` (an input fails), `needs_review` (rules fired that need a person) or `mergeable` (no rule fired, or every reason is a `needs_review` reason cleared by answers at the head). It MUST carry the `head` (or null), the `policy_version`, `reasons`, the input digests under `inputs`, and `computed_at`. A verdict is computed in `draft` and `open`.

#### Scenario: Nothing fired
- **WHEN** a change request has Git facts and claims for head `H`, every required workflow passed on `H`, and no rule fires
- **THEN** the verdict is `mergeable` with `reasons` `[]`, `head` `H`, and the project's current policy version

#### Scenario: Verdict on a draft
- **WHEN** a `draft` change request gets Git facts and claims
- **THEN** its verdict is computed and is not `pending` because of the state

### Requirement: The verdict takes the highest-precedence outcome
The verdict `state` MUST be the highest-precedence outcome of all rules that fired, with precedence `pending`, then `blocked`, then `needs_review`, and `mergeable` when no rule fired or every reason that fired is a `needs_review` reason cleared by answers at the head. `reasons` MUST list every rule that fired, cleared or not, ordered by outcome precedence, then `rule`, then `subject`.

#### Scenario: Pending outranks blocked
- **WHEN** required workflow `ci` failed on the head and required workflow `e2e` has no run on it
- **THEN** the verdict is `pending` and `reasons` holds a `required_workflow_missing` reason for `e2e` and a `required_workflow_failed` reason for `ci`

#### Scenario: Blocked outranks needs_review
- **WHEN** required workflow `ci` failed and the claims have `door` `one_way` under a `needs_review` setting
- **THEN** the verdict is `blocked` and `reasons` includes the `one_way_door` reason

#### Scenario: Open items split into several items
- **WHEN** the only reason is `open_items` with 2 claims questions, and one question is answered `choose` at the head
- **THEN** the verdict stays `needs_review` until the other question is answered `choose`

## ADDED Requirements

### Requirement: Answers resolve needs_review
A verdict whose highest-precedence outcome is `needs_review` SHALL become `mergeable` when every review packet item at the current head has a current answer of `approve` or `choose`. A reason is cleared when every item made from it is, so an `open_items` reason needs all of its `question` and `open_item` items. An item whose current answer is `request_change` or `reject`, or that has no answer, MUST keep the verdict at `needs_review`. The reasons MUST stay in the verdict after they are cleared.

#### Scenario: All items approved
- **WHEN** change request 42 has `one_way_door` and `size` items at head `a1b2c3d…`, and both are answered `approve` at that head
- **THEN** the verdict at `a1b2c3d…` is `mergeable` and still lists both reasons

#### Scenario: One item asks for a change
- **WHEN** one of two items is answered `approve` and the other `request_change`
- **THEN** the verdict stays `needs_review`

#### Scenario: Question answered by choose
- **WHEN** the only item is a `question` answered `choose` with option `keep`
- **THEN** the verdict is `mergeable`

### Requirement: Answers never override blocked or pending
Answers SHALL clear only `needs_review` items. A `scenario_set_approval` answer clears no item itself; it acts only through the scenario set decision it records. A verdict with any `blocked` reason MUST stay `blocked`, and one with any `pending` reason MUST stay `pending`, whatever answers exist. Answers given while the verdict is `blocked` or `pending` SHALL be stored and SHALL count once those reasons are gone at the same head.

#### Scenario: Blocked with every item approved
- **WHEN** a Must scenario failed at the head and every item is answered `approve`
- **THEN** the verdict is `blocked`

#### Scenario: Pending clears at the same head
- **WHEN** every item is approved while the `ci` run is missing, and then a passing `ci` run on the same head is stored
- **THEN** the verdict becomes `mergeable` without new answers

### Requirement: The verdict is recomputed on review input
The verdict SHALL be recomputed inside the transaction that stores an answer, replaces an answer, or records a scenario set approval or rejection through an answer.

#### Scenario: Last approval
- **WHEN** the last open item is answered `approve`
- **THEN** the verdict read right after the `201` is `mergeable`

### Requirement: The verdict reports review progress
The verdict response SHALL include `review` with `items` (the number of packet items at the head) and `cleared` (the number with a current `approve` or `choose` answer at the head). A `scenario_set_approval` item is counted in `items` but never in `cleared`: it is cleared only by the set's approval, which removes it from the packet.

#### Scenario: Progress counts
- **WHEN** a head has 3 items, 2 answered `approve` and 1 answered `request_change`
- **THEN** the verdict has `review` `{"items": 3, "cleared": 2}`

#### Scenario: New head resets progress
- **WHEN** a new head is reported with 3 items
- **THEN** the verdict has `review` `{"items": 3, "cleared": 0}`
