# Spec Delta

## Purpose

Stores goodflows job cache archives for a project as immutable, branch-scoped entries in S3-compatible object storage. Clients reserve, upload and commit entries through presigned URLs and restore them by exact key or by partial key. Cache keys give remote runners access to one project's caches and nothing else.

## ADDED Requirements

### Requirement: Cache routes require a key with cache access
Every route under `/api/v1/projects/:project/caches` SHALL require a valid API key for the project's account. Missing, expired or revoked keys MUST return `401`. Public (`pk_`) keys MUST return `403` on every cache route. A cache (`ck_`) key MUST return `403` on a project other than the one it is bound to. Lookup, reserve and commit accept `sk_` keys and `ck_` keys. Listing and purging accept only `sk_` keys. An invalid slug returns `422` on `project`, and an unknown slug returns `404`.

#### Scenario: Public key reads a cache
- **WHEN** a client with a `pk_` key looks up an entry that exists
- **THEN** the API responds `403` and returns no download URL

#### Scenario: Cache key on another project
- **WHEN** a `ck_` key bound to project `alpha` looks up an entry in project `beta` of the same account
- **THEN** the API responds `403`

#### Scenario: Cache key lists entries
- **WHEN** a client with a `ck_` read-write key lists a project's caches or purges an entry
- **THEN** the API responds `403` and deletes nothing

#### Scenario: Missing key
- **WHEN** a client with no key reserves an entry
- **THEN** the API responds `401` and reserves nothing

### Requirement: Cache keys cannot use other routes
A `ck_` key MUST be refused with `403` on every route outside `/api/v1/projects/:project/caches`, including read routes such as `GET /api/v1/projects`, `GET /api/v1/me` and `GET /api/v1/projects/:project/workflow-runs`, and write routes such as `POST /api/v1/projects/:project/test-reports` and `POST /api/v1/projects/:project/cache-keys`.

#### Scenario: Cache key reads workflow runs
- **WHEN** a client with a `ck_` key lists the workflow runs of its own project
- **THEN** the API responds `403`

#### Scenario: Cache key mints a cache key
- **WHEN** a client with a `ck_` read-write key posts to `/api/v1/projects/:project/cache-keys`
- **THEN** the API responds `403` and creates no key

### Requirement: Private keys mint cache keys
`POST /api/v1/projects/:project/cache-keys` SHALL require an `sk_` key and SHALL accept `access` (`read` or `read_write`, required), `scope` (optional, the scope rule), `ttl_seconds` (optional), and `name` (optional, at most 100 characters). It MUST respond `201` with the key's `id`, `token`, `access`, `scope` and `expires_at`. The token starts with `ck_` and MUST appear in no later response.

#### Scenario: Mint a bound read-write key
- **WHEN** a client with an `sk_` key mints `{"access": "read_write", "scope": "feature/login", "ttl_seconds": 3600}`
- **THEN** the API responds `201` with a `ck_` token whose `expires_at` is one hour later, bound to that project and scope

#### Scenario: Public key mints
- **WHEN** a client with a `pk_` key mints a cache key
- **THEN** the API responds `403` and creates no key


#### Scenario: Read key with a scope
- **WHEN** a client mints `{"access": "read", "scope": "feature/login"}`
- **THEN** the API responds `201` and the key may read only `feature/login` and the default-branch scope

### Requirement: Cache key lifetimes depend on access
Minting MUST be the only way to create a cache key. Without `ttl_seconds`, a key MUST expire after 21,600 seconds. A `read_write` key MUST take `ttl_seconds` from 60 through 86,400 and MUST NOT be created without an expiry. A `read` key MUST take `ttl_seconds` from 60 through 31,536,000, or `null` for no expiry, and a `null` MUST require a `name`. An out-of-range or disallowed `ttl_seconds` MUST respond `422` on `ttl_seconds` and create no key. An expired key MUST get `401`.

#### Scenario: Long-lived read key
- **WHEN** a client with an `sk_` key mints `{"access": "read", "ttl_seconds": null, "name": "orb setup"}`
- **THEN** the API responds `201` with `expires_at` null, and the key still restores caches after the sweep runs a year later

