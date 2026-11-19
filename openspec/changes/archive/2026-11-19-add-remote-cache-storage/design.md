# Design

## Context

See proposal.md for motivation and specs/cache-storage/spec.md for the behavior contract.

The goodflows CLI design (`add-job-caches`) fixes the client side:
- `partial = sha256(format version, name, os, arch, values)` and `key = sha256(partial, files digest)`, both 64 lowercase hex.
- An entry is one tar.gz archive of at most 5,000,000,000 bytes compressed.
- Rolling caches (`key.unique`) save a new entry on every commit and rely on LRU eviction to drop old ones. Home-directory caches such as `~/.cargo/registry` and `~/.npm` can each be several GB.
- Restore tries the exact key, then the newest entry with the same partial. Save happens only when the exact key missed. Entries are immutable and the first writer wins.
- The remote store is reached with the existing `[reporting]` project, URL and Bearer key. A Sprite remote runner never gets the reporting key.

What the app has today:
- `GoodFlows.Accounts.ApiKey` has two types, `:public` (`pk_`, read-only) and `:private` (`sk_`). A key belongs to an `account_user`, so it carries a user and an account, but no project. `ApiAuth` authenticates any active, unexpired key. `ApiAuth, :require_write_access` returns `403` unless `ApiKey.can_write?/1`, which is true only for `:private`.
- Project-scoped routes resolve `:project` with `LoadProject` as the last plug: `422` for an invalid slug, `404` for a slug not in the key's account.
- There is no object storage and no S3 client. Test reports and workflow runs are JSON in Postgres. `Req` is already a dependency.
- Background work runs on PgFlow. `Spry.ReaperScheduler` enqueues a PgFlow job every 5 minutes from the `:global` leader only.
- A project has only a `slug`. Nothing records a project's default branch. The project API has no update route.
- Recipes, test reports and workflow runs block project deletion with a composite `(project_id, account_id)` foreign key and `ON DELETE NO ACTION`.

## Goals / Non-Goals

**Goals:**
- A remote cache that matches the CLI's restore and save rules, with archive bytes going straight between the client and object storage.
- Branch scopes that keep a feature branch from poisoning the default branch, enforced by the server and not by client behavior.
- A credential a Sprite can hold that touches only one project's caches, and when bound, only one branch's scope.
- Bounded storage per project, with eviction that never needs an operator.
- A way to purge a poisoned cache.

**Non-Goals:**
- Any dashboard change. Purging is through the API only, and cache keys are created only by minting (D5).
- Long-lived `read_write` cache keys. Only CI and per-run Sprite keys write, and `read_write` keys last at most 24 hours.
- Multipart uploads. R2 accepts one PUT of up to 5,363,466,240 bytes (5 GiB less 5 MiB) and S3 up to 5 GiB, both above the 5,000,000,000-byte entry cap.
- Proxying archive bytes through the app, or serving caches without object storage.
- Per-account quotas, cross-project sharing, and cache statistics.
- Compressing, unpacking or inspecting archives on the server.

## Decisions

### D1. Object storage is an S3-compatible bucket reached through presigned URLs

The app gets object storage as one S3-compatible bucket configured at runtime:

| Variable | Notes |
|---|---|
| `CACHE_S3_BUCKET` | required to enable caches |
| `CACHE_S3_ENDPOINT` | for example `https://<account>.r2.cloudflarestorage.com`; omit for AWS S3 |
| `CACHE_S3_REGION` | `auto` for R2 |
| `CACHE_S3_ACCESS_KEY_ID`, `CACHE_S3_SECRET_ACCESS_KEY` | credentials scoped to that bucket; required when `CACHE_S3_BUCKET` is set, or the server refuses to boot |

Production uses Cloudflare R2. Cache traffic is mostly downloads, and R2 has no egress fees. MinIO is the local and smoke-test store, and AWS S3 works the same way. GCS is not supported: its S3 interoperability API is not known to honor `x-amz-checksum-sha256` (Risks).

`GoodFlows.Caches.ObjectStore` is a behaviour with `presign_put/2`, `presign_get/2`, `head/1` and `delete/1`. `ObjectStore.S3` implements it with `req_s3` (a `Req` plugin): `ReqS3.presign_url/1` for both URLs and `Req` `HEAD`/`DELETE` for the rest. Tests use an in-memory `ObjectStore.Fake` selected through config, so the suite needs no bucket. A `just`/script target runs MinIO for the end-to-end smoke test.

