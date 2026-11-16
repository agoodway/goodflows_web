# Tasks

## 1. Projects

- [ ] 1.1 Add the `add_default_branch_to_projects` migration (`text not null default 'main'`) and `default_branch` on `Project` with the scope rule (an opaque label of 1 to 256 bytes with no control characters, not validated as a Git ref). Accept it on create, render it in `ProjectJSON`, and add `ProjectController.update` (`PATCH`, `default_branch` only, any other key `422`) on the project write scope. Update `ProjectRequest`/`ProjectResponse` and add `ProjectUpdateRequest`. Verify with `project_controller_test.exs` cases for every new scenario in the projects delta.

## 2. Object storage

- [ ] 2.1 Add `req_s3`. Add the `GoodFlows.Caches.ObjectStore` behaviour (`presign_put/2`, `presign_get/2`, `head/1`, `delete/1`), `ObjectStore.S3`, and an in-memory `ObjectStore.Fake` that records signed headers and enforces them on a simulated PUT. Read `CACHE_S3_*` and the D6 limits in `config/runtime.exs`, refusing to boot when `CACHE_MAX_ENTRY_BYTES` is above 5,363,466,240 or above the project quota, document them in `.env.sample`, and select the fake in `config/test.exs` (design D1). Unit-test that the presigned PUT signs `content-length`, `content-type`, and `x-amz-checksum-sha256` (base64 of the digest), that both URLs carry the configured TTLs, and that neither the S3 module nor its callers log a URL.
- [ ] 2.2 Add a MinIO target (`just` recipe or script) for local development and the smoke test in task 7.2.

## 3. Cache keys

- [ ] 3.1 Add the `add_cache_columns_to_api_keys` migration (`project_id` with `on_delete: :delete_all`, `scope`, and check constraints that tie both to the cache types) and the `:cache_read` / `:cache_write` types with the `ck_` prefix (design D5). Keep `can_write?/1` true only for `:private`. Add `ApiKey.cache_access/4` and unit-test every row of the D5 table, including a bound read key and the default-branch scope.
- [ ] 3.2 Make `ApiAuth`'s default clause return `403` for cache keys and add `ApiAuth, :allow_cache_keys`. Verify a `ck_` key gets `403` on `GET /api/v1/projects`, `GET /api/v1/me`, a workflow-run list, a test-report upload, and the cache-key routes, and that `sk_` and `pk_` behavior on existing routes is unchanged (existing suites pass untouched).
- [ ] 3.3 Add `CacheKeyController.create`, `index` and `delete` on the project write scope (design D5). `create` takes `access`, `scope`, `ttl_seconds` per the D5 lifetime table, and `name`, and shows the token once. `null` means no expiry and is allowed only for `read` with a `name`. `index` lists active cache keys without tokens. `delete` returns `204` on a repeat revoke and `404` for another project's key or a non-cache key. Cover every scenario under "Private keys mint cache keys", "Cache key lifetimes depend on access", "Private keys list cache keys" and "Private keys revoke cache keys", including a non-expiring read key that still works after the sweep runs, and a read key bound to a scope.
- [ ] 3.4 Filter `Accounts.list_api_keys/1` (or the `ApiKeyLive.Index` query) to `:public` and `:private` keys so minted cache keys don't appear in the dashboard (design D9). Verify with a LiveView test that a minted key's row is absent.

## 4. Entries

