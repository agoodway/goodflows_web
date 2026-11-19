# Design

## Context

See proposal.md (Why) and specs/cache-storage/spec.md for the contract. This change extends the remote cache from `add-remote-cache-storage` (archived 2026-11-19; its design is cited below as D1 to D10).

What exists today:
- `GoodFlows.Caches.reserve/5` validates the body, presigns one PUT with `ObjectStore.presign_put/2` (local signing, no network), then inserts the `cache_entries` row in a transaction that locks the project row, replaces an expired reservation in the slot, returns `409`, evicts, or returns `507` (D3, D6).
- `Caches.commit/3` HEADs the object with checksum mode and requires the size and `x-amz-checksum-sha256` to match (D3). A failed check deletes the row. A store error is `503` with `retry-after: 1`.
- An `AFTER DELETE` trigger on `cache_entries` queues `object_key` in `cache_object_deletions` with `delete_after = GREATEST(now, upload_expires_at)`. `Caches.Sweep` step 4 deletes queued objects once `delete_after` is more than 60 s past (D2, D7).
- `ObjectStore` has `presign_put/2`, `presign_get/2`, `head/1` and `delete/1`. `ObjectStore.S3` uses `ReqS3.presign_url/1` and `Req` with `aws_sigv4`. The test `ObjectStore.Fake` (`app/test/support/object_store_fake.ex`) records signed headers and enforces them in `put/3`.
- Dependencies: `req` 0.7.5, `req_s3` 0.2.5 (`app/mix.lock`).

### Evidence from the R2 test bucket

Measured and checked against live Cloudflare R2 before this change was written:

| Check | Result |
|---|---|
| 1 GB as one presigned PUT | 59.0 s, 17 MB/s |
| 1 GB as 8 parallel 16 MiB multipart parts | 19.6 s, 51 MB/s |
| UploadPart URL presigned with `x-amz-checksum-sha256`, correct body | `501 NotImplemented` |
| HEAD with checksum mode of a completed multipart object | no SHA-256; R2 supports full-object checksums only for CRC64NVME |
| UploadPart URL presigned with `Content-MD5` and `Content-Length`: right body / wrong body / header missing | `200` / `400 BadDigest` / `403 SignatureDoesNotMatch` |
| Limits | parts 5 MiB to 5 GiB, all but the last the same size, at most 10,000 parts; incomplete uploads auto-abort after 7 days |
| Multipart ETag | hex MD5 of the concatenated binary part MD5s, then `-N` |

So on R2 neither a per-part nor a full-object SHA-256 can be enforced for multipart uploads, while a signed `Content-MD5` per part can.

### What `req` and `req_s3` support (read from the locked sources)

- `ReqS3.presign_url/1` forwards every option it does not drop to `Req.Utils.aws_sigv4_url/1`, which accepts `:headers` (signed, lower-cased and trimmed) and `:query` (extra query parameters, encoded and sorted into the canonical query before signing). The URL itself must have no query (`true = url.query in [nil, ""]`). So a part URL is `ReqS3.presign_url(url: object_url, method: :put, expires: ttl, headers: [{"content-length", …}, {"content-md5", …}], query: [{"partNumber", n}, {"uploadId", id}])`. Signed `content-md5` works the same way `x-amz-checksum-sha256` does today.
- `Req`'s `put_aws_sigv4` step signs any method and keeps the URL's query: `aws_sigv4_headers/1` builds the canonical query by splitting the already-encoded query on `&` and `=` and sorting, and hashes a binary body into `x-amz-content-sha256`. So CreateMultipartUpload (`POST ?uploads`, which canonicalizes as `uploads=`), ListParts (`GET ?uploadId=&part-number-marker=`), CompleteMultipartUpload (`POST ?uploadId=` with an XML body) and AbortMultipartUpload (`DELETE ?uploadId=`) can all go through the existing `request/3` helper. The query must be built already encoded with `URI.encode(&URI.char_unreserved?/1)`, because the signer does not re-encode it; upload ids can contain `+`, `/` or `=`.
- `req_s3` has no multipart helpers, and its XML parser `ReqS3.XML` is `@moduledoc false`, so the app must not call it.

Fallbacks, should any of this not hold when tested (task 2.2): call `Req.Utils.aws_sigv4_url/1` directly (public, and what `presign_url/1` calls) for part URLs, and `Req.Utils.aws_sigv4_headers/1` for the store requests. Neither needs a new dependency. Only if both fail would `ex_aws_s3` be considered, and that would be raised before implementing.

