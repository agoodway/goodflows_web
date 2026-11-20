# cache-storage Specification

## Purpose

Stores goodflows job cache archives for a project as immutable, branch-scoped entries in S3-compatible object storage. Clients reserve, upload and commit entries through presigned URLs and restore them by exact key or by partial key. Cache keys give remote runners access to one project's caches and nothing else.

## Requirements

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
`POST /api/v1/projects/:project/cache-keys` SHALL require an `sk_` key and SHALL accept `access` (`read` or `read_write`, required), `scope` (optional, the scope rule), `ttl_seconds` (optional), and `name` (optional, at most 100 characters). It MUST respond `201` with the key's `id`, `token`, `access`, `scope` and `expires_at`. The token starts with `ck_` and MUST appear in no later response. A mint for a project at its cap of active keys (default 1,000) MUST get `422` and create no key.

#### Scenario: Mint a bound read-write key
- **WHEN** a client with an `sk_` key mints `{"access": "read_write", "scope": "feature/login", "ttl_seconds": 3600}`
- **THEN** the API responds `201` with a `ck_` token whose `expires_at` is one hour later, bound to that project and scope

#### Scenario: Public key mints
- **WHEN** a client with a `pk_` key mints a cache key
- **THEN** the API responds `403` and creates no key

#### Scenario: Read key with a scope
- **WHEN** a client mints `{"access": "read", "scope": "feature/login"}`
- **THEN** the API responds `201` and the key may read only `feature/login` and the default-branch scope

#### Scenario: Project at the key cap
- **WHEN** a project has 1,000 cache keys that are neither revoked nor expired and a client with an `sk_` key mints another
- **THEN** the API responds `422` and creates no key

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
An `sk_` key and an unbound `ck_` key SHALL read any scope. An unbound `ck_` read-write key and an `sk_` key SHALL write any scope. A `ck_` key bound to scope `B` MUST be allowed to read only with `scope` `B`, with `scope` equal to the project's default branch, or with no `scope`. A `ck_` read-write key bound to `B` MUST be allowed to reserve and commit only in scope `B`, and MUST get `403` reserving in any other scope. Any other request MUST respond `403` before any lookup or input validation.

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

#### Scenario: Read key commits
- **WHEN** a `ck_` read key commits any `upload_id`
- **THEN** the API responds `403` and commits nothing

#### Scenario: Refused key sends invalid input
- **WHEN** a `ck_` read key reserves with a body that has an unknown key, a malformed `scope` or a non-JSON Content-Type, or a `ck_` key bound to `feature/login` looks up a malformed `partial` with `scope` `feature/other`
- **THEN** the API responds `403`, not `415` or `422`, because the access check runs before the path, Content-Type, query or body is validated

### Requirement: Cache identifiers have fixed formats
`key`, `partial` and `sha256` MUST be exactly 64 lowercase hexadecimal characters. `scope` MUST be an opaque label of 1 to 256 UTF-8 bytes with no control characters, compared as an exact byte string. The server MUST NOT require it to be a valid Git branch or ref name. `name` MUST be non-blank, at most 64 bytes, with no control characters. A path `key` or `upload_id` in the wrong format MUST respond `404`. A query or body value in the wrong format MUST respond `422` on that field.

#### Scenario: Uppercase key in the path
- **WHEN** a client looks up a key containing an uppercase hex digit
- **THEN** the API responds `404`

#### Scenario: Malformed path from a refused key
- **WHEN** a `ck_` read key reserves a path key containing an uppercase hex digit, or commits an `upload_id` that is not a UUID
- **THEN** the API responds `403`, not `404`: a key refused by its access check gets `403` before the path is validated

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
`POST /api/v1/projects/:project/caches/entries/:key` SHALL accept `name`, `partial`, `scope`, `size`, `sha256` and an optional `parts`, and respond `201` with `upload_id`, the upload or part URLs, `upload_url_expires_at` and `expires_at`. Keys are unique per project and scope: reserving MUST respond `409` when the key is committed or reserved and unexpired in that scope, and MUST replace an expired reservation there. Concurrent reservations of one key in one scope MUST yield one `201`.

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

#### Scenario: Multipart reservation of a taken key
- **WHEN** key K is committed in `main` and a client reserves K in `main` with `parts`
- **THEN** the API responds `409`, and any multipart upload the attempt started is aborted no later than the next sweep

