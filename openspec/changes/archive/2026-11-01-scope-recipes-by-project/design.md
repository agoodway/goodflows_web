# Design

## Context

See proposal.md for motivation. Recipes live in `recipes` with `belongs_to :account` and a unique index on `(account_id, name)`. `GoodFlows.Spry` takes an account and scopes every recipe query by `account_id`. The router serves CRUD at `/api/v1/recipes` and run start/list at `/api/v1/recipes/:id/runs`. `GET /api/v1/runs/:id` loads a run by id. One Sprites credential belongs to the account, and the one-active-run guard is `(account, resolved sprite name)`.

There is no `projects` table. `store-test-timings` will store `project_id` once this table exists. Apply this change first. This change does not write test reports.

## Goals / Non-Goals

**Goals:**

- Persist a project as its own row, and make every recipe belong to one.
- Resolve the URL slug to that row for recipe and nested run routes.
- Keep sprite admission account-wide, because the VM lives in the account's Sprites org.

**Non-Goals:**

- A display name or a rename route. The slug is the public name.
- Copying `project` onto runs. `GET /api/v1/runs/:id` stays account-scoped and survives recipe deletion as it does today. Run responses render the project slug through the recipe (D4), but no runs column stores it.
- A compatibility alias for `/api/v1/recipes`.
- The test-report foreign key. `store-test-timings` adds that after this table exists.

## Decisions

### D1. Project is a schema

Add `GoodFlows.Projects.Project` and `GoodFlows.Projects`. The table is `projects`: UUID id, `account_id` referencing `accounts` with `on_delete: :delete_all`, `slug` as `text` `null: false`, and `timestamps(type: :utc_datetime_usec)`. Unique index on `[:account_id, :slug]`.

The slug is 1–64 UTF-8 bytes (`validate_length(:slug, min: 1, max: 64, count: :bytes)`) and matches `~r/\A[a-z0-9][a-z0-9_-]*\z/`. Use `\A…\z`, as `GoodFlows.Spry.Template` does, so `"abc\n"` is rejected. `Project.changeset/2` enforces that and the unique constraint. `Project.valid_slug?/1` exposes the same rule, so `LoadProject` and `store-test-timings` share it. `Project` has `has_many :recipes`. Responses use the recipe envelope: `{data: {id, slug, inserted_at, updated_at}}` for one project, `{data: [...]}` for a list, and no `account_id`.

`GoodFlows.Projects` exposes `list_projects/1` (ordered by slug), `get_project/2` (`account, slug` → `{:ok, %Project{}}` or `{:error, :not_found}`), `create_project/2`, and `delete_project/2`. The web layer adds `ProjectController`, `ProjectJSON`, and the `GoodFlowsWeb.Schemas` modules `Project`, `ProjectRequest`, `ProjectResponse`, and `ProjectListResponse`.

`POST /api/v1/projects` takes `%{"slug" => ...}` and creates the row for the authenticated account. `GET /api/v1/projects` lists that account's projects ordered by slug. `GET` and `DELETE /api/v1/projects/:project` address the slug. There is no update route.

`delete_project/2` returns `{:error, :has_recipes}` when any recipe has that `project_id`. It does not delete recipes. An empty project is deleted. The delete runs `Repo.delete/1` on a changeset with `no_assoc_constraint(:recipes)`, so a recipe committed between a pre-check and the delete still maps to `{:error, :has_recipes}` and not a raised `Ecto.ConstraintError`. `FallbackController` gains a `{:error, :has_recipes}` clause that renders `409` with `errors.detail`. The OpenAPI `DELETE /projects/{project}` documents `409` with `ConflictResponse`, whose moduledoc is generalised beyond recipes. The recipe foreign key uses `on_delete: :nothing` (`NO ACTION`), so a direct SQL delete cannot remove a project out from under its recipes, and the constraint name stays `recipes_project_id_fkey` for `no_assoc_constraint`. `NO ACTION` rather than `RESTRICT`: an account delete cascades to both `projects` and `recipes`, and `NO ACTION` checks at the end of the statement, so it succeeds whichever cascade fires first. `RESTRICT` would only work by trigger firing order, which a dump and restore could flip.

Reads accept any API key. Create and delete require a private key. Another account's slug is `:not_found`.

Alternative considered: store the slug only on `recipes`. Rejected. A project other records can reference needs a row and an id.

### D2. The path loads the project row

