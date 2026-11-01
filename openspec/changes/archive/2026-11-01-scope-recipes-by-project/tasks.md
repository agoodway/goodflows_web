# Tasks

## 1. Project schema

- [x] 1.1 Add one migration for `projects` (`account_id` delete-cascade, `slug`, unique per account) and `recipes.project_id` `NOT NULL` as a composite `(project_id, account_id)` foreign key referencing `projects (id, account_id)` (unique index on `projects [:id, :account_id]`) with `ON DELETE NO ACTION`. If `recipes` is non-empty, raise `Ecto.MigrationError` telling the operator to delete or export the recipes or run a backfill migration first, and do not invent a project. Drop `recipes_account_id_name_index`, add an `[:account_id]` index, and create a unique index on `[:project_id, :name]`. `down` raises `Ecto.MigrationError` while an account has duplicate recipe names, and otherwise reverses every step. Do not edit `20261101180000_create_recipes.exs`. Add `GoodFlows.Projects.Project` (`has_many :recipes`, `valid_slug?/1`, slug rule `~r/\A[a-z0-9][a-z0-9_-]*\z/` with a 1–64 byte length) and `GoodFlows.Projects` (`list_projects/1` ordered by slug, `get_project/2`, `create_project/2`). Verify that an empty test database migrates and rolls back, with a migration test (`Ecto.Migrator` down and up in the sandbox) covering the `up` guard with a recipe present and the `down` duplicate-name guard. Verify these project context tests:
  - create
  - a duplicate slug returns an error changeset on `slug`
  - the same slug on another account
  - invalid slugs, including `"abc\n"`
  - list is limited to the account and ordered by slug
  - show of another account's slug is `:not_found`
  - `valid_slug?/1` accepts 64 bytes and rejects 65
  - deleting an already-deleted project is `:not_found`
  - deleting an account removes its projects, recipes, and finished runs
  - the database rejects a recipe whose account differs from its project's, and a direct delete of a project with recipes

  Existing recipe inserts fail until task 2.1.
- [x] 1.2 Add `POST`, `GET`, `GET :project`, and `DELETE /api/v1/projects` through `ProjectController`, `ProjectJSON`, and `GoodFlowsWeb.Schemas.Project`/`ProjectRequest`/`ProjectResponse`/`ProjectListResponse`. Include OpenAPI and the private-key write rule. Responses are `{data: ...}` without `account_id`. `GoodFlowsWeb.Plugs.LoadProject` runs last in its pipelines, after `:api_authenticated` and `:api_write`. It validates the path slug with `Project.valid_slug?/1` (`422` through `ChangesetJSON`) and assigns the account's project or returns `404`. Add a `FallbackController` clause for `{:error, :has_recipes}` that returns `409`. Generalise the `ConflictResponse` moduledoc and document it on project delete. There is no update route. Verify these controller tests:
  - create returns `201`
  - list returns projects ordered by slug
  - show returns `200`
  - deleting an empty project returns `204`, and a later show returns `404`
  - `pk_` create returns `403`, `pk_` delete returns `403`, and `pk_` list returns `200`
  - an invalid path slug returns `422`
  - another account's project returns `404`
  - a 64-byte slug is served and a 65-byte path slug is `422`
  - project-scoped routes without a Bearer token return `401`

## 2. Recipes belong to a project

- [x] 2.1 Add `belongs_to :project` on `GoodFlows.Spry.Recipe`. Reject a body key `project` on create and replace. Point `unique_constraint(:name, ...)` at `(project_id, name)`, and add `foreign_key_constraint(:project_id)` mapped to `:not_found`. Change recipe reads and writes to take the `%Project{}`, set `account_id` from that project, filter on `project_id`, and return recipes with the `project` association set from the given struct. Replace does not cast `project_id`. `delete_recipe/3` calls `get_recipe/3` before `lock_recipe/2`. `delete_project/2` uses `no_assoc_constraint(:recipes)` and returns `{:error, :has_recipes}` when any recipe exists. Update the "unique per account" wording in the `Recipe` moduledoc and constraint message. Thread the project through `request_run/5` and `list_runs/4` into `get_recipe/3`. Update `SpryFixtures` so the project compiles: `project_fixture(account, attrs \\ %{})` always inserts (unique default slug, raises on a duplicate), `recipe_fixture(%Project{}, attrs \\ %{})` takes the project, and `start_run`/`dry_run` take the project. Then update the controllers and the Spry tests. Verify these schema and context tests:
  - body rejection of `project` on create and replace
  - the same name in another project
  - the same name in the same project
  - another project's recipe is `:not_found` for show, replace, and delete
  - a wrong-project delete keeps the recipe
  - replace keeps `project_id`
  - project delete returns `409` while a recipe remains