#### Scenario: Read-write key without expiry
- **WHEN** a client mints `{"access": "read_write", "ttl_seconds": null}`
- **THEN** the API responds `422` with an error on `ttl_seconds` and creates no key

#### Scenario: Out-of-range TTL
- **WHEN** a client mints a `read_write` key with `ttl_seconds` `86401`, or any key with `59`
- **THEN** the API responds `422` with an error on `ttl_seconds`

#### Scenario: Unnamed key without expiry
- **WHEN** a client mints `{"access": "read", "ttl_seconds": null}` without `name`
- **THEN** the API responds `422` with an error on `name`

#### Scenario: Omitted TTL
- **WHEN** a client mints a `read` key without `ttl_seconds`
- **THEN** the key's `expires_at` is 21,600 seconds after it was created

#### Scenario: Key used after expiry
- **WHEN** a key minted with `ttl_seconds` `60` is used two minutes later
- **THEN** the API responds `401`

### Requirement: Long-lived read keys only read
A non-expiring or long-TTL `read` key MUST have the same access as any `read` cache key. Unbound, it MUST be able to look up any scope with the D4 fallback. Bound to a scope, it MUST be limited like any bound key. It MUST NOT reserve, commit, list entries, purge, or mint.

#### Scenario: Orb restores a feature branch
- **WHEN** an unbound non-expiring `read` key looks up a partial with `scope` `feature/login`
- **THEN** the API responds as for any read key, searching `feature/login` and then the default-branch scope

#### Scenario: Orb key bound to the default branch
- **WHEN** a client with an `sk_` key mints `{"access": "read", "ttl_seconds": null, "scope": "main", "name": "orbs"}`, `main` is the default branch, and the key looks up a partial with `scope` `main` or without `scope`
- **THEN** the mint responds `201` and the lookup searches only the `main` scope

#### Scenario: Orb key asks for a feature branch
- **WHEN** a non-expiring `read` key bound to `main` looks up a partial with `scope` `feature/login`
- **THEN** the API responds `403`

#### Scenario: Long-lived key tries to save
- **WHEN** an unbound non-expiring `read` key reserves an entry
- **THEN** the API responds `403` and reserves nothing

### Requirement: Private keys list cache keys
`GET /api/v1/projects/:project/cache-keys` SHALL require an `sk_` key and return the project's cache keys that are neither revoked nor expired, newest first and keyset-paged, with `id`, `name`, `access`, `scope`, `token_prefix`, `expires_at`, `last_used_at` and `inserted_at`. It MUST NOT return a token.

#### Scenario: Find a long-lived key
- **WHEN** a project has a non-expiring `read` key and a revoked key, and a client with an `sk_` key lists cache keys
- **THEN** the response contains the non-expiring key without its token, and not the revoked key

#### Scenario: Cache key lists keys
- **WHEN** a client with a `ck_` key lists cache keys
- **THEN** the API responds `403`

### Requirement: Private keys revoke cache keys
`DELETE /api/v1/projects/:project/cache-keys/:id` SHALL require an `sk_` key, revoke a cache key of that project, and respond `204`, including when it is already revoked. It MUST respond `404` for a key of another project and for a non-cache key. A revoked key MUST get `401` on its next request.

#### Scenario: Revoke a minted key
- **WHEN** a client revokes a minted key and the key is then used to look up an entry
- **THEN** the revoke responds `204` and the lookup responds `401`

#### Scenario: Revoke a private key through the cache-key route
- **WHEN** a client deletes the id of an `sk_` key through `/cache-keys/:id`
- **THEN** the API responds `404` and the key still works

### Requirement: Scope access depends on the key
An `sk_` key and an unbound `ck_` key SHALL read any scope. An unbound `ck_` read-write key and an `sk_` key SHALL write any scope. A `ck_` key bound to scope `B` MUST be allowed to read only with `scope` `B`, with `scope` equal to the project's default branch, or with no `scope`. A `ck_` read-write key bound to `B` MUST be allowed to reserve and commit only in scope `B`, and MUST get `403` reserving in any other scope. Any other request MUST respond `403` before any lookup.

