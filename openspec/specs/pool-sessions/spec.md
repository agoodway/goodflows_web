# pool-sessions Specification

## Purpose

Lets one client invocation lease members of a pool for its jobs, place its working tree on them, stay alive across brief disconnects, and return the members for reset when it is done.

## Requirements

### Requirement: Create a session
`POST /api/v1/projects/:project/pools/:pool/sessions` SHALL require `max_members` (1 to the pool's `max_members`) and `acquire_timeout_ms` (1,000 to a server maximum) and respond `201` with the session, in status `waiting`, wrapped in a `data` object. It MUST require a private (`sk_`) key and MUST record the key that created it. A deleted or unknown pool MUST respond `404`.

#### Scenario: Start a session
- **WHEN** a client with a private key posts `{"max_members": 4, "acquire_timeout_ms": 120000}` to a pool's sessions
- **THEN** the API responds `201` with `data` holding the session `id`, status `waiting`, and the channel topic `pool_session:<id>`

#### Scenario: Request more than the pool allows
- **WHEN** a pool has `max_members` 4 and a client requests `max_members` 5
- **THEN** the API responds `422` with an error on `max_members`

### Requirement: Session body fields are restricted
A session create body MUST contain only `max_members`, `acquire_timeout_ms`, and an optional `label` (at most 255 characters, no control characters). Any other key MUST be rejected with `422` on that key, and no session is created.

#### Scenario: Unknown key
- **WHEN** a client posts a session with `{"max_members": 2, "acquire_timeout_ms": 60000, "priority": 9}`
- **THEN** the API responds `422` with an error on `priority`

### Requirement: Members are granted partially
The server SHALL grant idle, non-stale members of the pool whose internal credential fingerprint matches the session's captured credential to a session one at a time, while its holdings are below its current `wanted` count (initially its `max_members`), as members become available. A session MUST become `active` on its first grant and MUST NOT wait for its full request. Each grant MUST be announced on the session channel.

#### Scenario: One free member
- **WHEN** a session requests 4 members and the pool has 1 idle member
- **THEN** the session is granted that member, becomes `active`, and receives more grants as members are provisioned or released

### Requirement: Grants are fair across sessions
Among sessions eligible for the available member's credential namespace, when several sessions of a pool are waiting for members, the server MUST grant each newly available member to the session whose request has been unmet the longest, counting each session's time since its last grant. A session holding members MUST NOT receive another until every eligible waiting session with zero members has received one.

#### Scenario: Two sessions compete
- **WHEN** session A holds 2 members and wants 2 more, session B holds none, and one member becomes idle
- **THEN** that member is granted to session B

#### Scenario: Fairness across a batch of idle members
- **WHEN** two sessions with unmet demand compete for several idle members in one grant transaction
- **THEN** priority is recomputed after each individual grant using time since last grant, with zero-holding sessions served first

### Requirement: Acquire timeout fails the session
A session that has received no member by `acquire_timeout_ms` after creation MUST become `expired` with reason `no_member_available`, and the channel MUST announce it. The server MUST NOT run anything for that session. A session that already holds a member MUST NOT expire because of this timeout.

#### Scenario: Pool fully busy
- **WHEN** all members are leased by other sessions for longer than the new session's `acquire_timeout_ms`
- **THEN** the session becomes `expired` with reason `no_member_available`

#### Scenario: Acquisition deadline after a first grant
- **WHEN** a session receives a member, explicitly releases its last member, and later passes its acquisition deadline
- **THEN** it does not expire with `no_member_available` and no replacement is granted until wanted is raised

### Requirement: Clients can ask for fewer or more members
Over the session channel a client SHALL be able to raise or lower its wanted member count within 0 and the request's `max_members` with a `want` event (`{wanted}`), and to release one member it holds with a `release_member` event (`{member_id}`). `wanted` means desired total holdings and starts at the requested maximum. Lowering wanted MUST NOT revoke already granted members. Releasing a member MUST atomically reduce wanted to the lesser of its previous value and the remaining holdings (possibly zero), so the server does not automatically replace it; a later want increase MAY request replacements. A released member MUST be reset before any session receives it. Releasing a member with a running exec MUST cancel that exec first, and no new exec MAY be admitted on it in between; waiting for that cancel MUST NOT keep the session's server from renewing its lease or answering other requests. A cancel whose remote kill cannot be confirmed MUST NOT also report the member lost (the release resets it), so the release still succeeds and lowers `wanted`. When the server running the session cannot be reached (and is not confirmed lost), `release_member` MUST be refused with `unavailable` and the member stays held.

#### Scenario: Release an unneeded member
- **WHEN** a client with 3 members releases one because no more jobs are ready
- **THEN** that member is reset and returned to the pool, and the session keeps the other 2

#### Scenario: Release while the exec stop is slow
- **WHEN** a client releases a member whose running exec takes 30 seconds to stop
- **THEN** the session's server keeps renewing its lease and answering meanwhile, refuses new execs on that member, and completes the release once the exec has stopped

#### Scenario: Release while the session's server is unreachable
- **WHEN** a client releases a member while the server running its session cannot be reached
- **THEN** the release is refused with `unavailable` and the member stays granted

### Requirement: Workspace upload
`PUT /api/v1/pool-sessions/:id/workspace` SHALL accept a gzip-compressed tar body (`application/gzip`) up to a server-configured size limit, at most once per session. The server MUST extract it into `/workspace` in every member granted to the session, including members granted later. GoodFlows-to-member archive delivery MUST use bounded resumable binary transfers as defined by `sprite-transfers`, including for late grants. The initial client HTTP upload is not resumable in this change. A member MUST NOT be reported ready for execs until its complete archive is checksum-verified and its workspace is extracted. A body whose Content-Type is not `application/gzip`, or whose Content-Encoding is neither absent nor `identity`, MUST respond `415`. A declared Content-Length above the limit MUST respond `413` before any spool reservation. A second upload MUST respond `409`. An upload that cannot reserve its size from the node spool budget or from the account's share of it (`spool_account_max_bytes`, covering uploads and report downloads together), or that exceeds the per-account concurrent-upload cap, MUST respond `503` with `Retry-After` and remain retryable. Once an upload is recorded, its reservation MUST shrink to the archive's actual size for as long as the spooled archive is kept. A body that cannot be read MUST respond `400` and remain retryable. An upload whose body is not fully received within the configured read deadline MUST respond `408`, release its reservation, and remain retryable. Admission of concurrent uploads MUST be atomic; a failed validation releases the reservation for retry. An upload completing after session end MUST NOT publish readiness or alter a new lease.

#### Scenario: Upload once
- **WHEN** a client uploads a 20 MiB workspace tarball to an active session with 2 members
- **THEN** the API responds `204` and both members are announced as ready on the channel

#### Scenario: Finished upload frees its unused reservation
- **WHEN** a 2 MiB workspace is uploaded with a 256 MiB limit
- **THEN** the node spool holds 2 MiB for that session, not 256 MiB, while the session lasts

#### Scenario: Oversized upload
- **WHEN** a client uploads a body larger than the configured workspace limit
- **THEN** the API responds `413` and no member is changed

#### Scenario: Upload and later grant on different nodes
- **WHEN** upload reaches one node and a later member is granted by another
- **THEN** both use the session coordinator's spool and the member is ready only after owner-routed hydration

#### Scenario: Hydration is sequential per session
- **WHEN** a workspace is uploaded to a session holding 3 members
- **THEN** the members receive it one after another, each announced `member_ready` when its extraction finishes

#### Scenario: Missed grant announcement
- **WHEN** a member is granted to a session that has a workspace but the session's server misses the grant announcement
- **THEN** the member is still hydrated, at the session server's next lease renewal

### Requirement: Workspace archives are confined
Validation and extraction MUST enforce configured expanded-byte, entry-count, and wall-clock limits in addition to the compressed limit. Preflight limit breaches MUST respond `413`, corrupt archives MUST respond `422`, and preflight failures MUST NOT modify members. Extraction-time disk or deadline failures may occur after writes and MUST follow the member-loss/reset rule below. Extraction MUST reject unsupported special entries (including FIFOs and sockets) and an archive containing absolute paths, `..` path segments, device files, or links that resolve outside `/workspace`, including escaping link chains or duplicate-entry interactions. Only regular files, directories, and links proven confined by full entry metadata validation MAY be extracted. Path and link names carried in GNU long-name/long-link entries and PAX extended headers MUST be validated like plain names, and a global PAX header that sets `path`, `linkpath`, or `size` MUST be rejected. Validation MUST complete before member writes, and extraction MUST also guard against preexisting escaping links. An archive rejected during preflight for confinement or entry-type violations MUST respond `422`, MUST leave the session without a workspace, and MUST allow a corrected upload.

#### Scenario: Path traversal
- **WHEN** an uploaded archive contains the entry `../etc/passwd`
- **THEN** the API responds `422` and the session accepts a later valid upload

### Requirement: Workspace hydration failure on a member
If delivering or extracting the workspace into a member fails, including exhausted transfer retries, a restart-required integrity failure, staging disk-full, or extraction failure, that member MUST be released for reset and announced as lost on the channel, and the session MUST keep its place in the grant queue to receive a replacement. A member whose transfer helper is missing or incompatible MUST instead become `broken`, and MUST also be announced as lost with the session keeping its place.

#### Scenario: Extraction fails on one member
- **WHEN** extraction fails on one of two members
- **THEN** the channel announces that member as lost and the session is offered another member

#### Scenario: Hydration worker dies
- **WHEN** the process delivering the workspace to a member dies without reporting a result
- **THEN** the member is announced lost and reset, and the session is offered another member

#### Scenario: Transfer requires restart
- **WHEN** a member's workspace transfer reports restart required after a final hash mismatch
- **THEN** the channel announces that member as lost, it is reset, and the session is offered another member

### Requirement: Sessions stay alive while connected
A session SHALL stay alive while at least one channel subscriber of the creating key is joined to it. When none is joined for the configured disconnect grace (default 60 seconds), the session MUST become `expired` with reason `client_disconnected`. Its running execs MUST be cancelled and its members reset.

#### Scenario: Brief disconnect
- **WHEN** a client's socket drops and the client rejoins within the grace
- **THEN** the session stays `active` and its members and execs are unchanged

#### Scenario: Client gone
- **WHEN** no client is joined to an active session for longer than the grace
- **THEN** the session becomes `expired` with reason `client_disconnected`, running execs are cancelled, and members are reset

### Requirement: Sessions have a maximum lifetime
A session MUST become `expired` with reason `lifetime_exceeded` once a server-configured maximum lifetime since creation has passed. Its execs MUST be cancelled and its members reset.

#### Scenario: Lifetime reached
- **WHEN** a session is still active after the maximum lifetime
- **THEN** it becomes `expired` with reason `lifetime_exceeded`

### Requirement: Release a session
`DELETE /api/v1/pool-sessions/:id`, or a `release` event over the session channel, SHALL end the session as `released`, cancel its running execs, and reset its members. Releasing an ended session MUST respond `204` and change nothing.

#### Scenario: Normal end
- **WHEN** a client deletes its active session after its jobs finish
- **THEN** the API responds `204`, the session is `released`, and its members become `resetting`

### Requirement: Sessions are owned by their creating key
Only the API key that created a session MAY join, upload to, or release it, or run execs in it. Another key of the same account MUST receive `403`. A key of another account MUST receive `404`. Deleting or revoking the creating key MUST expire the session with reason `key_revoked`.

#### Scenario: Another key of the account
- **WHEN** a second private key of the same account deletes the session
- **THEN** the API responds `403` and the session continues

#### Scenario: Creating key revoked
- **WHEN** the key that created an active session is revoked
- **THEN** the session becomes `expired` with reason `key_revoked`, running execs end `cancelled`, and members are reset

### Requirement: Session records are retrievable
`GET /api/v1/pool-sessions/:id` SHALL return, wrapped in a `data` object, the session's `status` (`waiting`, `active`, `released`, or `expired`), any end reason, `max_members`, `label`, the pool slug and project slug, the members currently granted, whether a workspace was uploaded, and timestamps. It SHALL accept any valid key of the account. It MUST NOT return the workspace contents, command lines, environment values, or output. The end reason MUST be null while the session is `waiting`, `active`, or `released`, and one of `no_member_available`, `client_disconnected`, `lifetime_exceeded`, `key_revoked`, or `session_owner_lost` when `expired`; `session_ended` events and `ended` join refusals carry the same reason.

#### Scenario: Read an expired session
- **WHEN** a client reads a session that expired because its client disconnected
- **THEN** the response has status `expired`, reason `client_disconnected`, and no granted members

### Requirement: Ended sessions are retained for a bounded time
Ended sessions (`released` or `expired`) and their execs (including persisted exit payloads) SHALL be deleted by the reconciler once they ended longer ago than a server-configured retention period (default 30 days). Open sessions MUST never be deleted by retention.

#### Scenario: Old session purged
- **WHEN** a session ended 31 days ago with the default retention
- **THEN** the session and its execs are deleted, and reading it responds `404`

### Requirement: Session operations require a credential
Creating a session MUST fail with `422` stating that a Sprites credential must be configured when the account has none. A session MUST capture the account's credential once at creation and use it for all of its member operations, so a later credential change does not affect it. The session coordinator MUST hold the snapshot only in memory and service resource-dependent operations across nodes through bounded owner RPC. A confirmed lost coordinator, or an owner unreachable beyond the disconnect grace, MUST end the session with reason `session_owner_lost`; it MUST NOT silently refetch a replacement credential. An owner on a node the server has not connected to (for example right after it booted) is unreachable, not confirmed lost. A coordinator that cannot renew its lease (for example during a database outage) MUST retry until the lease deadline it last recorded, MUST NOT crash on a transient database error, and once that deadline passes MUST admit no further work and stop, discarding its resources. Member reuse MUST wait for fenced worker recovery before reset.

#### Scenario: Credential replaced mid-session
- **WHEN** the account replaces its credential while a session is active
- **THEN** the session's execs continue with the credential captured at creation

#### Scenario: Owner on a node not yet connected
- **WHEN** a freshly booted node leads the reconciler before it has connected to the node owning a session whose lease is current
- **THEN** that session is not expired and its execs and members are untouched

#### Scenario: Database outage shorter than the lease
- **WHEN** the session coordinator's lease renewal fails for 10 seconds and then succeeds, with a 60-second disconnect grace
- **THEN** the coordinator keeps running and the session continues

#### Scenario: Session owner is lost
- **WHEN** the session coordinator dies or remains unreachable beyond disconnect grace
- **THEN** the session expires with `session_owner_lost`, running execs end with status `error` and `error_reason` `owner_lost`, and members remain unavailable until fenced recovery permits reset