- [x] 2.2 A project mismatch on `request_run`, including a dry run, or on `list_runs` returns `:not_found` before admission, the credential lookup, or any Sprites call, and inserts no run. Do not add `project_id` to the runs table or to the active-run lookup. `lock_recipe/2` stays account-and-id. Verify these runs-context tests:
  - the same resolved sprite name under another project is `409` with `active_run_id`
  - a wrong-project dry run is `:not_found`
  - `concurrency_test.exs` still passes

## 3. Nested HTTP routes

- [x] 3.1 Move recipe CRUD and recipe run start/list under `/api/v1/projects/:project/...`. Reads use `[:api, :api_authenticated, :load_project]`, and writes use `[:api, :api_authenticated, :api_write, :load_project]`. Delete the seven unscoped `/api/v1/recipes` routes. Leave `/me`, `/runs/:id`, and `/sprites-credential` on their current pipelines. Verify these controller tests:
  - a valid slug with no project returns `404` for recipe create and list, and for run start and list, and creates no run
  - `200` with an empty recipe list when the project exists and has none
  - an invalid slug `GoodCases` on recipe list and on run start returns `422` with `errors.project` and stores nothing
  - a `pk_` write to a missing project returns `403`
  - `GET /api/v1/recipes`, `POST /api/v1/recipes`, `GET /api/v1/recipes/:id/runs`, and `POST /api/v1/recipes/:id/runs` return `404`. Unmatched routes raise `Phoenix.Router.NoRouteError` in `ConnCase`, so use `assert_error_sent 404`.
- [x] 3.2 Include `project_id` and `project` (the slug) in `RecipeJSON` and `GoodFlowsWeb.Schemas.Recipe`, rendered from the set association with no Repo call (a recipe without it raises `ArgumentError`). Add `project` (nullable slug) to `RunJSON` and `GoodFlowsWeb.Schemas.Run`, set from the loaded recipe in `request_run/5` and `list_runs/4` and preloaded in `get_run/2`, with no query per run. `project` is absent from `RecipeRequest`. Update the "unique per account" wording in `RecipeRequest`. Update the OpenAPI path parameters and not-found descriptions. Update the overview in `GoodFlowsWeb.ApiSpec`, including a first step that creates a project. Verify recipe and run controller tests on the new paths:
  - `201` returns `project_id` and `project`
  - a body field `project` on create or replace is `422` and stores nothing
  - the same name in two projects is allowed
  - show, replace, delete, start, dry run, and list under another project of the same account are `404`
  - a public key can list and cannot create
  - project delete with a recipe is `409`
  - `GET /api/v1/runs/:id` is unchanged apart from the new `project` field
  - run responses (start, list, show) include `project`, the recipe's project slug, and it is `null` once the recipe is deleted
  - project-scoped recipe routes without a Bearer token return `401`, and a 64-byte project slug lists recipes
  - every project-scoped OpenAPI operation (an explicit list of path and verb) has a required `project` parameter whose description contains `Project.slug_rule()`
  - the generated OpenAPI document has the project and nested paths, and not `/api/v1/recipes` or `/api/v1/recipes/{id}/runs`. Replace the existing `paths["/api/v1/recipes"]` assertions in `recipe_controller_test.exs`.

## 4. Integration check

- [x] 4.1 Run the project, Spry context, recipe controller, and run controller tests, then `mix precommit`, and verify they pass without Sprites calls. Confirm this change does not write `test_reports`. After archiving, set the Purpose of `openspec/specs/projects/spec.md` from this delta. Change the `openspec/specs/spry-recipes/spec.md` Purpose from "per account" to "per project within an account" under `/api/v1/projects/:project/recipes`.