#### Scenario: Bound key writes its branch
- **WHEN** a `ck_` read-write key bound to `feature/login` reserves a key with `scope` `feature/login`
- **THEN** the API responds `201`

#### Scenario: Bound key writes the default branch
- **WHEN** a `ck_` read-write key bound to `feature/login` reserves a key with `scope` `main`, and `main` is the project's default branch
- **THEN** the API responds `403` and reserves nothing

#### Scenario: Bound key writes an unrelated label
- **WHEN** a `ck_` read-write key bound to `pr-42` reserves a key with `scope` `pr-43`
- **THEN** the API responds `403` and reserves nothing

#### Scenario: Bound key reads another branch
- **WHEN** a `ck_` key bound to `feature/login` looks up a partial with `scope` `feature/other`
- **THEN** the API responds `403`

#### Scenario: Read key reserves
- **WHEN** a `ck_` read key reserves an entry
- **THEN** the API responds `403` and reserves nothing

### Requirement: Cache identifiers have fixed formats
`key`, `partial` and `sha256` MUST be exactly 64 lowercase hexadecimal characters. `scope` MUST be an opaque label of 1 to 256 UTF-8 bytes with no control characters, compared as an exact byte string. The server MUST NOT require it to be a valid Git branch or ref name. `name` MUST be non-blank, at most 64 bytes, with no control characters. A path `key` or `upload_id` in the wrong format MUST respond `404`. A query or body value in the wrong format MUST respond `422` on that field.

#### Scenario: Uppercase key in the path
- **WHEN** a client looks up a key containing an uppercase hex digit
- **THEN** the API responds `404`

#### Scenario: Short partial
- **WHEN** a client looks up a partial of 63 hex characters
- **THEN** the API responds `422` with an error on `partial`

#### Scenario: Scope that is not a Git ref
- **WHEN** a client reserves with `scope` `pr 42..head` (a string Git would reject as a branch name)
- **THEN** the API accepts the scope

#### Scenario: Scope over the cap
- **WHEN** a client reserves with a `scope` of 257 bytes
- **THEN** the API responds `422` with an error on `scope`

#### Scenario: Scope with a newline
- **WHEN** a client reserves with `scope` `"main\n"`
- **THEN** the API responds `422` with an error on `scope`

### Requirement: Lookups read the requested scope then the default-branch scope
An exact lookup `GET /api/v1/projects/:project/caches/entries/:key` and a partial lookup `GET /api/v1/projects/:project/caches/entries?partial=` SHALL take an optional `scope`. With `scope` `S`, a lookup MUST search `S` first and then the project's default-branch scope. Without `scope`, it MUST search only the default-branch scope. A lookup MUST NOT return an entry from any other scope. Only committed entries are returned. A lookup that finds nothing responds `404`.

#### Scenario: Exact hit in the requested scope
- **WHEN** key K is committed in `feature/login` and in `main`, and a client looks up K with `scope` `feature/login`
- **THEN** the API responds `200` with the `feature/login` entry and `scope` `feature/login`

#### Scenario: Exact hit falls back to the default branch
- **WHEN** key K is committed only in `main`, `main` is the default branch, and a client looks up K with `scope` `feature/login`
- **THEN** the API responds `200` with the `main` entry and `scope` `main`

#### Scenario: Another branch is never read
- **WHEN** key K is committed only in `feature/other` and a client looks up K with `scope` `feature/login`
- **THEN** the API responds `404`

#### Scenario: Reservation is not visible
- **WHEN** key K is reserved but not committed in `main` and a client looks it up with `scope` `main`
- **THEN** the API responds `404`

#### Scenario: Lookup without a scope
- **WHEN** key K is committed only in `feature/login` and a client looks up K without `scope`
- **THEN** the API responds `404`

### Requirement: Partial lookups return the newest entry of the first matching scope
A partial lookup MUST return the entry with the latest `committed_at` among committed entries with that `partial` in the first scope of the lookup order that has any, breaking ties by entry id. An entry in the default-branch scope MUST NOT be preferred over an entry in the requested scope because it is newer. `partial` is required.