## Goals / Non-Goals

**Goals:**
- Parallel part uploads whose length and MD5 the store enforces per part, with the server, not the client, deciding which parts make up the object.
- No new way to leave an untracked object in the bucket.
- Single-PUT reservations unchanged on the wire and in storage.

**Non-Goals:**
- SHA-256 verification of multipart objects by the store (impossible on R2, see Evidence). CRC64NVME full-object checksums are possible on R2 but would add a second digest to the contract for little gain over per-part MD5 plus client-side SHA-256 checks on restore.
- Resuming an upload across reservations, or adding parts after reserve.
- Raising the 5,000,000,000-byte entry cap. At that cap and the 5 MiB minimum part size a reservation has at most 954 parts, so the 10,000-part limit only matters if the cap is raised later.
- Multipart downloads (ranged GETs on the existing `download_url` already work).

## Decisions

### M1. The wire contract is fixed by the CLI companion

The request and response shapes are those in the proposal and the spec delta, shared with the goodflows companion change. Details the contract left open were settled as follows:
- `parts` must be an object with exactly the keys `size` and `md5`; an unknown key inside it is `422` on `parts`, matching the strict reservation body (D3). `"parts": null` is the same as no `parts`.
- `parts.size` must be a JSON integer (as `size` already must be). Each `md5` entry must be padded standard base64 (RFC 4648 section 4, 24 characters) decoding to 16 bytes, because that is the form `Content-MD5` takes (RFC 1864) and the server sends it back verbatim in the part's `headers`.
- Part `n` (1-based) has length `parts.size` except the last, which is `size - (count - 1) * parts.size`. A reservation smaller than `parts.size` is one part, which S3 and R2 allow at any size.
- All `parts` errors are reported on `parts`, with a message naming the rule (`part size must be from 5242880 through 5368709120`, `md5 must have N entries`, `md5 entries must be base64 of 16 bytes`, `must have at most 10000 parts`).
- `upload_url_expires_at` is the expiry of every part URL. The response omits `upload_url` and `upload_headers` rather than sending them as `null`.

### M2. The entry records the multipart upload

Migration `add_multipart_to_cache_entries` adds to `cache_entries`:

| Column | Type | Notes |
|---|---|---|
| `multipart_upload_id` | text null | the store's `UploadId` |
| `part_size` | bigint null | `parts.size` |
| `part_md5s` | text[] null | the declared base64 MD5s in part order |

A check constraint requires all three to be null or all non-null. `Entry.multipart?/1` is true when `multipart_upload_id` is set. The columns stay after commit: they are small and explain the entry's ETag. `cache_object_deletions` gains `multipart_upload_id text null`.

The trigger function is replaced (`CREATE OR REPLACE FUNCTION`) to copy `OLD.multipart_upload_id` and to set `delete_after` to now for a multipart row and, as today, to `GREATEST(now, upload_expires_at)` otherwise (M4).

### M3. Reserve creates the upload before the transaction

`Caches.reserve/5` keeps its order (precheck, path key, body validation including `parts`, scope access, `413`) and then, for a body with `parts`:
1. Generates the `upload_id` and object key as today and calls `ObjectStore.create_multipart/1` (CreateMultipartUpload, `content-type: application/gzip`). A store error is `{:error, :object_store_unavailable}`, which the fallback already renders as `503` with `retry-after: 1`. Nothing is written.
2. Presigns every part URL with `ObjectStore.presign_part/4`, valid for `:cache_reservation_ttl_seconds`, and takes `upload_expires_at` after signing, as D1 does for the single PUT.
3. Runs the same transaction as today, inserting the three M2 columns.
4. When the transaction returns an error (`409`, `507`, a lost race), inserts a `cache_object_deletions` row for the object key and upload id with `delete_after` now, outside the rolled-back transaction, then calls `abort_multipart/2` once, ignoring the result. The queue row makes the abort durable: if the immediate abort fails, the sweep retries it. When the transaction raises or exits instead (for example on a lost database connection), the upload is aborted and queued on a best-effort basis before the error propagates.

Creating the upload inside the transaction would hold the project lock across a network call, which D6 avoids for presigning too. Checking the slot before creating saves an upload in the rare `409` case, but cannot replace the locked check, so it is not added; the CLI reserves only after its lookup missed (D3).