- [ ] 4.1 Add the `create_cache_entries` migration and `GoodFlows.Caches.Entry` (design D2): columns, the state check constraint, the composite project FK with `ON DELETE CASCADE`, the indexes, `cache_object_deletions`, and the `AFTER DELETE` trigger. Verify `mix ecto.migrate && mix ecto.rollback && mix ecto.migrate`, and in `CreateProjectsMigrationTest` roll the new migrations down before `projects` and up after it. Test that deleting an entry, a project, and an account each queues the object key once.
- [ ] 4.2 Implement `Caches.lookup_key/4` and `Caches.lookup_partial/4` with the D4 lookup order and the throttled `last_accessed_at` update. Context tests must cover each lookup-order scenario, a reservation being invisible, a newer default-branch entry not beating the requested scope, equal `committed_at` ordered by id, and the one-hour throttle on both sides of the boundary.
- [ ] 4.3 Implement `Caches.reserve/5` (design D6): project row lock, expired-reservation replacement, the `409` slot check, LRU eviction over bytes and entry count, `507` when reservations fill the quota, `413` above the entry cap. Tests: concurrent reservations of one key (one `201`), concurrent reservations that together exceed the quota (no overrun), eviction order across scopes, the entry at exactly 5,000,000,000 bytes and `413` at 5,000,000,001, a superseded rolling-cache entry evicted before an older entry that was restored more recently, the same key in another scope, and `507` leaving committed entries untouched.
- [ ] 4.4 Implement `Caches.commit/3`: `404` for unknown, expired, or another key's upload; idempotent `200` for this key's committed upload; `HEAD` checks for existence, length and checksum, with `422` deleting the reservation; then commit. Test each outcome against the fake store, including a missing checksum header from `HEAD` (`422`).
- [ ] 4.5 Implement `Caches.list/3` (keyset with `KeysetCursor`, `name` and `scope` filters, usage), `Caches.delete/3` (one key in one scope), and `Caches.delete_matching/2` (at least one filter). Test counts, `0` deletions, and that purged entries vanish from lookups.

## 5. HTTP

- [ ] 5.1 Add the `:api_cache_authenticated` and `:cache_access` pipelines, `RequireCacheAccess` (`403` for `pk_` and other-project `ck_` keys, then `503` without a bucket), and the routes in design D8. Verify route order so `/caches/entries` and `/caches/entries/:key` resolve per method.
- [ ] 5.2 Add `CacheEntryController` (`show`, `lookup`, `reserve`, `index`, `delete`, `delete_matching`), `CacheUploadController.commit`, and their JSON views. Controller tests must cover every scenario in the `cache-storage` delta, including the per-scope `403`s from D5, `404` for a malformed path key or `upload_id`, `422` on query and body fields, `415` on a non-JSON reserve, and `401` for missing, expired, and revoked keys.
- [ ] 5.3 Hygiene: a sentinel placed in the fake store's signature never appears in logs at `:debug`, error bodies, or `Sentry.Context.get_all()`. Add cache routes to `SentryScrubber`'s response scrubbing.

## 6. Sweep and operations

- [ ] 6.1 Add `Caches.SweepScheduler` and the PgFlow `Caches.SweepJob` (design D7), started in `application.ex` next to `Spry.ReaperScheduler`. Test expiry, retention eviction, cache-key cleanup at 7 days, batch limits, idempotent object deletion (`404` from the store clears the row), and that a failed delete stays queued.
- [ ] 6.2 Against MinIO and a Cloudflare R2 test bucket, confirm that a 5,000,000,000-byte PUT succeeds through a presigned URL, a PUT with a wrong body is rejected, a PUT without the signed headers is rejected, and `HEAD` with checksum mode returns `x-amz-checksum-sha256`. Record the results in the PR description. Do not enable caches in production until both pass. Production uses R2 (design D1).

## 7. Documentation and integration

- [ ] 7.1 Add the OpenAPI schemas and responses from design D10 and the cache section of the `api_spec.ex` description (scopes, key types, presigned URL handling, the rule never to send `Authorization` to a presigned URL). Verify with `openapi_test.exs`.
- [ ] 7.2 Run an end-to-end smoke test against a local server with MinIO: create a project, mint a bound `ck_` key, reserve, PUT with `curl` using `upload_headers`, commit, restore by exact key and by partial from a second scope (fallback), purge by name, and revoke the key. Add it to `scripts/` next to `e2e-cli-smoke.sh` and record the commands in the PR description for the goodflows companion.
- [ ] 7.3 Run `mix precommit` and verify it passes.
- [ ] 7.4 After this change is archived, edit the canonical `openspec/specs/projects/spec.md` purpose to mention the default branch and that caches are deleted with a project. A MODIFIED delta cannot change Purpose.
