# Proposal

## Why

A cache save uploads the whole archive through one presigned PUT, and one PUT is slow. On the Cloudflare R2 test bucket, 1 GB took 59.0 s as a single PUT (17 MB/s) and 19.6 s as 8 parallel 16 MiB multipart parts (51 MB/s). Home-directory caches can be several GB, so saves take minutes that parallel parts would cut by about two thirds. The goodflows CLI (agoodway/goodflows) is adding parallel part uploads in a companion change that uses the contract below.

## What Changes

- Reserve (`POST /api/v1/projects/:project/caches/entries/:key`) accepts an optional `parts` object, `{"size": <part size in bytes>, "md5": [<base64 MD5 of part 1>, ...]}`. The part size must be from 5,242,880 through 5,368,709,120 bytes. The part count is `ceil(size / parts.size)`, must equal the length of `md5`, and is at most 10,000. Each `md5` entry is the base64 of 16 bytes. Anything else is `422` on `parts`. `sha256` stays required.
- With `parts`, the server starts an S3 multipart upload and the `201` response has `upload_parts`, a list of `{"number", "url", "headers": {"content-length", "content-md5"}}` in part order, plus `upload_id`, `upload_url_expires_at` and `expires_at`. It has no `upload_url` or `upload_headers`. Each part URL is signed with exactly those headers, so the store rejects a part whose length or MD5 differs. The client never sends `Authorization` to a part URL. Part URLs expire with the reservation (default 7,200 s), not after the single PUT's 15 minutes.
- Commit (`POST .../caches/uploads/:upload_id/commit`, no body) for a multipart reservation lists the parts itself and does not trust client ETags. Every part must be present with an ETag equal to the hex of its declared MD5. The server then completes the upload, HEADs the object, and checks its size and that its ETag is `hex(MD5(declared part MD5s concatenated)) + "-" + count`. A missing or mismatched part, or a wrong size or ETag, is `422` on `upload`; the reservation is deleted and the multipart upload aborted. An unreachable store is `503` with `retry-after`, as today. Retrying a committed upload stays an idempotent `200`.
- A multipart entry's stored `sha256` is the client's declared value. R2 cannot enforce a SHA-256 on multipart uploads (design, Evidence), so the store does not verify it. Restoring clients already verify size and `sha256` before extracting. Single-PUT entries keep the full SHA-256 check.
- Without `parts`, reserve and commit behave exactly as today.
- Deleting a multipart reservation by any means (expiry, purge, eviction, rejected commit, project or account delete) aborts its multipart upload through the existing object deletion queue.
- Quota, eviction and the entry cap use the declared `size` as now. The 5,000,000,000-byte entry cap and its 5,363,466,240-byte ceiling do not change.
- Not included: raising the entry cap, per-part SHA-256 or full-object CRC64NVME checksums, resuming an upload under a new reservation, letting the client choose part numbers or complete the upload itself, and changes to downloads.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `cache-storage`: reserve accepts `parts` and returns presigned part URLs. Commit verifies multipart uploads by part ETags and the multipart ETag instead of a SHA-256. Deleting a multipart reservation aborts its upload. The single-PUT requirements are scoped to reservations without `parts`.

## Impact

- `GoodFlows.Caches` (`reserve/5`, `commit/3`), `GoodFlows.Caches.Entry`, `GoodFlows.Caches.Sweep`.
- `GoodFlows.Caches.ObjectStore` gains multipart callbacks. `ObjectStore.S3` implements them with `req_s3` presigning and `Req`'s `aws_sigv4` step, and the test `ObjectStore.Fake` models them, including MD5 enforcement.
- A migration adds `cache_entries.multipart_upload_id`, `part_size` and `part_md5s`, and `cache_object_deletions.multipart_upload_id`, and replaces the deletion trigger function.
- `CacheEntryController.reserve`, `CacheEntryJSON`, `CacheUploadController.commit`, and the OpenAPI schemas `CacheReservationRequest` and `CacheReservationResponse`.
- `scripts/cache-object-store-check.sh` and `scripts/e2e-cache-smoke.sh`.
- The goodflows CLI companion change (agoodway/goodflows) consumes this contract. Old clients that never send `parts` are unaffected.