Quota and the entry cap use the declared `size` exactly as today. Parts that the client never uploads cost nothing on the store and are freed by the abort.

### M4. Part URLs live as long as the reservation, and deletion aborts immediately

A part PUT never creates an object. Only CompleteMultipartUpload does, and only the server calls it. After AbortMultipartUpload, a part PUT fails with `NoSuchUpload`. So the reason D1 and D2 give for a short upload URL and a delayed object delete, a late PUT recreating an object the app no longer tracks, does not apply to parts:
- Part URLs are signed for `:cache_reservation_ttl_seconds` (default 7,200), not `:cache_upload_url_ttl_seconds` (900). A runner whose later parts start after 15 minutes still succeeds, as long as it commits before `expires_at`. Because the URLs are signed before the row is inserted, every part URL expires slightly before the reservation, so no part PUT can start after the reservation expired.
- For a deleted multipart row the trigger sets `delete_after` to now. The sweep's 60-second margin (D7) still applies, then it aborts the upload and deletes the object key. It does not wait for the part URLs to expire: once aborted, those URLs can only fail. Waiting up to two hours would only keep uploaded parts billed for longer.
- SigV4 presigned URLs last at most 604,800 seconds, so `config/runtime.exs` refuses to boot with `CACHE_RESERVATION_TTL_SECONDS` above that (spec). The existing check that the upload URL TTL is at most the reservation TTL stays for single PUTs.

The no-orphan guarantee then rests on ordering, not on time:
- The sweep aborts before it deletes. A commit that calls CompleteMultipartUpload after the abort gets `NoSuchUpload` and creates nothing.
- A commit that completed before the abort has created the object. The abort then reports `NoSuchUpload`, which counts as done, and the delete that follows removes the object.
- A commit only marks a row committed with `WHERE state = 'reserved' AND expires_at > now`, as today. If the row was deleted meanwhile the commit responds `404`, and the object is already queued.

### M5. Aborting goes through the deletion queue, not a new sweep step

Every way a row disappears (expiry in sweep step 1, retention, eviction, purge, a rejected commit, a replaced expired reservation, project and account cascades) already fires the trigger, so routing aborts through `cache_object_deletions` covers them all, including cascades that never touch Elixir code. A separate sweep step that scanned expired multipart reservations would miss purges, evictions and cascades.

Sweep step 4 handles a queue row with a `multipart_upload_id` as: `abort_multipart/2` (`:ok` or `{:error, :not_found}` both count), then `delete/1` as today (an upload that was completed and then purged has an object), then delete the queue row. Any other error leaves the row for the next sweep. Each such row costs two store requests within the same 200-second budget.

Rejected commits also call `abort_multipart/2` directly after deleting the row (M6), so the spec's "a later part PUT fails" holds immediately rather than after the next sweep.

### M6. Commit of a multipart reservation

After loading the reservation as today (`404` rules and the idempotent `200` for a committed row are unchanged):
1. `ObjectStore.list_parts/2`, following `NextPartNumberMarker` until `IsTruncated` is false (1,000 parts per page). A marker that does not grow, or is 10,000 or more (part numbers end at 10,000), is a malformed response (`503`), so paging cannot run unbounded. The client's ETags are never used; commit has no body.
   - `{:ok, parts}`: the part numbers must be exactly 1 through the count, each ETag (quotes stripped, lower-cased) must equal the hex of the declared MD5, and each `Size` must equal the part's length. Otherwise reject.
   - `{:error, :not_found}` (`NoSuchUpload`): an earlier commit attempt already completed the upload, or it was aborted. Skip to step 3, which decides.
   - Any other error: `503`, reservation kept.
2. `ObjectStore.complete_multipart/3` with the listed part numbers and ETags. `:ok` and `{:error, :not_found}` go on to step 3. A refusal from the store (an S3 error code such as `InvalidPart` or `EntityTooSmall`, including one returned in a `200` body, which S3 does for CompleteMultipartUpload) rejects. A transport error, a `5xx`, or a retryable S3 error code (`InternalError`, `SlowDown`, `ServiceUnavailable`, `RequestTimeout`, in a `200` or a `400` body) is `503`.
3. `ObjectStore.head/1`. The object must exist, its length must equal `size`, and its ETag must equal `hex(MD5(md5_1 <> … <> md5_N)) <> "-" <> N` computed from the declared MD5 bytes. A missing object, wrong size or wrong ETag rejects with `is missing`, `has the wrong size` or `has the wrong checksum`, except that a missing object after step 1 or 2 reported `NoSuchUpload` is `503` with the reservation kept: nothing in the app aborts the upload of a live, unexpired reservation, so that state means another commit's CompleteMultipartUpload (up to 120 s) is still running, and rejecting would lose a valid save. A truly lost upload is cleaned up when the reservation expires. A store error is `503`.
4. Mark the row committed as today.

