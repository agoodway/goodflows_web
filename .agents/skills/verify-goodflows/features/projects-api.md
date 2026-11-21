# Projects API

An API client authenticated with a dashboard-created key manages the account's projects through `/api/v1/projects`: create a project by slug, list and read projects, change the default branch, and delete one. Public keys can only read.

## Sub-features

- `projects-create` creates a project from `{"slug": …}`, with `default_branch` defaulting to `main`.
- `projects-list` lists the account's projects ordered by slug.
- `projects-show` reads one project at `/api/v1/projects/<slug>`.
- `projects-update` changes only `default_branch`. The slug cannot be renamed.
- `projects-delete` removes a project, after which reads return 404.
- `projects-validation` rejects an invalid or duplicate slug with 422.
- `projects-public-readonly` returns 403 to a `pk_` key on every write.

## How to get to it (user POV)

- Send HTTP requests to `$GF_URL/api/v1/projects…` with `Authorization: Bearer <key>`.
- Browse the endpoints and their schemas in Swagger UI at `$GF_URL/api/v1/docs`.

## Driving it with control-goodflows

Preconditions:

- Baseline state.
- A private key was created through the dashboard as in [API keys](./api-keys.md), and its token is exported as `GF_API_KEY`.

- **Create.** Run `$C api project-create POST /api/v1/projects '{"slug":"verify-proj"}'`. The result is HTTP 201 with `data.slug` set to `verify-proj` and `default_branch` set to `main`.
- **Duplicate.** Run the same request as `project-duplicate`. The result is HTTP 422 with `slug: has already been taken by another project in this account`, and no second row exists.
- **Invalid slug.** Run `$C api project-invalid POST /api/v1/projects '{"slug":"Not Valid"}'`. The result is HTTP 422 with the slug rule in the error.
- **List and show.** Run `$C api project-list GET /api/v1/projects` and `$C api project-show GET /api/v1/projects/verify-proj`. Both return 200, and the list contains `verify-proj`.
- **Update.** Run `$C api project-update PATCH /api/v1/projects/verify-proj '{"default_branch":"trunk"}'`. The result is HTTP 200 with `default_branch` set to `trunk`.
- **No rename.** Run `$C api project-rename PATCH /api/v1/projects/verify-proj '{"slug":"renamed"}'`. The result is HTTP 422 with `slug: is not allowed`.
- **Delete.** Run `$C api project-delete DELETE /api/v1/projects/verify-proj`, then `$C api project-gone GET /api/v1/projects/verify-proj`. The delete returns 204 with an empty body and the read returns 404 `Not Found`.
- **Public key.** With a `pk_` key exported, `$C api public-write POST /api/v1/projects '{"slug":"verify-public"}'` returns 403 `Forbidden - insufficient permissions` and `$C api public-read GET /api/v1/projects` returns 200.
- **Proof.** Run `$C db "select slug, default_branch from projects order by slug" projects-api/db-rows.txt` after the update and again after the delete. Keep every `api/project-*` file.

## Gotchas

- Slugs are 1 to 64 bytes of lowercase letters, digits, `_`, and `-`, starting with a letter or digit. Uppercase or spaces return 422.
- `$C api` writes an empty `.json` file for a 204 response. The `.status` file is the proof.
- Projects are scoped to the key's account. A key made while the dashboard showed Globex Industries cannot see Acme Corp's projects, so note which account the key belongs to (`GET /api/v1/me`).
- The API requires `content-type: application/json` on writes. `$C api` sets it whenever a body is given.
- With an `sk_` key and an existing project, cache endpoints under `/caches` return 503 `Remote caches are not configured on this server`, because launch configures no cache bucket. Report them as unreachable rather than failing them, unless the run set the `CACHE_S3_*` variables (see `app/scripts/minio.sh`). A `pk_` key gets 403 before the bucket check, and `/cache-keys` works without a bucket (200).
