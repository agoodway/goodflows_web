---
paths:
  - "app/lib/good_flows_web/controllers/api/v1/project_controller.ex"
  - "app/lib/good_flows_web/controllers/api/v1/project_json.ex"
  - "app/lib/good_flows_web/schemas/project*.ex"
  - "app/lib/good_flows_web/plugs/load_project.ex"
  - "app/lib/good_flows/projects.ex"
  - "app/lib/good_flows/projects/**"
  - "app/test/good_flows_web/controllers/api/v1/project_controller_test.exs"
  - "app/test/good_flows/projects_test.exs"
---

# Projects API

An API client authenticated with a dashboard-created key manages the account's projects through `/api/v1/projects`: create a project by slug, list and read projects, change the default branch, and delete one. Writes need a private key of an account owner or admin: public keys and plain members' private keys can only read. The same projects are managed in the dashboard, see [Projects page](./projects-page.md).

## Sub-features

- `projects-create` creates a project from `{"slug": …}`, with `default_branch` defaulting to `main`.
- `projects-list` lists the account's projects ordered by slug.
- `projects-show` reads one project at `/api/v1/projects/<slug>`.
- `projects-update` changes only `default_branch`. The slug cannot be renamed.
- `projects-delete` removes a project, after which reads return 404. It is refused with 409 while the project has recipes, test reports, workflow runs, change requests, or verify runs.
- `projects-validation` rejects an invalid or duplicate slug, or an empty `default_branch`, with 422.
- `projects-public-readonly` returns 403 to a `pk_` key on every write.
- `projects-member-readonly` returns 403 to a plain member's `sk_` key on create, update, and delete, and 200 on reads.

## How to get to it (user POV)

- Send HTTP requests to `$GF_URL/api/v1/projects…` with `Authorization: Bearer <key>`.
- Browse the endpoints and their schemas in Swagger UI at `$GF_URL/api/v1/docs`.

## Driving it with control-goodflows

Preconditions:

- Baseline state.
- A private key was created through the dashboard **while it showed Acme Corp** (where the seeded user is owner), as in [API keys](./api-keys.md), and its token is exported as `GF_API_KEY`. `GET /api/v1/me` reports `role` `owner`.

- **Create.** Run `$C api project-create POST /api/v1/projects '{"slug":"verify-proj"}'`. The result is HTTP 201 with `data.slug` set to `verify-proj` and `default_branch` set to `main`.
- **Duplicate.** Run the same request as `project-duplicate`. The result is HTTP 422 with `slug: has already been taken by another project in this account`, and no second row exists.
- **Invalid slug.** Run `$C api project-invalid POST /api/v1/projects '{"slug":"Not Valid"}'`. The result is HTTP 422 with `slug: must be 1 to 64 bytes of lowercase letters, digits, `_`, and `-`, starting with a letter or digit`. `$C api project-bad-branch PATCH /api/v1/projects/verify-proj '{"default_branch":""}'` returns 422 with `default_branch: can't be blank`.
- **List and show.** Run `$C api project-list GET /api/v1/projects` and `$C api project-show GET /api/v1/projects/verify-proj`. Both return 200, and the list contains `verify-proj`.
- **Update.** Run `$C api project-update PATCH /api/v1/projects/verify-proj '{"default_branch":"trunk"}'`. The result is HTTP 200 with `default_branch` set to `trunk`.
- **No rename.** Run `$C api project-rename PATCH /api/v1/projects/verify-proj '{"slug":"renamed"}'`. The result is HTTP 422 with `slug: is not allowed`.
- **Blocked delete.** Run `$C api recipe-create POST /api/v1/projects/verify-proj/recipes '{"name":"verify-recipe"}'` (201), then `$C api project-delete-blocked DELETE /api/v1/projects/verify-proj`. The result is HTTP 409 `The project still has recipes; delete them first` and the project remains. Delete the recipe with `$C api recipe-delete DELETE /api/v1/projects/verify-proj/recipes/<recipe id>` (204).
- **Delete.** Run `$C api project-delete DELETE /api/v1/projects/verify-proj`, then `$C api project-gone GET /api/v1/projects/verify-proj`. The delete returns 204 with an empty body and the read returns 404 `Not Found`.
- **Public key.** With a `pk_` key exported, `$C api public-write POST /api/v1/projects '{"slug":"verify-public"}'` returns 403 `Forbidden - insufficient permissions` and `$C api public-read GET /api/v1/projects` returns 200.
- **Member key.** Switch the dashboard to Globex Industries (see [Account dashboard](./account-dashboard.md)), create a private key there, and export it. `$C api member-me GET /api/v1/me` reports `role` `member`. `$C api member-read GET /api/v1/projects` returns 200, and lists the seeded `globex-api`. `$C api member-create POST /api/v1/projects '{"slug":"member-try"}'`, `$C api member-update PATCH /api/v1/projects/globex-api '{"default_branch":"trunk"}'`, and `$C api member-delete DELETE /api/v1/projects/globex-api` each return 403 `Forbidden - insufficient permissions`. `$C db "select slug, default_branch from projects order by slug" projects-api/db-member.txt` still shows only `globex-api|main`.
- **Proof.** Run `$C db "select slug, default_branch from projects order by slug" projects-api/db-rows.txt` after the update and again after the delete. Keep every `api/project-*` file.

## Gotchas

- Slugs are 1 to 64 bytes of lowercase letters, digits, `_`, and `-`, starting with a letter or digit. Uppercase or spaces return 422.
- `$C api` writes an empty `.json` file for a 204 response. The `.status` file is the proof.
- Projects are scoped to the key's account. A key made while the dashboard showed Globex Industries cannot see Acme Corp's projects, and as a member's key it cannot write at all, so check `account.name` and `role` with `GET /api/v1/me`.
- For a member's key, PATCH or DELETE of a project that does not exist returns 404 (or 422 for an invalid slug) before the role check. Use the seeded `globex-api` to reach the 403.
- Send `content-type: application/json` on writes; `$C api` sets it whenever a body is given. An unparseable content type returns 415.
- With an `sk_` key and an existing project, cache endpoints under `/caches` return 503 `Remote caches are not configured on this server`, because launch configures no cache bucket. Report them as unreachable rather than failing them, unless the run set the `CACHE_S3_*` variables (see `app/scripts/minio.sh`). A `pk_` key gets 403 before the bucket check, and `/cache-keys` works without a bucket (200).
