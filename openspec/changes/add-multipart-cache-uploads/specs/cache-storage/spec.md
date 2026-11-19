# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

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

### Requirement: Upload headers are signed into the upload URL
In a reservation without `parts`, `upload_headers` MUST contain `content-length` equal to `size`, `content-type` `application/gzip`, and `x-amz-checksum-sha256` equal to the base64 of the `sha256` digest. Those headers MUST be signed into `upload_url`, and the client MUST send them with its PUT and MUST NOT send an `Authorization` header.

#### Scenario: Headers carry the reservation
- **WHEN** a client reserves 52,428,800 bytes with a given `sha256`
- **THEN** `upload_headers` has `content-length` `52428800` and the base64 form of that digest, and `upload_url` lists both in its signed headers

#### Scenario: Multipart reservation has no single upload URL
- **WHEN** a client reserves with `parts`
- **THEN** the response has neither `upload_url` nor `upload_headers`

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
