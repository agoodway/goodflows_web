# Spec Delta

## Purpose

Defines project-scoped pools of pre-built Sprite VMs that clients lease to run jobs, and keeps each pool's members built, reset, and within capacity.

## ADDED Requirements

### Requirement: Pool schema
A pool SHALL belong to one project and have a `slug` (1 to 64 bytes matching `[a-z0-9][a-z0-9_-]*`, unique within its project), a `setup` list, `min_ready`, `max_members`, and an optional `idle_ttl_ms`. `setup` items MUST follow the recipe phase list rules: at most 500 non-empty strings of at most 10,000 characters each. An omitted `setup` MUST be stored as an empty list.

#### Scenario: Create a pool
- **WHEN** a client with a private key posts `{"slug": "rust-ci", "setup": ["curl -sSf https://sh.rustup.rs | sh -s -- -y"], "max_members": 4}` to `/api/v1/projects/app/pools`
- **THEN** the API responds `201` with the pool, including `min_ready` `1`, `setup_version` `1`, and the project's slug as `project`

#### Scenario: Duplicate slug in one project
- **WHEN** a client creates a second pool with slug `rust-ci` in the same project
- **THEN** the API responds `422` with an error on `slug`

#### Scenario: Same slug in another project
- **WHEN** a client creates pool `rust-ci` in a different project of the same account
- **THEN** the API responds `201`

### Requirement: Pool capacity bounds
`max_members` MUST be an integer from 1 to the server-configured per-pool cap. `min_ready` MUST be an integer from 0 to `max_members` and SHALL default to 1. `idle_ttl_ms` MUST be null (the default, meaning idle shrink is off) or an integer from 60,000 to 2,592,000,000 (30 days). A value outside these bounds MUST be rejected with `422` on that field. The database MUST also enforce `0 <= min_ready <= max_members` and `max_members >= 1`.

#### Scenario: min_ready above max_members
- **WHEN** a client saves a pool with `min_ready` 5 and `max_members` 4
- **THEN** the API responds `422` with an error on `min_ready`

#### Scenario: max_members above the server cap
- **WHEN** the server cap is 32 and a client saves a pool with `max_members` 33
- **THEN** the API responds `422` with an error on `max_members`

### Requirement: Pool setup has no placeholders or host steps
Pool `setup` items MUST be plain strings. A `{{…}}` token in a setup item MUST be rejected with `422` naming the token. A non-string item, including a `{host: …}` object, MUST be rejected with `422`.

#### Scenario: Placeholder in setup
- **WHEN** a client saves a pool whose setup contains `git checkout {{commit}}`
- **THEN** the API responds `422` naming `{{commit}}`

### Requirement: Pool body fields are restricted
A pool create or replace body MUST contain only `slug`, `setup`, `min_ready`, `max_members`, and `idle_ttl_ms`. Any other key, including `project`, `org`, and `setup_version`, MUST be rejected with `422` on that key, and storage MUST be left unchanged.

#### Scenario: Project in the body
- **WHEN** a client posts a pool whose body includes `project`
- **THEN** the API responds `422` with an error on `project` and no pool is created

### Requirement: Pool endpoints
The API SHALL provide `POST /api/v1/projects/:project/pools`, `GET /api/v1/projects/:project/pools`, `GET /api/v1/projects/:project/pools/:pool`, `PUT /api/v1/projects/:project/pools/:pool` (full replacement, the slug in the body must equal the path), `DELETE /api/v1/projects/:project/pools/:pool`, and `GET /api/v1/projects/:project/pools/:pool/members`. Each MUST be in the OpenAPI document. `:pool` is the pool slug. Listing MUST order pools by slug.

#### Scenario: Rename through replace
- **WHEN** a client puts a pool at `/pools/rust-ci` with body slug `rust`
- **THEN** the API responds `422` with an error on `slug` and the pool is unchanged

### Requirement: Pool access control
Reading pools and members SHALL accept any valid API key for the account. Creating, replacing, and deleting pools MUST require a private (`sk_`) key. A pool of another account, or addressed under another project of the same account, MUST respond `404`. The `:project` segment MUST follow the project slug rule used by recipe routes.

#### Scenario: Public key creates a pool
- **WHEN** a client with a `pk_` key posts a pool
- **THEN** the API responds `403`

