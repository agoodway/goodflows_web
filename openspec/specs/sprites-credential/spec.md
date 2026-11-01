# sprites-credential Specification

## Purpose

Holds the Sprites API token an account uses for all of its Sprite VM operations, so runs act in that account's own Sprites organization without exposing the token.

## Requirements

### Requirement: One Sprites credential per account

Each account SHALL have at most one Sprites credential. Setting a credential when one exists MUST replace it.

#### Scenario: Set a credential

- **WHEN** a client sends `PUT /api/v1/sprites-credential` with a non-empty `token`
- **THEN** the API responds `200` with `configured: true`

#### Scenario: Replace a credential

- **WHEN** a credential exists and a client sends `PUT /api/v1/sprites-credential` with a different `token`
- **THEN** later runs use the new token

#### Scenario: Blank token

- **WHEN** a client sends `PUT /api/v1/sprites-credential` with a missing or blank `token`
- **THEN** the API responds `422` with an error on `token`

### Requirement: The token is never returned

No API response, log line, or error message SHALL include the stored token. `GET /api/v1/sprites-credential` MUST report only whether a credential is configured, the token's last four characters (or null for tokens of four or fewer characters), and when it was last updated.

#### Scenario: Read a configured credential

- **WHEN** a credential with token ending `a1b2` is set and a client sends `GET /api/v1/sprites-credential`
- **THEN** the API responds `200` with `configured: true`, `last4: "a1b2"`, and `updated_at`, and no `token` field

#### Scenario: Read with no credential

- **WHEN** no credential is set and a client sends `GET /api/v1/sprites-credential`
- **THEN** the API responds `200` with `configured: false`

#### Scenario: Short token metadata

- **WHEN** a non-empty token of four or fewer characters is configured
- **THEN** credential responses report `last4: null` and never return the complete token

### Requirement: The token is encrypted at rest

The stored token MUST be encrypted in the database. Reading the database row without the application's encryption key MUST NOT reveal the token.

#### Scenario: Stored value is ciphertext

- **WHEN** a credential with token `tok_example` is set
- **THEN** the persisted column value does not contain `tok_example`

### Requirement: Remove a credential

`DELETE /api/v1/sprites-credential` SHALL remove the account's credential and respond `204`. Removing when none exists MUST also respond `204`.

#### Scenario: Remove an existing credential

- **WHEN** a credential exists and a client deletes it
- **THEN** the API responds `204` and a later `GET` reports `configured: false`

### Requirement: Credential access control

Reading the credential status SHALL accept any valid API key. Setting and removing the credential MUST require a private (`sk_`) key whose user is an owner or admin of the account; any other key MUST receive `403`, and the OpenAPI document MUST list `403` for both operations.

#### Scenario: Public key cannot set

- **WHEN** a client with a `pk_` key sends `PUT /api/v1/sprites-credential`
- **THEN** the API responds `403` and the stored credential is unchanged

#### Scenario: Non-admin member cannot set or remove

- **WHEN** a client with an `sk_` key of a user who is a plain member (not owner or admin) of the account sends `PUT` or `DELETE /api/v1/sprites-credential`
- **THEN** the API responds `403` and the stored credential is unchanged

#### Scenario: Admin can set

- **WHEN** a client with an `sk_` key of an account admin sends `PUT /api/v1/sprites-credential` with a token
- **THEN** the API responds `200` and later runs use that token

### Requirement: One credential client per claimed run

A worker MUST fetch the current account credential once after claiming a queued run and use that client for the whole run. A replacement or removal MUST affect subsequent claims, while an already claimed run SHALL continue with its captured client. Plaintext tokens and clients MUST NOT be persisted in run snapshots or job payloads. If the credential is missing at claim time, the run MUST fail before any VM operation.

#### Scenario: Credential replaced before claim

- **WHEN** a run is queued and the account replaces its credential before the worker claims the run
- **THEN** the worker uses the replacement credential for every VM operation

#### Scenario: Credential removed before claim

- **WHEN** a run is queued and its credential is removed before the worker claims it
- **THEN** the run fails with a credential-configuration error and no VM operation occurs

#### Scenario: Credential changed during execution

- **WHEN** a claimed run's credential is replaced or removed while its steps execute
- **THEN** the run continues using its original client for all remaining operations