Reject means: delete the row (the trigger queues the abort and the object delete), call `abort_multipart/2` once ignoring the result, and respond `422` on `upload`. Part failures use the message `has missing or wrong parts`.

Step 1 repeats what the signed `Content-MD5` already enforced, and step 3 repeats what step 1 established, but each is the server's only proof at that point: step 1 that the parts it is about to stitch are the declared ones, and step 3 that the stored object is the stitched result. Both are cheap.

A `503` after the upload completed leaves an object and a reserved row. A retried commit lands in step 1's `NoSuchUpload` branch and verifies by `HEAD`, so a retry is safe. If the reservation expires instead, the row's deletion queues the object as for any other reservation.

`complete_multipart/3` gets a 120-second receive timeout instead of the store's usual 15 seconds, since completing hundreds of parts can take S3 longer. A commit request can therefore take up to about two minutes; the CLI's commit timeout must allow that.

### M7. A multipart entry's `sha256` is the client's declaration

R2 cannot check a SHA-256 on multipart uploads (Evidence), so for a multipart entry the stored `sha256` is the value from reserve, returned unchanged on lookups. What the store does enforce is each part's length and MD5 and, through the ETag, the exact list of parts. The remaining gap is a writer whose bytes do not hash to its declared `sha256`. That writer already holds write access to that scope and could upload any archive it likes with a matching digest, so the gap grants nothing new. Restoring clients must check size and `sha256` before extracting, which the cache-storage spec already asks of clients, and treat a mismatch as a miss. Single-PUT entries keep the store-enforced SHA-256 (D3).

### M8. ObjectStore behaviour

New callbacks, all on `GoodFlows.Caches.ObjectStore` with delegating functions like the existing ones:

| Callback | Store request | Returns |
|---|---|---|
| `create_multipart(object_key)` | `POST ?uploads` | `{:ok, upload_id}` or `{:error, term}` |
| `presign_part(object_key, upload_id, number, %{size, md5, expires_in})` | none (local) | `{url, headers}`, headers `content-length` and `content-md5` |
| `list_parts(object_key, upload_id)` | `GET ?uploadId=` (paged) | `{:ok, [%{number, etag, size}]}`, `{:error, :not_found}`, `{:error, term}` |
| `complete_multipart(object_key, upload_id, [{number, etag}])` | `POST ?uploadId=` | `:ok`, `{:error, :not_found}`, `{:error, {:rejected, code}}`, `{:error, term}` |
| `abort_multipart(object_key, upload_id)` | `DELETE ?uploadId=` | `:ok`, `{:error, :not_found}`, `{:error, term}` |

`head/1` also returns `etag` (quotes stripped). `ObjectStore.part_headers/2` builds the part headers so the S3 adapter and the Fake agree, as `upload_headers/2` does.

`ObjectStore.S3` parses the XML responses (`InitiateMultipartUploadResult`, `ListPartsResult`, `CompleteMultipartUploadResult`, `Error`) with a small private module over `:xmerl_sax_parser` with entity expansion disabled, the same approach `req_s3` takes internally. `:xmerl` is added to `extra_applications`. Nothing logs a URL or an upload id together with a signature, as D10 requires.

`ObjectStore.Fake` models the whole lifecycle so the suite needs no bucket:
- `create_multipart/1` returns a fresh id; uploads are `open`, `completed` or `aborted`.
- `presign_part/4` records the signed headers per `{upload_id, number}` and returns a URL with the sentinel signature and the `partNumber` and `uploadId` query parameters.
- `put_part(url, headers, body)` simulates a part PUT: `:signature_mismatch` unless the headers equal the signed ones, `:length_mismatch`, `:bad_digest` when the body's MD5 differs from `content-md5`, `:no_such_upload` when the upload is not open; otherwise stores the part with ETag `hex(md5(body))`, replacing an earlier upload of that number as S3 does.
- `list_parts/2`, `complete_multipart/3` (`{:error, {:rejected, "InvalidPart"}}` when a given ETag does not match the stored part; creates the object with the multipart ETag, the summed size and no SHA-256) and `abort_multipart/2`.
- Failure injection for each call (extending `fail_deletes/1` and `heal/1`) and a helper to complete an upload behind the server's back, for the retried-commit path.