`GoodFlowsWeb.Plugs.LoadProject` runs only on scopes whose path contains `:project`, after the route has matched. It is the last plug in those pipelines, after `:api_authenticated` (which sets `current_account`) and after `:api_write` on write scopes. Auth and permission errors (`401`, `403`) therefore come before slug errors. A `pk_` write to a missing or invalid project is `403`. It validates `conn.path_params["project"]` with `Project.valid_slug?/1`. An invalid slug halts with `422` through `GoodFlowsWeb.ChangesetJSON` (`errors.project`) and does not query. A valid slug calls `Projects.get_project/2`. It either assigns the `%Project{}` to `:project` or halts with `404` when no row exists. Missing projects are not created by a recipe or run request.

`Recipe.changeset/2` rejects a body key `project` on create and replace, the same way `validate_no_org/2` rejects `org`. Controllers keep passing `conn.body_params`, not `conn.params`, so the path `project` param never trips this rule. `create_recipe/3` sets `project_id` and `account_id` from the loaded project, not from attrs. It also adds `foreign_key_constraint(:project_id)`, so a project deleted after `LoadProject` ran maps to `{:error, :not_found}` (`404`) and not a raised error. Replace does not cast `project_id`, and a body `project_id` is ignored.

### D3. Uniqueness is `(project_id, name)`

Add `recipes.project_id` as a required composite foreign key `(project_id, account_id)` referencing `projects (id, account_id)` with `on_delete: :nothing` (`NO ACTION`, see D1): `references(:projects, column: :id, with: [account_id: :account_id], type: :binary_id, on_delete: :nothing)`, backed by a unique index on `projects [:id, :account_id]`. Keep `recipes.account_id`. On create, set `account_id` from `project.account_id`; the composite key makes the database reject any recipe whose account differs from its project's. The constraint is still named `recipes_project_id_fkey`, so `foreign_key_constraint(:project_id)` and `no_assoc_constraint(:recipes)` keep that name. Drop `recipes_account_id_name_index`, add a plain index on `[:account_id]` so account-scoped lookups and the account cascade stay indexed, and add a unique index on `[:project_id, :name]`. Point `unique_constraint(:name, ...)` at that index and say the name is taken in this project. Update the remaining "unique per account" wording in the `Recipe` moduledoc, the `RecipeRequest` description, and the `ApiSpec` overview.

`list_recipes/2`, `get_recipe/3`, `replace_recipe/4`, and `delete_recipe/3` take the `%Project{}` and filter on `project_id` and `account_id`. A recipe that exists under another project is `:not_found`. The context returns recipes with the `project` association set from the `%Project{}` it was given (`%{recipe | project: project}`), with no extra query. `RecipeJSON` renders `project_id` plus `project` (`recipe.project.slug`) and does no Repo calls; a recipe without its project set raises a descriptive `ArgumentError` rather than a `FunctionClauseError`.

`request_run/5` (`account, project, recipe_id, params, opts \\ []`) and `list_runs/4` (`account, project, recipe_id, params \\ %{}`) insert the project after the account. Both load the recipe through `get_recipe/3`, and so does a dry run. Wrong project returns `:not_found` before admission, the credential lookup, or any Sprites call, so no run row is inserted. `delete_recipe/3` also calls `get_recipe/3` first and then `lock_recipe(account, recipe.id)`. Today it calls `lock_recipe/2` directly. `lock_recipe/2` stays account-and-id; only a project-matching caller reaches it. `project_id` never changes, so checking before the lock is safe.

### D4. Sprite admission stays on the account

Do not add `project_id` to the active-run lookup or to the runs table. Two recipes in different projects that expand to the same sprite name still conflict with `409` and `active_run_id`.

Projects do not isolate VMs. Sprite names are global to the account's Sprites credential, so same-named recipe templates in different projects drive the same sprite, and one project's `teardown` can destroy a VM another project set up. The guard only blocks overlapping runs. Sprite naming does not change in this change; the `Recipe` moduledoc and the `ApiSpec` caveats state the risk. Sprite names are also global to the Sprites token itself, so two accounts storing one token, or the `spry` CLI using it, can collide the same way. That risk predates this change.