When `CACHE_S3_BUCKET` is unset, every cache route responds `503` with a fixed detail, and the sweep (D7) skips only its object deletions (step 4). Cache-key routes keep working, so keys can be minted before a bucket exists, and old cache keys, expired reservations and stale entries are still deleted. Rows left from a bucket that was later unset queue their objects as usual, and those objects are deleted once a bucket is configured again. The CLI treats `503` as a miss or a skipped save.

Object keys are `caches/<project_id>/<upload_id>`. They are chosen by the server and never contain the cache key, scope or name. Each reservation gets a fresh `upload_id`, so a late PUT for an expired reservation can never overwrite a committed entry's object.

*Alternative considered:* streaming archives through the app into Postgres large objects or a volume. Rejected: 5 GB bodies would tie up Phoenix processes and database storage, and the user asked that the app not stream large archives.

### D2. One table holds reservations and entries

`cache_entries` (`GoodFlows.Caches.Entry`):

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | also the `upload_id` |
| `account_id` | uuid | `references(:accounts, on_delete: :delete_all)` |
| `project_id` | uuid | composite FK `(project_id, account_id)` -> `projects (id, account_id)`, `ON DELETE CASCADE` |
| `scope` | text | an opaque label, usually a branch name (D3, D4) |
| `key` | text | 64 lowercase hex |
| `partial` | text | 64 lowercase hex |
| `name` | text | the cache's declared name (D3), metadata only |
| `size` | bigint | bytes, 1..`:cache_max_entry_bytes` (default 5,000,000,000) |
| `sha256` | text | 64 lowercase hex of the archive bytes |
| `object_key` | text | D1 |
| `state` | text | `reserved` or `committed` |
| `reserved_by_api_key_id` | uuid null | `references(:api_keys, on_delete: :nilify_all)` |
| `expires_at` | utc_datetime_usec null | set while `reserved`, null once committed |
| `upload_expires_at` | utc_datetime_usec | when the presigned upload URL expires; signed before the row is inserted and taken after signing, so the URL never outlives it |
| `committed_at` | utc_datetime_usec null | |
| `last_accessed_at` | utc_datetime_usec null | set at commit and on hits (D6) |
| `inserted_at` | utc_datetime_usec | |

A check constraint ties `state` to the timestamps: `reserved` has `expires_at` and no `committed_at`, and `committed` has `committed_at` and `last_accessed_at` and no `expires_at`.

Indexes:
- unique `(project_id, scope, key)`. A key is unique per scope, not per project (D4). A reservation holds the slot, so two writers can't both reserve.
- `(project_id, scope, partial, committed_at DESC, id DESC) WHERE state = 'committed'` for the partial lookup
- `(project_id, last_accessed_at, id) WHERE state = 'committed'` for eviction
- `(expires_at) WHERE state = 'reserved'` for the sweep
- `(last_accessed_at) WHERE state = 'committed'` for the sweep's retention step
- `(project_id, name)` for list and purge by name
- `reserved_by_api_key_id`, for the nilify on key delete

`ON DELETE CASCADE` on the project FK is a deliberate difference from recipes, test reports and workflow runs. A cache is a disposable copy of something a run can rebuild, so it should never stop a project from being deleted (projects delta).

An `AFTER DELETE` row trigger on `cache_entries` inserts `OLD.object_key` into `cache_object_deletions (object_key text primary key, inserted_at, delete_after)`, with `delete_after` the later of now and `OLD.upload_expires_at`. Every way a row disappears — purge, eviction, expiry, a commit that rejects the upload, project delete or account delete cascading — then queues its object, and the sweep deletes it once `delete_after` is more than 60 seconds past (D7), outside any request. The object of a row deleted while its upload URL is still valid is kept until that URL has expired, so no new PUT can recreate it afterwards. `ON CONFLICT DO NOTHING` keeps the queue idempotent.

### D3. Wire contract

All paths are under `/api/v1/projects/:project/caches`. Bodies and responses are JSON with the app's `{"data": …}` and `{"errors": …}` envelopes. Field rules:

- `key`, `partial`, `sha256`: exactly 64 lowercase hex characters. A path `key` that fails this is `404`, not `422`, like `run_id` on workflow runs. A query or body value that fails it is `422` on that field.
- `scope`: an opaque label of 1 to 256 UTF-8 bytes with no control characters. It is not validated as a Git branch or ref name: the CLI takes it from a `[cache] scope` expression over env vars (for example `env.GITHUB_HEAD_REF ?? env.GITHUB_REF_NAME`) and falls back to the Git branch, so `pr-42`, `refs/pull/42/merge` and names Git would reject are all valid. 256 bytes leaves room for long branch names and matches the `source.branch` rule from `accept-upload-envelope`. Scopes are compared as exact byte strings, with no trimming or case folding.
- `name`: goodflows' name rule (non-blank, at most 64 bytes, no control characters).
- `size`: an integer from 1 through `:cache_max_entry_bytes` (default 5,000,000,000). Above that is `413`.

**Exact lookup.** `GET .../caches/entries/:key?scope=<scope>` returns `200` with the entry from the first scope in the lookup order (D4) that has `key` committed, or `404`.

**Partial lookup.** `GET .../caches/entries?partial=<partial>&scope=<scope>` returns `200` with the newest committed entry (`committed_at DESC, id DESC`) with that partial in the first scope in the lookup order that has one, or `404`. A newer entry in the default-branch scope does not beat an older one in the requested scope. That is how GitHub Actions caches behave, and it keeps a branch on its own lineage. `partial` is required (`422`).

Both lookups return:

```json
{"data": {"key": "…", "partial": "…", "name": "deps", "scope": "main",
          "size": 52428800, "sha256": "…", "created_at": "2026-11-16T12:00:00Z",
          "download_url": "https://…", "download_url_expires_at": "2026-11-16T12:15:00Z"}}
```

`created_at` is `committed_at`. `scope` says which scope matched. `download_url` is a presigned GET valid for `:cache_download_url_ttl_seconds` (default 900).

**Reserve.** `POST .../caches/entries/:key` with `{"name", "partial", "scope", "size", "sha256"}` (all required, no other keys). On success, `201`:

```json
{"data": {"upload_id": "…", "upload_url": "https://…",
          "upload_headers": {"content-length": "52428800", "content-type": "application/gzip",
                             "x-amz-checksum-sha256": "<base64 of the digest>"},
          "upload_url_expires_at": "…", "expires_at": "…"}}
```

The client MUST send exactly `upload_headers` with its PUT. They are SigV4-signed into the URL, so the object store rejects a body whose length differs (S3 and R2 require `Content-Length` to match the body) and a body whose SHA-256 differs (`BadDigest`). `upload_url` is valid for `:cache_upload_url_ttl_seconds` (default 900): S3 checks expiry when a request starts, so a PUT that starts in time can finish. The reservation is valid for `:cache_reservation_ttl_seconds` (default 7,200). A PUT that starts at the last moment then has 105 minutes to finish, which a 5 GB archive needs at about 0.8 MB/s (6.4 Mbit/s). The old one-hour default left 45 minutes, which needs about 1.9 MB/s and is too tight for a 5 GB upload from a slow runner.

Other reserve outcomes:
- `409` when `key` is committed in `scope`, or reserved there and unexpired. An expired reservation is replaced in the same transaction. A `409` never names the other writer.
- `403` when the key may not write that scope (D5).
- `413` when `size` is above the entry cap.
- `422` for an invalid or missing field, or an unknown key in the body.
- `507` when the quota can't be freed (D6).

Reserve does not check other scopes: a key already committed in the default-branch scope can still be reserved in a feature scope. The CLI reserves only after its exact lookup missed in both, so this happens only in a race, and the duplicate is harmless.