#### Scenario: Pool under the wrong project
- **WHEN** pool `rust-ci` belongs to project `app` and a client gets `/api/v1/projects/web/pools/rust-ci` with a key of the same account
- **THEN** the API responds `404`

### Requirement: A Sprites credential is required for pools
Creating or replacing a pool MUST fail with `422` and an error stating that a Sprites credential must be configured when the account has none. The body MUST be validated first, so an invalid body reports its validation errors even without a credential.

#### Scenario: No credential
- **WHEN** an account without a Sprites credential posts a valid pool
- **THEN** the API responds `422` with the credential error and no pool is created

### Requirement: Pool responses report member state
A pool response MUST include `id`, `slug`, `project`, `setup`, `setup_version`, `min_ready`, `max_members`, `idle_ttl_ms` (or null), `status` (`active` or `credential_missing`), member counts by state, `provision_failures`, `next_provision_at` (or null), a sanitized `last_provision_error` (or null), and timestamps. A member response MUST include `id`, `name`, `state`, `setup_version`, `stale`, the id of the session leasing it (or null), any last error, and timestamps. Responses MUST NOT include checkpoint ids, worker owner ids, or the Sprites token.

#### Scenario: Member list
- **WHEN** a client lists members of a pool with one idle and one provisioning member
- **THEN** each member is listed with its `name` starting with `gfp-`, its `state`, and `stale` `false`

### Requirement: Member names use the reserved prefix
The server SHALL choose each member's sprite name. Names MUST start with `gfp-`, be valid sprite names, and be unique across all accounts. Clients MUST NOT be able to choose or change them.

#### Scenario: Server-chosen name
- **WHEN** the reconciler creates a member
- **THEN** its sprite name matches `^gfp-[a-z0-9-]+$` and differs from every other member's name

### Requirement: Members are provisioned with a golden checkpoint
Provisioning a member SHALL create its sprite, run the pool `setup` items in order through a shell (stopping at the first non-zero exit, error, or timeout), install and verify the compatible transfer helper after setup, and then take a checkpoint of that sprite as the member's golden state. Only a member whose setup, helper installation/version verification, and checkpoint all succeeded MUST become `idle`. Each setup item MUST be bounded by the server step timeout. Provisioning MUST atomically capture setup and setup_version at admission and retain that version on completion; a setup edit during provisioning MUST NOT relabel an old checkpoint as current.

#### Scenario: Setup succeeds
- **WHEN** a member's setup items all exit 0 and its checkpoint is created
- **THEN** the member becomes `idle` with the captured `setup_version`, and is eligible for grant only if that version is still current

#### Scenario: Setup fails
- **WHEN** the second setup item exits 1
- **THEN** later items do not run, no checkpoint is taken, and the member becomes `broken` with an error naming the failing item index and exit code

#### Scenario: Setup edited during provisioning
- **WHEN** setup version 2 is saved while a member is provisioning version 1
- **THEN** that member retains version 1, is never granted as current, and is destroyed and replaced

### Requirement: Members are reset after every lease
When a member is released, or its session expires, the member MUST be restored to its golden checkpoint before it can be granted again. A member being restored MUST be in state `resetting`. A failed restore MUST make the member `broken`.

#### Scenario: Reset after release
- **WHEN** a session releases a member that ran jobs which wrote files
- **THEN** the member is `resetting` until the restore completes, then `idle`, and a later session sees none of those files

### Requirement: Reconciler maintains capacity
The server SHALL periodically, and promptly after a pool change or an unmet session request, reconcile each active pool. While the count of non-broken members is below `max_members`, it MUST provision members until idle plus provisioning members reach `min_ready` plus the number of members waiting sessions still request. It MUST NOT create more than `max_members` members, counting broken members until they are destroyed.

#### Scenario: Keep min_ready warm
- **WHEN** a pool has `min_ready` 2, `max_members` 4, and one idle member
- **THEN** the reconciler provisions one more member

#### Scenario: Grow for demand
- **WHEN** a pool has `min_ready` 1 and one idle member, and a waiting session still wants 2 more members
- **THEN** the reconciler provisions members until there are at most `max_members` in total

#### Scenario: One failing pool
- **WHEN** reconciling one pool raises an error
- **THEN** the error is logged and every other pool is still reconciled in the same pass