#### Scenario: Newest of two in one scope
- **WHEN** two entries with partial P are committed in `main` at 10:00 and 11:00
- **THEN** a partial lookup for P with `scope` `main` returns the 11:00 entry

#### Scenario: Requested scope wins over a newer default entry
- **WHEN** partial P has an entry committed in `feature/login` at 10:00 and one in `main` at 11:00
- **THEN** a partial lookup for P with `scope` `feature/login` returns the `feature/login` entry

#### Scenario: Missing partial
- **WHEN** a client calls the partial lookup without `partial`
- **THEN** the API responds `422` with an error on `partial`

### Requirement: A hit returns metadata and a download URL
A successful lookup SHALL respond `200` with `key`, `partial`, `name`, `scope`, `size`, `sha256`, `created_at` (the commit time), `download_url` and `download_url_expires_at` under `data`. `download_url` MUST be a presigned GET for the entry's object that expires after the configured download TTL (default 900 seconds). A hit MUST update the entry's last-access time when the stored time is more than one hour old.

#### Scenario: Download the archive
- **WHEN** a client looks up a committed entry and GETs its `download_url` without an `Authorization` header
- **THEN** the object store returns the archive bytes whose SHA-256 equals the entry's `sha256`

#### Scenario: Hit renews retention
- **WHEN** an entry last accessed six days ago is restored
- **THEN** its last-access time becomes the time of the restore and the retention sweep keeps it

### Requirement: Reserving an upload holds the key in one scope
`POST /api/v1/projects/:project/caches/entries/:key` SHALL accept `name`, `partial`, `scope`, `size` and `sha256`, and respond `201` with `upload_id`, `upload_url`, `upload_headers`, `upload_url_expires_at` and `expires_at`. Keys are unique per project and scope: reserving MUST respond `409` when the key is committed or reserved and unexpired in that scope, and MUST replace an expired reservation there. Concurrent reservations of one key in one scope MUST yield one `201`.

#### Scenario: Reserve a new key
- **WHEN** a client reserves key K in `main` with a 50 MiB size and its SHA-256
- **THEN** the API responds `201` with an upload URL and headers that carry that size and checksum

#### Scenario: Key already committed
- **WHEN** key K is committed in `main` and a client reserves K in `main`
- **THEN** the API responds `409` and the committed entry is unchanged

#### Scenario: Same key in another scope
- **WHEN** key K is committed in `main` and a client reserves K in `feature/login`
- **THEN** the API responds `201`

#### Scenario: Expired reservation is replaced
- **WHEN** key K was reserved in `main` and that reservation expired without a commit, and a client reserves K in `main`
- **THEN** the API responds `201` with a new `upload_id`, and the old `upload_id` can no longer be committed

#### Scenario: Concurrent reservations
- **WHEN** two clients reserve key K in `main` at the same time
- **THEN** one responds `201` and the other `409`


### Requirement: Reservation bodies are strict JSON
A reservation body with a missing field, a field in the wrong format, or an unknown key MUST respond `422` and reserve nothing. A reservation whose content type is not `application/json` MUST respond `415`.

#### Scenario: Unknown body key
- **WHEN** a reservation body includes `project`
- **THEN** the API responds `422` and reserves nothing

#### Scenario: Form-encoded body
- **WHEN** a client reserves with `Content-Type: application/x-www-form-urlencoded`
- **THEN** the API responds `415` and reserves nothing

### Requirement: Upload headers are signed into the upload URL
`upload_headers` in a reservation response MUST contain `content-length` equal to `size`, `content-type` `application/gzip`, and `x-amz-checksum-sha256` equal to the base64 of the `sha256` digest. Those headers MUST be signed into `upload_url`, and the client MUST send them with its PUT and MUST NOT send an `Authorization` header.

#### Scenario: Headers carry the reservation
- **WHEN** a client reserves 52,428,800 bytes with a given `sha256`
- **THEN** `upload_headers` has `content-length` `52428800` and the base64 form of that digest, and `upload_url` lists both in its signed headers