**Commit.** `POST .../caches/uploads/:upload_id/commit` with no body. The server:
1. Loads the reservation by `(project_id, id)`. It is `404` if it does not exist, has expired, or was reserved by a different API key. An `upload_id` that is not a UUID is `404`.
2. Returns `200` with the entry if it is already committed and was reserved by this key, so a retried commit is safe.
3. Calls `ObjectStore.head/1` with checksum mode enabled. The object must exist, its `Content-Length` must equal `size`, and its `x-amz-checksum-sha256` must equal the reserved digest. Otherwise the reservation is deleted (which queues the object, D2) and the response is `422` on `upload` with `is missing`, `has the wrong size`, or `has the wrong checksum`. When the store cannot answer the `HEAD`, the response is `503` with `retry-after: 1` and the reservation is kept, so the client can commit again.
4. Sets `state = committed`, `committed_at` and `last_accessed_at` to now, and `expires_at` to null, and returns `200` with the same body as a lookup (including a `download_url`).

The `HEAD` repeats checks the signed PUT already enforced. It is the server's only proof that the bytes are there, and it is cheap.

**List.** `GET .../caches?name=&scope=&cursor=&limit=` (sk_ only) returns committed entries newest first, without download URLs, keyset-paged with `KeysetCursor` (`limit` 1..200, default 50), plus `usage: {"bytes", "entries", "quota_bytes", "max_entries"}`. Reservations are counted in `usage` but not listed.