### Requirement: Reservation bodies are strict JSON
A reservation body with a missing field, a field in the wrong format, or an unknown key MUST respond `422` and reserve nothing. A reservation whose content type is not `application/json`, compared case-insensitively and ignoring parameters such as `charset`, MUST respond `415`.

#### Scenario: Unknown body key
- **WHEN** a reservation body includes `project`
- **THEN** the API responds `422` and reserves nothing

#### Scenario: Form-encoded body
- **WHEN** a client reserves with `Content-Type: application/x-www-form-urlencoded`
- **THEN** the API responds `415` and reserves nothing

#### Scenario: JSON with a charset
- **WHEN** a client reserves with `Content-Type: application/json; charset=utf-8` and a valid body
- **THEN** the API responds `201`

### Requirement: Upload headers are signed into the upload URL
In a reservation without `parts`, `upload_headers` MUST contain `content-length` equal to `size`, `content-type` `application/gzip`, and `x-amz-checksum-sha256` equal to the base64 of the `sha256` digest. Those headers MUST be signed into `upload_url`, and the client MUST send them with its PUT and MUST NOT send an `Authorization` header.

#### Scenario: Headers carry the reservation
- **WHEN** a client reserves 52,428,800 bytes with a given `sha256`
- **THEN** `upload_headers` has `content-length` `52428800` and the base64 form of that digest, and `upload_url` lists both in its signed headers

#### Scenario: Multipart reservation has no single upload URL
- **WHEN** a client reserves with `parts`
- **THEN** the response has neither `upload_url` nor `upload_headers`

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
`POST /api/v1/projects/:project/caches/uploads/:upload_id/commit` SHALL make a reservation visible. It MUST respond `404` when the upload does not exist in that project, has expired, or was reserved by a different API key. On success it MUST respond `200` with the same body as a lookup hit. Committing an upload that this key already committed MUST respond `200` again. When the object store cannot be reached, commit MUST respond `503` with `retry-after` and keep the reservation.

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

#### Scenario: Object store unreachable at commit
- **WHEN** a client commits an uploaded reservation while the object store cannot answer
- **THEN** the API responds `503` with `retry-after: 1`, and the reservation stays and can be committed later

### Requirement: Commit checks the object's size and checksum
Before committing a reservation without `parts`, the server MUST confirm that the object exists, its length equals `size`, and the SHA-256 the object store recorded for it equals `sha256`. When any check fails, or the store reports no SHA-256, the server MUST respond `422` on `upload` and delete the reservation, which queues the object for deletion.

#### Scenario: Store reports a different length
- **WHEN** the stored object's length differs from the reserved `size`
- **THEN** commit responds `422` on `upload` and the reservation is deleted

#### Scenario: Store reports no checksum
- **WHEN** the object store returns the object without a SHA-256
- **THEN** commit responds `422` on `upload` and nothing is committed

#### Scenario: Multipart object without a SHA-256
- **WHEN** a reservation with `parts` is committed and the store reports no SHA-256 for the completed object
- **THEN** commit does not require one and checks the part and object ETags instead

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
A periodic sweep MUST delete reservations past their `expires_at` and committed entries not accessed within the configured retention (default 7 days). Deleting an entry or reservation by any means, including project and account deletion, MUST queue its object for deletion from object storage, and the sweep MUST delete queued objects, retrying failures on later sweeps. A queued object of a reservation without `parts` MUST NOT be deleted before its upload URL has expired.

#### Scenario: Stale entry
- **WHEN** an entry has not been accessed for 8 days and the sweep runs
- **THEN** the entry is deleted and its object is removed from the bucket

#### Scenario: Object store unavailable
- **WHEN** the sweep cannot delete a queued object
- **THEN** the object stays queued and a later sweep deletes it

#### Scenario: Rejected upload while its URL is valid
- **WHEN** a commit rejects an upload, or a reservation is purged, before its upload URL expires
- **THEN** sweeps keep the object until the URL has expired, and the next sweep after that deletes it

#### Scenario: Purged multipart reservation
- **WHEN** a reservation with `parts` is purged while its part URLs are still valid
- **THEN** the next sweep aborts its multipart upload without waiting for the part URLs to expire

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
When no cache bucket is configured, every route under `/api/v1/projects/:project/caches` MUST respond `503` after authentication and project resolution, and the cache-key routes MUST keep working. The server MUST refuse to start when a bucket is set without both credentials, or when the upload URL TTL is above the reservation TTL.