### M9. HTTP and OpenAPI

`CacheEntryController.reserve` is unchanged apart from documentation; `CacheEntryJSON.reservation/1` renders either the single-PUT or the multipart shape. `CacheUploadController.commit` is unchanged apart from its description. OpenAPI: `CacheReservationRequest` gains `parts` (`CacheUploadParts`: `size`, `md5`), and `CacheReservationResponse` documents `upload_parts` (`CacheUploadPart`: `number`, `url`, `headers`) with `upload_url` and `upload_headers` marked as present only without `parts`. The reserve operation documents `503` for a store that cannot create the upload. The `api_spec.ex` cache section says not to send `Authorization` to part URLs either, and that a multipart entry's `sha256` is not verified by the store.

## Risks / Trade-offs

- [SHA-256 not store-verified for multipart entries] -> Per-part MD5 and the multipart ETag bind the object to the declared parts, and clients verify `sha256` on restore (M7). MD5 is not collision-resistant, but only a key that may write the scope can declare the MD5s, and it can already write anything there.
- [Providers whose ETags are not MD5s] -> With SSE-KMS or SSE-C on AWS S3, ETags are not MD5 digests, so every multipart commit fails with `422`. That fails closed; single PUTs are unaffected. R2 and MinIO return MD5 ETags (task 6.2 confirms).
- [A part PUT still running when the upload is aborted] -> S3 documents that a part upload in progress during an abort may still succeed, leaving part storage that a second abort frees. Such a part can never become an object. R2 aborts incomplete uploads after 7 days anyway; on AWS S3, an `AbortIncompleteMultipartUpload` lifecycle rule is a safe backstop because it never touches completed objects. MinIO drops stale uploads on its own after its `stale_uploads_expiry` (24 hours by default).
- [A commit's CompleteMultipartUpload outlasting the sweep] -> A commit that loaded the row before it was purged could, in theory, still be completing when the sweep aborts and deletes. The abort makes a later completion fail; a completion that finished just before the delete is removed by it. The only window is a completion the store accepted but had not finished before the delete, which the 60-second margin plus the 120-second complete timeout make unlikely but not impossible. That would leave one untracked object, the same class of gap D2 accepts for long-running single PUTs.
- [Commit takes longer] -> ListParts paging and CompleteMultipartUpload add up to about two minutes in the worst case (M6). The CLI must not time out commit sooner.
- [Large responses] -> A reservation at the entry cap with 5 MiB parts lists 954 part URLs, roughly 0.6 MB of JSON. Acceptable; the CLI is expected to use larger parts (16 MiB in the measurement).
- [Reserve now needs the store] -> A multipart reserve fails with `503` while the store is down; single-PUT reserves still succeed and fail at the PUT. The CLI treats `503` as a skipped save, as before.

## Migration Plan

1. Deploy the migration (`add_multipart_to_cache_entries`: three nullable columns and a check constraint on `cache_entries`, one nullable column on `cache_object_deletions`, the replaced trigger function) and the code together. Existing rows are untouched, and clients that never send `parts` see no change.
2. Run `scripts/cache-object-store-check.sh` against the R2 bucket (task 6.2) before announcing `parts` to the CLI.
3. Rollback: `mix ecto.rollback -n 1` restores the old trigger function and drops the columns. Committed multipart entries keep working with the old code (lookups only read the object). Old code would reject uncommitted multipart reservations at commit (no SHA-256 on `HEAD`), and the uploads of rows dropped this way are no longer aborted by the app; R2 aborts them after 7 days. Rolling back also drops `cache_object_deletions.multipart_upload_id`, so aborts still queued at that point are lost (their object keys stay queued and are deleted); the abandoned part storage then relies on the store's own expiry of incomplete uploads (R2 after 7 days, MinIO's stale-upload expiry, or an `AbortIncompleteMultipartUpload` lifecycle rule on AWS S3).
