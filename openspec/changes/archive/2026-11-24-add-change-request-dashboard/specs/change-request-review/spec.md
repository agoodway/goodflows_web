## MODIFIED Requirements

### Requirement: Answers bind to the head
Each answer SHALL store the item `id`, `kind`, `rule`, the head it was given at, `answer`, `option`, `note`, the membership, the key, the channel and the time. A `head` in the body that is not the change request's current head MUST return `409` with the current head and store nothing. Only answers at the current head SHALL count and appear in the packet, whatever their channel.

#### Scenario: Stale head
- **WHEN** a client answers with `head` `a1b2c3d…` after head `d4e5f6a…` was reported
- **THEN** the API responds `409` with `head` `d4e5f6a…` and stores nothing

#### Scenario: Recorded fields
- **WHEN** a client answers `choose` with option `keep` and note `fine for v1`
- **THEN** the stored answer has the item `id`, the head, `choose`, `keep`, `fine for v1`, the key's membership and key, and channel `cli`

## ADDED Requirements

### Requirement: Answers record their channel
The channel MUST be `cli` for an answer made through the API, where the key is the request's key, and `dashboard` for an answer made in the dashboard, where the key is null and the membership is the signed-in member's.

#### Scenario: Dashboard answer in the packet
- **WHEN** member M approves an item at the current head in the dashboard and an `sk_` client then reads the packet
- **THEN** the item's answer is `approve` with `channel` `dashboard`, M's `user_id` and `key_id` null, and the verdict counts it as cleared

### Requirement: Dashboard members follow the answer rules
In the dashboard, the signed-in member's membership SHALL be held to the same rules as a key's membership.

#### Scenario: Plain member approves a set in the dashboard under admin
- **WHEN** `scenarios.approver` is `admin` and a member with role `member` tries to approve a `scenario_set_approval` item in the dashboard
- **THEN** nothing is stored
