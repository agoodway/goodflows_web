# Proposal

## Why

The `goodflows` CLI is adding job caches (goodflows change `add-job-caches`). A job declares caches by name, paths and key, and the CLI archives the paths as a tar.gz and keeps a local store. A local store helps a developer's machine, but CI machines and Sprite remote runners start empty, so they need a shared store. This change makes the GoodFlows server that store for a project. The CLI reaches it with the existing `[reporting]` project, URL and Bearer key.

A Sprite runner executes the job's code, which may be a pull request's. The reporting (`sk_`) key is deliberately never sent to a Sprite. The Sprite gets a cache key instead: a key that can touch only one project's caches, and when it may write, only one branch's scope.

## What Changes

- Add a `cache-storage` capability under `/api/v1/projects/:project/caches`. It is a two-phase, immutable, first-writer-wins entry store whose archive bytes live in S3-compatible object storage, Cloudflare R2 in production. The app hands out presigned URLs and never streams an archive itself.
  - `GET .../caches/entries/:key?scope=` restores an exact key. `GET .../caches/entries?partial=&scope=` returns the newest entry with that partial. Both read the given scope first, then the project's default-branch scope, and never another branch's.
  - `POST .../caches/entries/:key` reserves an upload in one scope and returns a presigned PUT URL plus the headers the PUT must send. `POST .../caches/uploads/:upload_id/commit` makes the entry visible after the server checks the stored object's size and SHA-256.
  - `GET .../caches` lists entries and the project's usage. `DELETE .../caches/entries/:key?scope=` and `DELETE .../caches/entries?name=&scope=&partial=` purge entries, for example a poisoned cache. Listing and deleting need an `sk_` key.
- Add cache keys (`ck_…`). Each is bound to one project and has the `read` or `read_write` access level. A key can optionally be bound to one `scope`. A bound key writes only that scope and reads only that scope and the default-branch scope. Cache keys get `403` on every other API route. An `sk_` key mints cache keys through `POST /api/v1/projects/:project/cache-keys`, lists them through `GET`, and revokes them through `DELETE`. Minting is the only way to create one. A `read_write` key expires within 24 hours, so the CLI gives each Sprite run its own short-lived key. A `read` key may be minted with `"ttl_seconds": null` and never expire, or with a TTL of up to one year, so an orb (through an Amp project secret used by `.agents/setup`) or another long-lived environment can restore caches while only CI writes. Orb keys are bound to the default branch.
- `pk_` keys get `403` on every cache route. `sk_` keys can do everything a cache key can, plus list and delete.
- Limits and retention: each entry is 1 byte to 5,000,000,000 bytes compressed, the goodflows CLI's cap. That fits one presigned PUT on R2, whose single-request limit is 5,363,466,240 bytes (5 GiB less 5 MiB), so no multipart upload is needed. The entry cap is configurable but can't be set above that R2 limit. A project's quota defaults to 50 GiB, counting committed entries and unexpired reservations. A reservation that does not fit evicts committed entries least recently used first. Entries not read for 7 days are evicted. Reservations expire after 2 hours. All of these are runtime configuration.
- `projects`: a project gains a `default_branch` (default `main`) that names its fallback cache scope. `POST /api/v1/projects` accepts it, and a new `PATCH /api/v1/projects/:project` changes only `default_branch`. Slugs still cannot be renamed. Cache entries and cache keys do not block deleting a project. They are deleted with it.
- Not included: a dashboard page that lists and purges cache entries (the API covers purging), creating, listing or revoking cache keys in the dashboard, long-lived `read_write` keys, per-account quotas, cache sharing across projects, multipart uploads, and a server-side proxy for object storage.

### Differences from the protocol proposed in goodflows `add-job-caches`

- Keys are unique per scope, not per project. The exact-key `GET` takes `scope` and falls back to the default-branch scope the same way the partial lookup does. Otherwise a feature branch could write a key first and every later `main` run would restore it, which is the poisoning the scope rule exists to stop. `409` on reserve means the key is already committed, or is reserved and unexpired, in that scope.
- `scope` is an opaque label (1 to 256 bytes, no control characters), not a Git ref, so the CLI can take it from env vars such as `GITHUB_HEAD_REF`. The default-branch scope is the scope equal to `projects.default_branch`.
- `scope` is optional on reads. Without it, a read checks only the default-branch scope, which suits a detached checkout that has no branch. Writes require `scope`.
- The reserve response returns an `upload_id`, and commit is `POST .../caches/uploads/:upload_id/commit`, not `.../entries/:key/commit`. Only the API key that reserved may commit. That keeps commit unambiguous now that a key can exist in several scopes.
- The reserve response includes `upload_headers`, which the PUT must send exactly as given: `content-length`, `content-type: application/gzip`, and `x-amz-checksum-sha256`. They are signed into the URL, so the object store rejects a body whose size or SHA-256 differs from the reservation.
- The reservation body also carries `name`, the cache's declared name, so the list and purge APIs can select a cache by name. It is metadata only and plays no part in lookup.
- The CLI MUST NOT send its `Authorization` header to `download_url` or `upload_url`. Those are bearer URLs on another origin.
- A full quota that eviction cannot free, because unexpired reservations fill it, responds `507` instead of `409` or `403`.
- Responses use the app's `{"data": …}` and `{"errors": …}` envelopes.

## Capabilities

### New Capabilities

- `cache-storage`: two-phase upload, scoped lookup, object-storage-backed download, quotas, retention, purge, and cache keys.

### Modified Capabilities

- `projects`: projects gain `default_branch` and an update route for it, and cache entries and cache keys are deleted with a project instead of blocking the delete.

## Impact

- New `GoodFlows.Caches` context with `Entry` and `ObjectStore` (behaviour plus an S3 implementation and a test fake). Migrations add `cache_entries`, `cache_object_deletions` (fed by an `AFTER DELETE` trigger), `projects.default_branch`, and `api_keys.project_id` and `api_keys.scope`.
- `ApiKey` gains `:cache_read` and `:cache_write` types with the `ck_` prefix. `ApiAuth` rejects cache keys outside cache routes. The dashboard is unchanged.
- New controllers `CacheEntryController`, `CacheUploadController`, and `CacheKeyController`, their JSON views and OpenAPI schemas, and `ProjectController.update`.
- New dependency: `req_s3` (built on the `Req` client the app already uses) for presigning and for `HEAD` and `DELETE`. New runtime configuration: `CACHE_S3_*` and `CACHE_*` limits. When the bucket is not configured, cache routes respond `503`.
- A `Caches.SweepScheduler` (leader-only, like `Spry.ReaperScheduler`) enqueues a PgFlow `Caches.SweepJob` that expires reservations, evicts stale entries, and deletes queued objects.
- Companion change in goodflows (`add-job-caches`): the client side of this protocol, minting a per-run cache key for each Sprite, and treating every remote cache failure as a miss or a skipped save.