Run responses carry `project`, the slug of the run's recipe's project, so a client can build `/api/v1/projects/{project}/recipes/{recipe_id}` from a run. It is derived, not stored: `request_run/5` and `list_runs/4` set the run's `recipe` association from the recipe they loaded (whose `project` is already set), with no query per run, and `get_run/2` preloads `[:steps, recipe: :project]` (a fixed number of queries). `RunJSON` reads `run.recipe.project.slug` with no Repo call. `project` is `null` once the recipe is deleted, like `recipe_id`; a run whose `recipe_id` is set but whose recipe is not loaded raises `ArgumentError`. `GoodFlowsWeb.Schemas.Run` documents `project` as a nullable string.

### D5. Router split

Leave `/me`, `/runs/:id`, and `/sprites-credential` on the existing pipelines. Add project collection routes on those pipelines:

```
GET    /api/v1/projects
POST   /api/v1/projects
```

Put show, delete, and the nested recipe and run routes in scopes that add `:load_project` last: reads use `pipe_through [:api, :api_authenticated, :load_project]`, writes use `[:api, :api_authenticated, :api_write, :load_project]`:

```
GET    /api/v1/projects/:project
DELETE /api/v1/projects/:project
GET    /api/v1/projects/:project/recipes
GET    /api/v1/projects/:project/recipes/:id
GET    /api/v1/projects/:project/recipes/:id/runs
POST   /api/v1/projects/:project/recipes
PUT    /api/v1/projects/:project/recipes/:id
DELETE /api/v1/projects/:project/recipes/:id
POST   /api/v1/projects/:project/recipes/:id/runs
```

Delete the seven unscoped recipe and recipe-run routes. Document the project and nested operations in OpenAPI and in `GoodFlowsWeb.ApiSpec`.

`SpryFixtures.project_fixture(account, attrs \\ %{})` always inserts a project from `attrs` (default slug `"project-<n>"`, unique per call) and raises on a duplicate slug or invalid attrs; it never reuses an existing project. Tests build paths from `project.slug`. `recipe_fixture(%Project{} = project, attrs \\ %{})` takes the project explicitly. `start_run(account, project, recipe_id, params, opts \\ [])` and `dry_run(account, project, recipe_id, params)` take the project and pass it through to Spry.

## Risks / Trade-offs

- [Existing clients call `/api/v1/recipes`] → Breaking move with no alias. Unscoped paths are `404`.
- [Two projects surprise each other with `409` on one sprite name] → The conflict body already names `active_run_id`. The spec requires this.
- [A database already has recipes] → The migration refuses to invent a project. See the migration plan.
- [Rollback of the unique index] → `down` cannot restore `(account_id, name)` while two projects of one account share a recipe name. It checks first and raises `Ecto.MigrationError` naming the duplicates, changing nothing. Roll the app and the migration back together, and rename or delete the duplicates first.
- [Same sprite name across projects] → Projects share the account's Sprites namespace, so one project's teardown can destroy another's VM (D4). Documented, not prevented.
- [Project delete and test reports] → This change only blocks delete when recipes exist. `store-test-timings` must also block delete when reports exist, with `ON DELETE RESTRICT` as the backstop.

## Migration Plan

One new migration. Do not edit `20261101180000_create_recipes.exs`.

`up` creates `projects` with unique indexes on `[:account_id, :slug]` and `[:id, :account_id]`. If `recipes` has any row, it raises `Ecto.MigrationError` and tells the operator to delete or export the existing recipes, or to run a backfill migration that creates projects and assigns recipes first; projects cannot be assigned before this migration creates the table. This change does not pick a slug. It then adds `project_id` `NOT NULL` as the composite `(project_id, account_id)` foreign key with `ON DELETE NO ACTION`, drops the old unique index, adds a plain `[:account_id]` index, and creates the `[:project_id, :name]` unique index. An empty `recipes` table migrates with no backfill.

`down` first raises `Ecto.MigrationError` if any account has two recipes with the same name. Otherwise it drops the `[:project_id, :name]` index and the `project_id` column (and its foreign key), drops the `[:account_id]` index, restores the `(account_id, name)` unique index, and drops `projects`. The migration's moduledoc states both guards.

A migration test runs `Ecto.Migrator` down to this version and up again inside the sandbox transaction (`async: false`, `migration_lock: false`): it asserts that `up` raises with a recipe present, that `up` then succeeds once it is gone, and that `down` raises on duplicate names. The sandbox rollback leaves the test database fully migrated.

Deploy the migration and the route change together. Apply this change before `store-test-timings`.

## Open Questions

None.