### Requirement: Entries are limited to 5,000,000,000 bytes
`size` MUST be an integer from 1 through the configured entry cap (default 5,000,000,000 bytes). A larger `size` MUST respond `413`. A `size` of 0 or a non-integer MUST respond `422`. The entry cap MUST NOT be configurable above 5,363,466,240 bytes, the largest single-request upload R2 accepts, or above the project quota. The server MUST refuse to start with such a setting.

#### Scenario: Entry at the cap
- **WHEN** a client reserves an entry of exactly 5,000,000,000 bytes in a project with room for it
- **THEN** the API responds `201` with a single presigned upload URL

#### Scenario: Entry over the cap
- **WHEN** a client reserves an entry of 5,000,000,001 bytes
- **THEN** the API responds `413` and reserves nothing

#### Scenario: Cap configured above R2's limit
- **WHEN** the server starts with `CACHE_MAX_ENTRY_BYTES` set to 5,363,466,241
- **THEN** it refuses to boot

### Requirement: The object store enforces the reserved size and checksum
Each reservation MUST get its own object, named by the server and never by the client. An upload to `upload_url` whose body length or SHA-256 differs from the reservation MUST be rejected by the object store, and an upload without `upload_headers` MUST fail signature verification. `upload_url` MUST expire after the configured upload TTL (default 900 seconds), and the reservation after the configured reservation TTL (default 7,200 seconds).

#### Scenario: Body differs from the reservation
- **WHEN** a client PUTs a body whose SHA-256 differs from the reserved `sha256`
- **THEN** the object store rejects the PUT and a later commit responds `422`

#### Scenario: Late upload after a new reservation
- **WHEN** a reservation expires, another client reserves the same key and commits, and the first client then PUTs to its old URL
- **THEN** the committed entry's bytes are unchanged

### Requirement: Commit verifies the stored object
`POST /api/v1/projects/:project/caches/uploads/:upload_id/commit` SHALL make a reservation visible. It MUST respond `404` when the upload does not exist in that project, has expired, or was reserved by a different API key. On success it MUST respond `200` with the same body as a lookup hit. Committing an upload that this key already committed MUST respond `200` again.

#### Scenario: Commit after upload
- **WHEN** a client reserves, PUTs the exact archive, and commits
- **THEN** the API responds `200` and a lookup of the key in that scope responds `200`

#### Scenario: Commit without upload
- **WHEN** a client commits a reservation whose object was never uploaded
- **THEN** the API responds `422` on `upload`, the reservation is deleted, and the key can be reserved again

#### Scenario: Commit by another key
- **WHEN** a key that did not reserve an upload commits it
- **THEN** the API responds `404` and the reservation is unchanged

#### Scenario: Retried commit
- **WHEN** a client commits the same upload twice
- **THEN** both respond `200` with the same entry

#### Scenario: Commit after expiry
- **WHEN** a client commits a reservation after its `expires_at`
- **THEN** the API responds `404`

### Requirement: Commit checks the object's size and checksum
Before committing, the server MUST confirm that the object exists, its length equals `size`, and the SHA-256 the object store recorded for it equals `sha256`. When any check fails, or the store reports no SHA-256, the server MUST respond `422` on `upload` and delete the reservation, which queues the object for deletion.

#### Scenario: Store reports a different length
- **WHEN** the stored object's length differs from the reserved `size`
- **THEN** commit responds `422` on `upload` and the reservation is deleted

#### Scenario: Store reports no checksum
- **WHEN** the object store returns the object without a SHA-256
- **THEN** commit responds `422` on `upload` and nothing is committed

### Requirement: Entries are immutable
A committed entry's metadata and object MUST NOT change. No route updates an entry. A purge removes it, after which the key may be reserved again in that scope.

#### Scenario: Re-upload after purge
- **WHEN** an entry is purged and a client reserves and commits the same key and scope with a different archive
- **THEN** later lookups return the new archive's `sha256`