#### Scenario: Bucket not configured
- **WHEN** the server has no cache bucket and a client with an `sk_` key looks up an entry
- **THEN** the API responds `503`

#### Scenario: Bucket without credentials
- **WHEN** the server starts with `CACHE_S3_BUCKET` set and `CACHE_S3_SECRET_ACCESS_KEY` blank
- **THEN** it refuses to boot

#### Scenario: Upload URL outlives the reservation
- **WHEN** the server starts with `CACHE_UPLOAD_URL_TTL_SECONDS` above `CACHE_RESERVATION_TTL_SECONDS`
- **THEN** it refuses to boot

### Requirement: Presigned URLs are not logged
No log line, error response or error report MUST contain a presigned URL or its signature.

#### Scenario: Lookup at debug level
- **WHEN** a lookup returns a download URL while Logger is at `:debug`
- **THEN** the captured logs do not contain the URL's signature

### Requirement: Reservations may declare upload parts
A reservation body MAY include `parts`, an object with exactly `size` (an integer from 5,242,880 through 5,368,709,120) and `md5` (a list of strings, each the padded standard base64 of 16 bytes). The list length MUST equal `ceil(size / parts.size)` for the reservation's `size` and MUST be at most 10,000. Any other `parts` MUST respond `422` on `parts` and reserve nothing. `"parts": null` is the same as no `parts`. `sha256` stays required.

#### Scenario: Valid parts
- **WHEN** a client reserves 52,428,800 bytes with `parts` `{"size": 16777216, "md5": [m1, m2, m3, m4]}`
- **THEN** the API responds `201`

#### Scenario: Part count does not match
- **WHEN** a client reserves 52,428,800 bytes with `parts.size` 16,777,216 and three `md5` values
- **THEN** the API responds `422` with an error on `parts` and reserves nothing

#### Scenario: Part size below the minimum
- **WHEN** a client reserves with `parts.size` 5,242,879
- **THEN** the API responds `422` with an error on `parts`

#### Scenario: MD5 of the wrong length
- **WHEN** a client reserves with an `md5` value that decodes to 20 bytes, or that is not base64
- **THEN** the API responds `422` with an error on `parts`

#### Scenario: Unknown key inside parts
- **WHEN** a client reserves with `parts` `{"size": 16777216, "md5": [...], "etags": [...]}`
- **THEN** the API responds `422` with an error on `parts`

#### Scenario: Parts without sha256
- **WHEN** a client reserves with valid `parts` and no `sha256`
- **THEN** the API responds `422` with an error on `sha256`

#### Scenario: Quota counts the declared size
- **WHEN** a project has 10 bytes of quota left and a client reserves 20 bytes with `parts`
- **THEN** the server evicts or refuses exactly as for a reservation of 20 bytes without `parts`

