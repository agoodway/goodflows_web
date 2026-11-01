# Proposal

## Why

Recipes are unique per account, while the work they run is named by a project. A project needs its own row so two projects in one account can keep the same sprite-name template, and so later records can point at that row instead of copying a slug.

## What Changes

- Add account-owned projects. A project has an id and a slug. The slug is unique per account and uses the 1–64 byte `[a-z0-9][a-z0-9_-]*` rule.
- Add `POST /api/v1/projects`, `GET /api/v1/projects`, `GET /api/v1/projects/:project`, and `DELETE /api/v1/projects/:project`. There is no rename. Delete returns `409` while any recipe belongs to the project.
- **BREAKING** Move recipe create, list, show, replace, and delete under `/api/v1/projects/:project/recipes`. Remove the unscoped `/api/v1/recipes` routes. There is no compatibility alias.
- **BREAKING** Move run start and the per-recipe run list to `/api/v1/projects/:project/recipes/:id/runs`. `GET /api/v1/runs/:id` stays account-scoped.
- A recipe belongs to a project row through `project_id`. Uniqueness becomes `(project_id, name)`. The recipe does not store a copy of the slug. The response includes `project_id` and `project` (the slug).
- The URL slug must name a project of the authenticated account. An invalid slug is `422`. A well-formed slug with no project row is `404` and does not create a project. A body field named `project` on a recipe is rejected.
- Keep the one-active-run guard on the account and the resolved sprite name. Sprite VMs still belong to the account's Sprites credential.
- Run responses include `project`, the slug of the run's recipe's project (null once the recipe is deleted), so a client can build the recipe URL from a run.

## Capabilities

### New Capabilities

- `projects`: Account-owned project records addressed by slug, with create, list, show, and delete.

### Modified Capabilities

- `spry-recipes`: A recipe belongs to a project row. Name uniqueness, nested paths, the returned resource, and a missing project follow that association.
- `spry-runs`: Starting a run and listing a recipe's runs resolve the URL slug to the recipe's project row. Fetching one run by id does not. Run responses include the recipe's project slug (`project`, null once the recipe is deleted), derived through the recipe and not stored. Sprite admission stays account-scoped, and projects do not isolate sprites: same-named templates in different projects drive the same VM.

## Impact

- New `projects` table and `recipes.project_id` foreign key. Existing recipe rows have no project; the migration does not invent one.
- `GoodFlows.Projects`, the recipe schema and JSON render, recipe and project controllers, run start and list, the router, OpenAPI, and the API overview.
- `store-test-timings` depends on this table and stores `project_id`. This change does not write test reports. Apply this change first.
- No display name, no project rename, and no foreign key from runs to projects.