**Purge.** `DELETE .../caches/entries/:key?scope=` deletes that entry, or its reservation, in one scope (`scope` required). `DELETE .../caches/entries?name=&scope=&partial=` deletes every entry and reservation matching all given filters, and requires at least one of them (`422` otherwise, so a bare `DELETE` can't empty a project by accident). Both respond `200` with `{"data": {"deleted": n}}`, `0` included, so a purge is idempotent. Both are sk_ only. A download URL handed out before a purge still serves the old bytes until the next sweep deletes the object (D7, every 5 minutes) or the URL expires, whichever comes first.

The proposal lists where this contract differs from the CLI's draft protocol and why.

### D4. Scopes

A scope is an opaque label (D3), usually a branch name. The default-branch scope is simply the scope whose string equals `projects.default_branch` (projects delta, default `main`). `default_branch` follows the same rule as `scope`.

The lookup order for a request with `scope=S` is `S`, then the default-branch scope when it differs from `S`. Without `scope`, it is the default-branch scope only. No request ever reads a third scope. Keys are unique per scope, so each lookup step is an indexed equality query.

Keys are unique per scope, not per project. With per-project keys, a feature branch that first wrote key K would serve K to every later `main` run, even with lookups scoped. An identical key from a branch is usually byte-identical content, but the cache exists to keep feature branches from seeding the default branch, so the server can't assume it.

Writes require `scope`. Any scope may be written by a key allowed to write it (D5), the default-branch scope included: that is how default-branch CI fills the fallback. Changing `default_branch` changes only which scope later lookups fall back to. It moves or deletes nothing.

### D5. Cache keys

Add two `ApiKey` types: `:cache_read` and `:cache_write`. Their tokens start with `ck_`, and both prefixes stay 3 characters, so the 12-character lookup prefix is unchanged. Migration `add_cache_columns_to_api_keys` adds:
- `project_id uuid null` with `references(:projects, on_delete: :delete_all)`, required for cache types and null otherwise (check constraint)
- `scope text null`, allowed only for cache types and following the D3 scope rule

`ApiKey.can_write?/1` stays true only for `:private`. A new `ApiKey.cache_access(key, project, scope, :read | :write)` decides cache access:

| Key | Read with scope `S` | Write scope `S` | List, purge |
|---|---|---|---|
| `sk_` | yes | yes | yes |
| `pk_` | no (`403`) | no (`403`) | no (`403`) |
| `ck_` read, unbound | yes | no (`403`) | no (`403`) |
| `ck_` read-write, unbound | yes | yes | no (`403`) |
| `ck_` bound to scope `B` | only `S = B`, `S` = the default branch, or no `scope` | only `S = B` (read-write keys) | no (`403`) |

A `ck_` key on a project other than its own gets `403`. `ApiAuth`'s default clause (`plug ApiAuth`) now returns `403` for cache keys, so every existing route, read routes included, refuses them without any change of its own. Cache routes use `plug ApiAuth, :allow_cache_keys`.

`pk_` keys get no cache access. A pk_ key is meant to be shareable for reading run data. A cache archive is executable input to a build, may hold build outputs, and is far larger than any document the API serves, so read access belongs to the `ck_` read type that someone mints for that purpose.

**Minting.** `POST /api/v1/projects/:project/cache-keys` (sk_ only) with `{"access": "read" | "read_write", "scope"?: "…", "ttl_seconds"?: n, "name"?: "…"}` returns `201` with `{"data": {"id", "token", "access", "scope", "expires_at"}}`. A project holds at most `:cache_max_keys_per_project` (default 1,000) active cache keys, neither revoked nor expired; minting one more returns `422`, and mints of one project are serialized by a `FOR NO KEY UPDATE` lock on the project row so concurrent mints cannot pass the cap. Any other body key is `422`, as for the reserve body, so a typo such as `ttl` cannot silently give the default lifetime. The token appears only in this response, as for dashboard-created `sk_` and `pk_` keys. Minting is the only way to create a cache key. Lifetimes depend on `access`:

| `access` | `ttl_seconds` omitted | `ttl_seconds` allowed | `ttl_seconds: null` |
|---|---|---|---|
| `read_write` | 21,600 (6 hours) | 60..86,400 | `422` |
| `read` | 21,600 (6 hours) | 60..31,536,000 (1 year) | no expiry; `name` required |

A non-expiring key needs an explicit `null`. Omitting `ttl_seconds` gives the 6-hour default, so a client that forgets the field never creates a permanent key. No expiry fits the app because dashboard `sk_` and `pk_` keys already allow a null `expires_at`. The one-year cap is for callers that want forced rotation. A non-expiring key must have a `name` so someone can tell it apart in the list later.

Long-lived `read` keys exist for orbs, where the key is an Amp project secret that `.agents/setup` uses, and for other long-lived environments. They restore caches, and only CI and Sprite runs write. Like any cache key, they can be bound to a scope. The recommended orb key is bound to the default branch:

```json
{"access": "read", "ttl_seconds": null, "scope": "main", "name": "orbs"}
```

Bound that way it reads only the default-branch scope, whatever `scope` the orb sends (D5 table: a bound key may read its own scope, the default branch, or with no `scope`). Unbound long-lived read keys stay allowed, for environments that should read any branch's lookup chain. It cannot write, list entries, purge, mint, or use any non-cache route.

`GET /api/v1/projects/:project/cache-keys` (sk_ only) lists the project's cache keys that are neither revoked nor expired, newest first: `id`, `name`, `access`, `scope`, `token_prefix`, `expires_at`, `last_used_at`, `inserted_at`. It never returns a token. Paging is keyset with `limit` 1..200 (default 50) and `cursor`. This route is how an operator finds a long-lived key to revoke without the dashboard. The key belongs to the minting key's `account_user`. `DELETE /api/v1/projects/:project/cache-keys/:id` (sk_ only) revokes one early (`204`, also when already revoked, and `404` for a key of another project or a non-cache key). The CLI mints one bound key per Sprite run and revokes it when the run ends. It binds the key to the run's branch, and mints a key bound to the default branch only for a run that is on the default branch. That key may write the default-branch scope, which is how Sprite runs on the default branch fill the fallback. The server can't tell which branch a run is on, so it trusts the scope the minting `sk_` key chose. Keys revoked or expired for more than 7 days are deleted by the sweep, so per-run minting doesn't grow `api_keys` forever. A non-expiring key stays until it is revoked.

Neither a `ck_` key nor a `pk_` key can mint.

### D6. Limits, quota and eviction

Runtime configuration, set in `config/runtime.exs` from env vars and documented in `.env.sample`:

| Setting | Default |
|---|---|
| `:cache_max_entry_bytes` (`CACHE_MAX_ENTRY_BYTES`) | 5,000,000,000; at most 5,363,466,240 |
| `:cache_project_quota_bytes` (`CACHE_PROJECT_QUOTA_BYTES`) | 53,687,091,200 (50 GiB) |
| `:cache_project_max_entries` (`CACHE_PROJECT_MAX_ENTRIES`) | 10,000 |
| `:cache_max_keys_per_project` (`CACHE_MAX_KEYS_PER_PROJECT`) | 1,000 active cache keys (D5) |
| `:cache_retention_days` (`CACHE_RETENTION_DAYS`) | 7 |
| `:cache_reservation_ttl_seconds` | 7,200 |
| `:cache_upload_url_ttl_seconds`, `:cache_download_url_ttl_seconds` | 900 |

`config/runtime.exs` MUST refuse to boot when `:cache_max_entry_bytes` is above 5,363,466,240 (R2's single-request upload limit, 5 GiB less 5 MiB) or above `:cache_project_quota_bytes`. Above the R2 limit, a PUT the server agreed to would always fail. Above the quota, a full-size entry could never fit. It MUST also refuse to boot when `:cache_upload_url_ttl_seconds` is above `:cache_reservation_ttl_seconds`, since an upload URL that outlived its reservation could create an object after the sweep deleted the reservation, and when `CACHE_S3_BUCKET` is set without both credentials, since every reserve would then fail after writing its row.

**Why 50 GiB.** At 10 GiB, two entries at the new cap fill the quota, and every new save of a large cache evicts the project's other caches. 50 GiB holds about ten full-size entries, or a typical mix: a few multi-GB home-directory caches (`~/.cargo/registry`, `~/.npm`) on the default branch, the same caches on a handful of active branches, and the latest entries of rolling caches. At R2's storage price, a full 50 GiB project costs well under a dollar a month, and R2 has no egress charges. A smaller deployment can lower it.

**Rolling caches.** A rolling cache (`key.unique`) writes a new key on every commit with the same partial. The partial lookup only ever returns the newest one, so older entries are never read again. Their `last_accessed_at` stays at their commit time, so once anything newer has been restored they rank below it for LRU eviction, the same as any entry nobody reads. Without quota pressure they last until the 7-day retention sweep. The 10,000-entry cap is far above what rolling caches need, since one entry per commit per branch for 7 days stays in the hundreds for most projects. No per-name limit is added in this change (see Risks).

Usage counts committed entries and unexpired reservations: `sum(size)` and `count(*)`. The entry cap stops a project from filling the table with tiny entries while staying under its byte quota.

Reserve presigns the upload first, then runs one transaction that takes `SELECT … FOR NO KEY UPDATE` on the project row, which serializes reservations per project without blocking the `FOR KEY SHARE` locks that inserts into the project's child tables take:
1. Delete an expired reservation for the same `(project_id, scope, key)`, if any.
2. Return `409` if the slot is still taken.
3. If adding the reservation would exceed either limit, delete committed entries in `last_accessed_at, id` order until it fits. Entries in every scope are candidates.
4. If it still doesn't fit, which means unexpired reservations fill the quota, roll back and return `507`.
5. Insert the reservation.

Eviction while reserving means a full project keeps working, and no operator has to clean up. `507` signals a project that is uploading more at once than it has room for.

A hit sets `last_accessed_at` only when the stored value is more than an hour old, so a hot cache doesn't write a row on every restore. Entries whose `last_accessed_at` is older than `:cache_retention_days` are evicted by the sweep.

### D7. Sweep

`GoodFlows.Caches.SweepScheduler` follows `Spry.ReaperScheduler`: it starts on every node, and only the `:global` leader enqueues `GoodFlows.Caches.SweepJob` (PgFlow, queue `:cache_sweep`, `max_attempts: 1`) every 5 minutes. One sweep:
1. Deletes reservations whose `expires_at` is past.
2. Deletes committed entries not accessed within the retention window.
3. Deletes API keys of a cache type revoked or expired more than 7 days ago.
4. Deletes up to 1,000 queued objects whose `delete_after` (D2) is more than 60 seconds past, a margin for clock skew between the sweep node, the node that signed the URL and the store, through `ObjectStore.delete/1` and removes each queue row after the store confirms (`204`, or `404` when the object is already gone). A failure leaves the row for the next sweep. No delete starts once the sweep has run for 200 seconds, so with the store's 15-second request timeout a slow store cannot push the job past its 300-second timeout; the rest stays queued.

Steps 1 to 3 run in batches of 1,000 rows. Without a cache bucket (D1) only step 4 is skipped, because objects cannot be deleted. Steps 1 and 2 only delete rows, and the trigger queues their objects, so they run as usual and step 4 catches up when a bucket is configured again. Sweeps are idempotent, so the leader handover overlap that `ReaperScheduler` documents is harmless here too.

### D8. Routes and pipelines

```
pipeline :api_cache_authenticated   # ApiAuth, :allow_cache_keys
pipeline :cache_access              # GoodFlowsWeb.Plugs.RequireCacheAccess

scope "/api/v1/projects/:project/caches" — [:api, :api_cache_authenticated, :load_project, :cache_access]
  get  "/entries/:key"                 CacheEntryController :show     (read)
  get  "/entries"                      CacheEntryController :lookup   (read)
  post "/entries/:key"                 CacheEntryController :reserve  (write)
  post "/uploads/:upload_id/commit"    CacheUploadController :commit  (write)

scope "/api/v1/projects/:project" — [:api, :api_authenticated, :api_write, :load_project, :cache_access]
  get    "/caches"                     CacheEntryController :index
  delete "/caches/entries/:key"        CacheEntryController :delete
  delete "/caches/entries"             CacheEntryController :delete_matching

scope "/api/v1/projects/:project" — [:api, :api_authenticated, :api_write, :load_project]
  get    "/cache-keys"                 CacheKeyController :index
  post   "/cache-keys"                 CacheKeyController :create
  delete "/cache-keys/:id"             CacheKeyController :delete
  patch  "/"                           ProjectController :update
```

`RequireCacheAccess` runs after `LoadProject`. It returns `403` for a `pk_` key and for a `ck_` key of another project, then `503` when the bucket is not configured. List and purge also pass through `:cache_access`, so they too respond `503` without a bucket, while the cache-key routes and `PATCH /` do not. The per-scope check needs the request's `scope`, so it runs in the controller through `ApiKey.cache_access/4`. Before that, and before the path key, Content-Type, query or body is validated, `ApiKey.precheck_cache_access/4` refuses with `403` a key that cannot satisfy the request whatever its fields: a `read` key reserving or committing, or a bound key whose raw `scope` is neither its bound scope nor (for reads) the default branch or absent. An unbound `ck_` key and an `sk_` key may use any valid scope, so their scope is checked after validation, and a malformed field gets `422`. The read/write split is by action. List, purge and minting sit on the existing `sk_` write pipeline, so the new default `ApiAuth` refusal returns `403` to `ck_` keys there.

The reserve body is small JSON and goes through `Plug.Parsers` like any other request. `RequireParsedBody` is not in the cache pipeline, so reserve does its own `415` check on Content-Type: it parses the header with `Plug.Conn.Utils.content_type/1`, so the media type is matched case-insensitively and parameters such as `charset=utf-8` are allowed. Commit has no body.

A cache key carries no user scope of its own, but `ApiAuth` still assigns `current_scope` from its `account_user`, so audit fields keep working.

### D9. No dashboard changes

The dashboard neither lists nor purges entries, and it doesn't create cache keys. `ApiKeyLive.Index` would otherwise list minted keys under the minting user, so its query filters to the `:public` and `:private` types. Cache keys, long-lived ones included, are listed and revoked through the API (D5). Purging is through the API (D3).

### D10. OpenAPI and hygiene

Add the schemas `CacheEntry`, `CacheEntryResponse`, `CacheReservationRequest`, `CacheReservationResponse`, `CacheListResponse`, `CachePurgeResponse`, `CacheKeyRequest`, `CacheKeyResponse` and `ProjectUpdateRequest`, and the `key`, `upload_id` and `scope` parameters. Document `403`, `404`, `409`, `413`, `422`, `503` and `507` where they apply.

Presigned URLs are bearer credentials. They never appear in logs: cache controller actions run with `Logger` metadata only, the S3 client does not log URLs, and `SentryScrubber` drops the request body for cache routes (the body `Sentry.PlugContext` captures; response bodies are never sent to Sentry). The proposal tells the CLI never to send `Authorization` to them. Tests assert a sentinel signature string never shows in captured logs.

## Resolved Questions

Approved by the user on 2026-11-16:
- `pk_` keys get no cache access (D5).
- A `ck_` key bound to the default branch may write that scope. The CLI mints one only for a run on the default branch (D5).
- The default branch is stored on the project (`projects.default_branch`, D4).
- The defaults in D6 stand, except those changed when the CLI raised its entry cap: entry cap 5,000,000,000 bytes, quota 50 GiB, reservation TTL 2 hours.
- The provider is Cloudflare R2 (D1).
- Purging is API-only, with no dashboard page (D9).
- Minted `read_write` keys last at most 24 hours (D5).
- Long-lived `read` keys: no expiry or an optional TTL of up to one year, minted and revoked only by `sk_` keys. Orb keys are bound to the default branch; unbound ones stay allowed (D5).
- Cache keys are API-only: no dashboard listing or revoking (D9).
- `scope` is an opaque label, not a Git ref (D3), so the CLI can derive it from env vars such as `GITHUB_HEAD_REF`.
- The same cache may be stored once per branch scope (D4).

## Risks / Trade-offs

- [Provider checksum support] -> Commit requires the store's `HEAD` to return `x-amz-checksum-sha256`. AWS S3, R2 and MinIO support SHA-256 PUT checksums. GCS interop may not, and a provider without them makes every commit fail with `422`. That fails closed. Task 6.2 checks R2 and MinIO before rollout.
- [A slow PUT outlives its row] -> An object is deleted only once its row is gone and its upload URL has expired (D2), so expiry, a rejected commit, purge and eviction never leave an object behind that a later PUT recreates. The one gap is a PUT the store accepted before the URL expired and that is still running when the object is deleted: for an expired reservation that means a PUT running for more than 105 minutes (the URL lasts 15 minutes, the reservation two hours), and for a reservation rejected or purged earlier, a PUT still running when its URL's 15 minutes are up. That leaves an orphan the app no longer tracks. A bucket lifecycle rule can't clean it up safely, because object age is not access age and the rule would also delete hot entries. Accepted for this version. A reconcile that lists `caches/` and deletes untracked objects is a follow-up if orphans show up in bucket usage.
- [Purge is not instant for URLs already issued] -> A URL issued before the purge works until the next sweep, about 5 minutes, or for an entry reserved less than 15 minutes before the purge, until the sweep after its upload URL expires. Acceptable for a poisoned cache. The CLI should also check the downloaded archive against the entry's `sha256` before unpacking it.
- [Eviction is per project and LRU] -> A project with one huge, frequently restored cache can evict its smaller ones. A rolling cache that writes 5 GB on every commit across many branches can churn through the quota and evict caches that are still useful but restored less often. A per-name quota is a follow-up if that shows up.
- [Large reservations hold quota] -> Each unexpired reservation counts toward the quota for up to 2 hours. Ten concurrent 5 GB reservations fill a 50 GiB project, and the eleventh gets `507` until one commits or expires. The CLI treats `507` as a skipped save.
- [Scope is a label the client picks] -> The server doesn't check that a scope is a real branch. Authority comes only from the key: an `sk_` or unbound read-write key may write any label, and a bound key only its own. A client that sends a wrong label with an unbound key can write any scope, `main` included, so Sprite keys must be bound.
- [Bound keys trust the scope the CLI chose] -> A bound key protects the default scope only if the CLI binds each Sprite key to the run's branch, and binds to the default branch only for a run on it. An unbound read-write key can write `main`. The CLI companion must bind every Sprite key.
- [Changing `ApiAuth`'s default] -> Every existing route now refuses `ck_` keys. No route accepts a key type that doesn't exist yet, so nothing that works today changes. Tests cover one read and one write route.
- [Unique keys per scope cost storage] -> The same archive can exist once per branch scope. Branch scopes age out after 7 days without reads.

## Migration Plan

1. Migrations: `add_default_branch_to_projects` (`text not null default 'main'`), `add_cache_columns_to_api_keys`, `create_cache_entries` (with `cache_object_deletions` and the trigger). None of them rewrites an existing row beyond the column default.
2. Deploy with `CACHE_S3_BUCKET` unset. Cache routes respond `503` and nothing else changes.
3. Create the R2 bucket and an R2 API token scoped to it, set `CACHE_S3_*`, and restart. Enable remote caching in goodflows.
4. Rollback: unset `CACHE_S3_BUCKET` to stop serving caches. Code from before this change cannot load an `api_keys` row of a cache type, so before redeploying older code, revoke cache keys and roll back the migrations (`mix ecto.rollback -n 3`). `add_cache_columns_to_api_keys` has an explicit `down` that deletes every cache key before it drops the constraints, index and columns. Dropping the table and columns loses only caches, and the bucket can be emptied separately.