### Requirement: Multipart reservations return presigned part URLs
A reservation with `parts` SHALL respond `201` with `upload_id`, `upload_parts`, `upload_url_expires_at` and `expires_at`, and without `upload_url` or `upload_headers`. `upload_parts` MUST list `{number, url, headers}` for parts 1 through the part count in order, where `headers` is exactly `content-length` (the part's length) and `content-md5` (its declared MD5). Every part URL MUST expire at `upload_url_expires_at`, no earlier than the reservation TTL after reserving.

#### Scenario: Part URLs of a three-part reservation
- **WHEN** a client reserves 40,000,000 bytes with `parts.size` 16,777,216 and three MD5s
- **THEN** `upload_parts` has numbers 1, 2 and 3 with `content-length` `16777216`, `16777216` and `6445568`, each with its declared `content-md5`

#### Scenario: Part URLs outlive the single PUT TTL
- **WHEN** a multipart reservation is made with the default settings
- **THEN** `upload_url_expires_at` is about 7,200 seconds later, not 900

#### Scenario: Reservation without parts
- **WHEN** a client reserves without `parts`
- **THEN** the response has `upload_url` and `upload_headers` and no `upload_parts`

### Requirement: The object store enforces each part's length and MD5
Each part URL MUST be signed with its `headers`, so the object store rejects a part PUT whose body length or MD5 differs from them, and a part PUT without those headers fails signature verification. The client MUST NOT send `Authorization` to a part URL. A part PUT MUST NOT create an object: only the server completing the upload does.

#### Scenario: Part body differs from its MD5
- **WHEN** a client PUTs part 2 with a body whose MD5 differs from the declared one
- **THEN** the object store rejects the PUT

#### Scenario: Part PUT without the signed headers
- **WHEN** a client PUTs part 1 without `content-md5`
- **THEN** the object store rejects the PUT with a signature error

#### Scenario: Parts uploaded but not committed
- **WHEN** a client PUTs every part and never commits
- **THEN** no object exists for the reservation and lookups respond `404`

### Requirement: Commit verifies a multipart upload from the store's part list
Committing a reservation with `parts` MUST read the uploaded parts from the object store, ignoring any client value, and require every part number with an ETag equal to the hex of its declared MD5. The server MUST then complete the upload and confirm that the object's length equals `size` and its ETag equals the hex MD5 of the declared part MD5 bytes concatenated, then `-` and the part count. On success commit responds as for any upload.

#### Scenario: Commit after all parts
- **WHEN** a client PUTs every part with its URL and headers and commits
- **THEN** the API responds `200` with the entry, and the download URL returns the concatenated parts

#### Scenario: Retried commit after the upload completed
- **WHEN** commit completes the upload and the store then fails, so commit responds `503`, and the client commits again
- **THEN** the second commit responds `200` with the entry

#### Scenario: Object store unreachable at a multipart commit
- **WHEN** the object store cannot answer while a multipart reservation is committed
- **THEN** the API responds `503` with `retry-after: 1`, and the reservation stays and can be committed later

#### Scenario: Upload gone but no object yet
- **WHEN** the store reports the multipart upload no longer exists and the object does not exist yet, as while another commit is still completing it
- **THEN** the API responds `503` with `retry-after: 1` and the reservation stays

### Requirement: A failed multipart commit aborts the upload
When a part is missing, a part's ETag or the object's ETag or length differs, or the store refuses to complete the upload, commit MUST respond `422` on `upload`, delete the reservation, and abort the multipart upload, so a later part PUT fails.

#### Scenario: Missing part
- **WHEN** a client PUTs parts 1 and 3 of three and commits
- **THEN** the API responds `422` on `upload`, the key can be reserved again, and a later PUT of part 2 is rejected

#### Scenario: Object ETag differs
- **WHEN** the completed object's ETag is not the one computed from the declared MD5s
- **THEN** the API responds `422` on `upload` and nothing is committed

### Requirement: Multipart entries store the declared SHA-256
An entry committed from a reservation with `parts` MUST keep the `sha256` the client declared, and lookups MUST return it. The object store does not verify it. Restoring clients MUST check the archive's size and `sha256` before extracting it.

#### Scenario: Lookup of a multipart entry
- **WHEN** a client looks up an entry that was committed through parts
- **THEN** the response's `sha256` is the value sent at reserve

### Requirement: Deleting a multipart reservation aborts its upload
When a reservation with `parts` is deleted by any means, including expiry, purge, eviction, a rejected commit, and project or account deletion, the server MUST abort its multipart upload, retrying on later sweeps until the store confirms or reports the upload gone.

#### Scenario: Expired multipart reservation
- **WHEN** a multipart reservation expires with some parts uploaded and the sweep runs
- **THEN** the multipart upload is aborted and no object exists

#### Scenario: Store unavailable while aborting
- **WHEN** the sweep cannot abort a deleted reservation's multipart upload
- **THEN** a later sweep aborts it

### Requirement: Multipart reserve needs the object store
A reservation with `parts` MUST start its multipart upload before it responds. When the object store cannot be reached, it MUST respond `503` with `retry-after` and reserve nothing.

#### Scenario: Store down at a multipart reserve
- **WHEN** a client reserves with `parts` while the object store cannot answer
- **THEN** the API responds `503` with `retry-after: 1`, and the key can be reserved once the store is back

### Requirement: Reservations fit a presigned URL's lifetime
The server MUST refuse to start when the reservation TTL is above 604,800 seconds, the longest lifetime of a SigV4 presigned URL, since part URLs expire with the reservation.

#### Scenario: Reservation TTL above a week
- **WHEN** the server starts with `CACHE_RESERVATION_TTL_SECONDS` set to 604,801
- **THEN** it refuses to boot