### Requirement: Opt-in idle shrink
A pool with a non-null `idle_ttl_ms` SHALL have idle members that have been idle (since they last became `idle`) for longer than `idle_ttl_ms` destroyed by the reconciler, longest idle first, while more than `min_ready` plus the unmet wants of the pool's open sessions would remain idle. Leased, provisioning, and resetting members MUST NOT be affected. With `idle_ttl_ms` null (the default), idle members SHALL only be retired by the other rules (stale, broken, excess over `max_members`, unneeded credential namespace).

#### Scenario: Idle shrink enabled
- **WHEN** a pool has `min_ready` 1, `idle_ttl_ms` 60,000, no unmet session wants, two members idle for 2 minutes, and one idle for 1 second
- **THEN** the reconciler destroys both members idle for 2 minutes and keeps the one idle for 1 second

#### Scenario: Idle shrink keeps demand
- **WHEN** a pool has `min_ready` 1, `idle_ttl_ms` 60,000, three members idle for 2 minutes, and an open session still wanting 1 member
- **THEN** the reconciler destroys one member and keeps two idle

#### Scenario: Idle shrink off by default
- **WHEN** a pool has `min_ready` 1, no `idle_ttl_ms`, and three members idle for a day
- **THEN** all three stay idle

### Requirement: Broken members are destroyed and replaced
The reconciler MUST destroy the sprite of a `broken` member and remove the member, then replace it through normal capacity reconciliation. A pool whose provisioning keeps failing MUST NOT be rebuilt without a backoff, and its failure streak and next provisioning attempt MUST survive member destruction on the pool row. A successful provision or setup revision MUST clear that streak. Sanitized diagnostics and the next attempt time MUST be visible in pool responses, and in failed members' last error while those rows remain.

#### Scenario: Replace a broken member
- **WHEN** a member is broken because its restore failed
- **THEN** its sprite is destroyed and a new member is provisioned if capacity calls for it

#### Scenario: Repeated provisioning failure
- **WHEN** provisioning fails and the broken member is destroyed
- **THEN** the pool retains its failure streak and delays replacement until its next provisioning attempt time

### Requirement: Setup changes make members stale
Replacing a pool with a different `setup` MUST increment `setup_version`. Members built from an older version MUST report `stale` `true`. A stale member MUST NOT be granted to a new session, MUST finish any current lease, and MUST then be destroyed and replaced. Changing only `min_ready` or `max_members` MUST NOT change `setup_version`.

#### Scenario: Update setup
- **WHEN** a client replaces a pool's setup while one member is leased and one is idle
- **THEN** `setup_version` increases, the idle member is destroyed and replaced, and the leased member is destroyed after its session releases it

### Requirement: Helper upgrades make members stale
A member records the helper identity it was built with: the packaged helper's release `version` and protocol version, not the binaries' SHA-256. A member whose recorded helper is older than the server's packaged helper (a lower protocol version, or the same protocol and a lower release version in SemVer order) MUST report `stale` `true` and MUST follow the stale-member rules: it is not granted to a new session, finishes any current lease, and is then destroyed and replaced. A member whose recorded helper is the same or newer MUST NOT be stale; a member built with a protocol version the server does not speak MUST NOT be granted by that server. Rebuilding the same helper release MUST NOT make members stale. A server without a valid helper manifest MUST NOT treat any member as stale because of its helper.

#### Scenario: New helper deployed
- **WHEN** the server is deployed with a new helper release while a pool has one idle and one leased member built with the old release
- **THEN** both report `stale` `true`, the idle member is destroyed and replaced, and the leased member is destroyed after its session releases it

#### Scenario: Rolling deploy
- **WHEN** during a rolling deploy a node still on the old helper release reconciles a pool whose idle members were built by a node with the new release
- **THEN** those members are not stale on the old node and are not destroyed

#### Scenario: Rebuilt helper
- **WHEN** the server is redeployed with a rebuild of the same helper release whose binaries have different SHA-256 values
- **THEN** no member becomes stale

### Requirement: Lowering max_members drains extra members
When `max_members` is lowered below the current member count, the reconciler MUST destroy idle members first and MUST NOT revoke leased members. Leased members above the new limit MUST be destroyed when released, not reset.