### Requirement: Projects have a storage quota
A project's committed entries and unexpired reservations MUST together stay within the configured byte quota (default 50 GiB) and entry cap (default 10,000). When a reservation would exceed either, the server MUST evict committed entries, from every scope, least recently accessed first, until it fits. When it still does not fit, the API MUST respond `507` and evict nothing. Reservations of one project MUST be serialized so concurrent reservations can't exceed the quota together.

#### Scenario: Reservation evicts the least recently used entry
- **WHEN** a project at its byte quota has entries A (accessed yesterday) and B (accessed today), and a client reserves an entry the size of A
- **THEN** the API responds `201`, A is deleted, and B remains

#### Scenario: Superseded rolling entries go first
- **WHEN** a full project has rolling-cache entry R1, committed yesterday and superseded by a newer R2 with the same partial, and an entry C committed last week and restored an hour ago
- **THEN** a reservation that needs room for one entry evicts R1, and C remains

#### Scenario: Quota held by reservations
- **WHEN** unexpired reservations fill a project's quota and a client reserves another entry
- **THEN** the API responds `507` and no committed entry is deleted

#### Scenario: Entry cap
- **WHEN** a project has 10,000 committed entries and a client reserves a new one
- **THEN** the least recently accessed entry is deleted and the API responds `201`

### Requirement: Unused entries and expired reservations are removed
A periodic sweep MUST delete reservations past their `expires_at` and committed entries not accessed within the configured retention (default 7 days). Deleting an entry or reservation by any means, including project and account deletion, MUST queue its object for deletion from object storage, and the sweep MUST delete queued objects, retrying failures on later sweeps.

#### Scenario: Stale entry
- **WHEN** an entry has not been accessed for 8 days and the sweep runs
- **THEN** the entry is deleted and its object is removed from the bucket

#### Scenario: Object store unavailable
- **WHEN** the sweep cannot delete a queued object
- **THEN** the object stays queued and a later sweep deletes it

### Requirement: Private keys list entries and usage
`GET /api/v1/projects/:project/caches` SHALL require an `sk_` key and return committed entries newest first, filtered by optional exact `name` and `scope`, keyset-paged with `limit` (1 to 200, default 50) and `cursor`, without download URLs. The response MUST include `usage` with `bytes` and `entries` (committed entries and unexpired reservations), `quota_bytes`, and `max_entries`.

#### Scenario: List by name
- **WHEN** a client lists caches with `name` `deps`
- **THEN** the API responds `200` with only entries named `deps` and the project's usage

### Requirement: Private keys purge entries
`DELETE /api/v1/projects/:project/caches/entries/:key?scope=` SHALL delete the entry or reservation for that key in that scope, and `scope` is required. `DELETE /api/v1/projects/:project/caches/entries` SHALL delete every entry and reservation matching all of the given `name`, `scope` and `partial` filters and MUST respond `422` when none is given. Both MUST require an `sk_` key and respond `200` with the number deleted, including `0`. A purged entry MUST be absent from the next lookup.

#### Scenario: Purge a poisoned cache
- **WHEN** a client deletes with `name` `deps` and `scope` `main`
- **THEN** the API responds `200` with the count deleted, and a partial lookup for those entries with `scope` `main` responds `404`

#### Scenario: Purge without filters
- **WHEN** a client calls `DELETE /api/v1/projects/:project/caches/entries` with no query
- **THEN** the API responds `422` and deletes nothing

#### Scenario: Purge a missing key
- **WHEN** a client purges a key that has no entry in that scope
- **THEN** the API responds `200` with `deleted` `0`

### Requirement: Caches need configured object storage
When no cache bucket is configured, every route under `/api/v1/projects/:project/caches` MUST respond `503` after authentication and project resolution, and the cache-key routes MUST keep working.

#### Scenario: Bucket not configured
- **WHEN** the server has no cache bucket and a client with an `sk_` key looks up an entry
- **THEN** the API responds `503`

### Requirement: Presigned URLs are not logged
No log line, error response or error report MUST contain a presigned URL or its signature.

#### Scenario: Lookup at debug level
- **WHEN** a lookup returns a download URL while Logger is at `:debug`
- **THEN** the captured logs do not contain the URL's signature