#### Scenario: Shrink a busy pool
- **WHEN** a pool with 4 members, 3 of them leased, is replaced with `max_members` 2
- **THEN** the idle member is destroyed, and released members are destroyed until 2 remain

### Requirement: Credential changes pause provisioning
When the account has no Sprites credential, the pool MUST report `status` `credential_missing` and the reconciler MUST NOT provision members, and MUST NOT retire idle members for belonging to another credential namespace (there is no current one); reset and destruction of existing members MUST continue using each member's creation-credential snapshot. Sessions that already hold members SHALL continue using their captured credential. Credential replacement MUST NOT grant a member from another credential namespace to an existing session. Background reset/destruction MUST use each member's encrypted creation-credential snapshot, never an unrelated replacement token; successful deletion or `not_found` under that original credential permits row removal. Cleanup authorization failures MUST retain the row and sanitized retry diagnostics; a member whose destruction failed with an authorization error (`401`/`403`) after 5 failures in total MUST become `abandoned`: it is no longer retried, the API shows it with that state and its last error, it still counts toward `max_members`, an operator can forget it explicitly (with an audit log line), and deleting its pool forgets it with a log line naming it instead of waiting forever. Old-generation idle members MAY serve matching existing sessions and MUST be retired when no such session needs them; warm/new provisioning uses the current credential. Restoring a credential MUST resume provisioning. Removing or replacing the account credential MUST NOT delete member creation-credential snapshots; they remain encrypted, are never returned, and are deleted with their member row once the member is destroyed.

#### Scenario: Credential removed
- **WHEN** an account removes its Sprites credential while a pool has idle members
- **THEN** the pool reports `credential_missing` and no new member is provisioned

#### Scenario: Credential revoked before cleanup
- **WHEN** a member's sprite cannot be destroyed because its creation credential is rejected with `401` for the fifth time
- **THEN** the member becomes `abandoned`, is no longer retried, and deleting its pool completes, logging the member's name

#### Scenario: Credential namespace changes
- **WHEN** a credential for another Sprites organization replaces the account credential
- **THEN** existing sessions keep only matching members, new sessions receive members from the new namespace, and old members are cleaned up with their original credential without silently orphaning them on authorization failure

### Requirement: Pools can be disabled
When pools are disabled by server configuration, or the pool helper artifact manifest is missing or invalid, pool, session, workspace, and report routes MUST respond `503`, except pool deletion, and pool socket connections MUST be refused. No member SHALL be granted or provisioned and no member SHALL be retired as stale. So that a rollback can be cleaned up, sessions MUST still expire, members MUST still be reset and destroyed (broken members, members of ended sessions, and members of deleted pools), and pool deletion MUST still be accepted and completed. In production, a node configured with pools enabled whose helper manifest is missing or invalid MUST refuse to boot. A node that is draining for shutdown MUST refuse new sessions and execs.

#### Scenario: Pools disabled
- **WHEN** pools are disabled and a client lists the pools of a project
- **THEN** the API responds `503` and the reconciler provisions and grants nothing

#### Scenario: Rollback cleanup
- **WHEN** pools are disabled while a session has gone without a client past the disconnect grace and a client deletes another pool
- **THEN** the session expires, the deletion responds `202`, and that pool's members are destroyed and its row removed

#### Scenario: Release without a helper manifest
- **WHEN** a production release with pools enabled boots without `priv/gf-transfer/manifest.json`
- **THEN** the node refuses to start, naming the packaging step

### Requirement: Deleting a pool
Deleting a pool that has any nonterminal session (`waiting` or `active`) MUST respond `409` and change nothing. The deletion check and marking MUST hold the same pool lock as session creation and grants. Otherwise the pool MUST respond `202`, become invisible to reads (`404`), refuse new sessions, and have all its member sprites destroyed in the background before its row is removed.

#### Scenario: Delete an idle pool
- **WHEN** a client deletes a pool with no waiting or active sessions
- **THEN** the API responds `202`, a later show responds `404`, and its member sprites are destroyed

#### Scenario: Delete a pool in use
- **WHEN** a client deletes a pool that has an active session
- **THEN** the API responds `409` and the pool and its members remain

#### Scenario: Delete while a session is waiting
- **WHEN** a client deletes a pool with a waiting session that has no grants
- **THEN** the API responds `409` and the pool and session remain
