# Inspector Review-Update — scope-recipes-by-project

**Reviewed:** 2026-11-01
**Reviewer:** inspector-review-update
**Mode:** auto
**Verdict:** Ready to implement (one cross-change follow-up belongs to `store-test-timings`)

## Summary

This change adds account-owned `projects` rows. Recipes move under `/api/v1/projects/:project/recipes`, and recipe name uniqueness changes from `(account_id, name)` to `(project_id, name)`. Sprite admission stays account-wide.

The delta format was already sound: every canonical scenario was kept and the function arities match the code. The review found one real plan bug, now patched: `delete_recipe` would have deleted a recipe through the wrong project. It also patched a project-delete race and closed task coverage gaps.

One issue remains. `store-test-timings` must modify the `projects` delete requirement, because it adds a second reason a project cannot be deleted. That fix belongs in that change.

`openspec validate scope-recipes-by-project --strict` passes after the patches.

**Original counts (raw, both specialists, before dedup):** Critical: 0 · Warning: 12 · Suggestion: 21
**Patches:** Auto-patched: 18 · User-guided: 0 · Model-recommended: 6 · Skipped: 3

## Scope inspected

- Proposal: `openspec/changes/scope-recipes-by-project/proposal.md`
- Design: `openspec/changes/scope-recipes-by-project/design.md`
- Tasks: `openspec/changes/scope-recipes-by-project/tasks.md`
- Deltas:
  - `openspec/changes/scope-recipes-by-project/specs/projects/spec.md`
  - `openspec/changes/scope-recipes-by-project/specs/spry-recipes/spec.md`
  - `openspec/changes/scope-recipes-by-project/specs/spry-runs/spec.md`
- Canonical specs consulted:
  - `openspec/specs/spry-recipes/spec.md`
  - `openspec/specs/spry-runs/spec.md`
  - `openspec/specs/spry-templates/spec.md`
  - `openspec/specs/sprites-credential/spec.md`
- Other active changes consulted: `openspec/changes/store-test-timings/`

## Patches applied

18 findings were auto-patched. 6 were patched from model recommendations. 3 were skipped.

### Auto-patched

1. **Recipe delete skipped the project check.** `design.md` D3 and `tasks.md` 2.1: `delete_recipe/3` now calls `get_recipe/3` before `lock_recipe/2`. A context test now checks that a delete under the wrong project keeps the recipe. Evidence: `app/lib/good_flows/spry.ex:72-74` calls `lock_recipe` directly.
2. **The slug regex accepted a trailing newline.** `design.md` D1 and `specs/projects/spec.md` "Invalid slug": the regex is now `\A…\z` with `count: :bytes`, and `"abc\n"` was added to the invalid scenarios and tests. This matches `app/lib/good_flows/spry/template.ex:15`.
3. **`:has_recipes` had no fallback clause.** `design.md` D1 and `tasks.md` 1.2: added the `FallbackController` `409` clause and generalised the `ConflictResponse` documentation.
4. **The Projects public API had no names.** `design.md` D1 and `tasks.md` 1.1 and 1.2: named `list_projects/1`, `get_project/2`, `create_project/2`, `delete_project/2`, and `Project.valid_slug?/1`, plus the controller, JSON, and schema modules.
5. **The project response shape was unstated.** `specs/projects/spec.md:10` and `design.md` D1: responses are `{data: {id, slug, inserted_at, updated_at}}`, matching `RecipeJSON`.
6. **The route count was wrong.** `design.md` D5 said eight unscoped routes; `router.ex:70-84` has seven. Corrected.
7. **The default arguments were described wrong.** `design.md` D3: the full signatures for `request_run/5` and `list_runs/4` are now stated (`request_run` has no default for `params`).
8. **A test was in the wrong task.** "Missing project creates no run" moved from the context task (2.2) to the HTTP task (3.1), because a missing project is turned away by `LoadProject`, not by the context.
9. **Project show and delete had no tests.** Added to `tasks.md` 1.2: show `200`, delete of an empty project `204` followed by a show `404`, and `pk_` delete `403`.
10. **No scenario for a `pk_` delete.** Added the scenario "Public key cannot delete" to `specs/projects/spec.md`.
11. **An invalid slug on nested routes was untested.** Added the scenario "Invalid project segment" to `specs/spry-runs/spec.md` "Start a run", plus `tasks.md` 3.1 tests for recipe list and run start.
12. **Unscoped-route tests were incomplete.** `tasks.md` 3.1 now tests all four unscoped routes with `assert_error_sent 404`. Task 3.2 now replaces the old OpenAPI path assertions.
13. **The dry run under the wrong project was unspecified.** Added a scenario to `specs/spry-runs/spec.md` "Start a run" and tests to tasks 2.2 and 3.2. The `404` comes before any credential lookup or Sprites call.
14. **The slug error field was unnamed.** `specs/spry-recipes/spec.md` "Project slugs are validated": the `422` now carries an error on `project`.
15. **The uniqueness wording was redundant.** `specs/spry-recipes/spec.md` "unique per project": "Within one account and one project" became "Within one project".
16. **Stale "per account" text in code.** `design.md` D3 and `tasks.md` 2.1 and 3.2 now list the `Recipe` moduledoc and constraint message, the `RecipeRequest` description, and the `ApiSpec` overview, including a new first step that creates a project.
17. **Context tests named HTTP status codes.** `tasks.md` 1.1: "duplicate slug `422`" now reads "returns an error changeset on `slug`".
18. **Canonical Purpose sections go stale on archive.** `tasks.md` 4.1 now includes setting the `projects` Purpose and updating the `spry-recipes` Purpose after archive. A delta cannot change a Purpose.

### Model-recommended patches

1. **Project-delete race and recipe-insert foreign key.** `design.md` D1 and D2, `tasks.md` 2.1
   - **Chose:** `delete_project/2` uses `no_assoc_constraint(:recipes)`, mapped to `{:error, :has_recipes}`. Recipe create adds `foreign_key_constraint(:project_id)`, mapped to `:not_found`.
   - **Rationale:** Both race outcomes become the documented `409` and `404` instead of a raised error (`500`). It is the standard Ecto pattern, and `store-test-timings` can add `:timing_reports` the same way.
2. **Pipeline order for `:load_project`.** `design.md` D2 and D5, `tasks.md` 3.1
   - **Chose:** `:load_project` runs last, after `:api_authenticated` and `:api_write`.
   - **Rationale:** `current_account` must already be set. Auth and permission errors should come before input errors, which matches the existing pipelines. A test now checks that a `pk_` write to a missing project returns `403`.
3. **Fixture signatures.** `design.md` D5 and `tasks.md` 2.1
   - **Chose:** `project_fixture(account, attrs)` gets or creates `goodcases`. `recipe_fixture(%Project{}, attrs)` takes the project explicitly. `start_run` and `dry_run` take the project.
   - **Rationale:** `concurrency_test.exs:79` calls `recipe_fixture` repeatedly for one account. If each call created `goodcases`, the second call would fail the unique slug. Passing the project explicitly matches the context API.
4. **Where `project` gets onto the recipe.** `design.md` D3 and `tasks.md` 3.2
   - **Chose:** The context sets the `project` association from the loaded `%Project{}`. `RecipeJSON` makes no Repo call.
   - **Rationale:** The struct is already loaded by `LoadProject`. Preloading in the view adds a query and puts data access in the view layer.
5. **Project list ordering.** `specs/projects/spec.md` "Project endpoints" and `tasks.md` 1.1 and 1.2
   - **Chose:** The spec now requires ordering by `slug`, as the design already said, and a test checks it.
   - **Rationale:** The design and spec disagreed. Ordering is cheap and makes the API deterministic.
6. **`project` in a replace body.** `specs/spry-recipes/spec.md` "Project is not a recipe body field"
   - **Chose:** Added the scenario "Project supplied on replace" (`422`, recipe unchanged) and a test. A body `project_id` is still ignored.
   - **Rationale:** `PUT` uses the same changeset, so the rule applies there too. Rejecting `project_id` as well would grow scope beyond the proposal.

### Skipped

1. **The two changes contradict each other on project delete.** `specs/projects/spec.md` "A project with recipes cannot be deleted" and `store-test-timings` (`proposal.md:24`, `design.md:72`, `specs/test-timing-storage/spec.md:56`)
   - **The conflict:** This change requires `204` for any project with no recipes. `store-test-timings` returns `409` for a project with timing reports, and its proposal says "Modified Capabilities: None".
   - **Recommended fix (in `store-test-timings`):** add `specs/projects/spec.md` with a RENAMED block ("…with recipes…" → "A project with dependents cannot be deleted") and a MODIFIED block that keeps both existing scenarios and adds a timing-report scenario. List `projects` under Modified Capabilities. Add a task to extend `delete_project/2`, for example with `no_assoc_constraint(:timing_reports)`. Optionally rename `:has_recipes` to `:in_use` at that point.
   - **Why skipped:** This skill only edits files in the target change.
2. **Rename the scenario "Duplicate name in the same account".** `specs/spry-recipes/spec.md:58`
   - **What happened:** I tried the rename, but `openspec validate --strict` treats a renamed scenario inside a MODIFIED block as a dropped canonical scenario. I reverted it.
   - **Status:** The body already says "in project `goodcases`". Rename it in the canonical spec after archive if wanted.
3. **Account delete with RESTRICT (Specialist A).** `design.md` D1
   - **The concern:** Specialist A asked whether a cascading account delete could hit `recipes.project_id ON DELETE RESTRICT`.
   - **Why no change:** Specialist B tested it against Postgres 18 in a rolled-back transaction. The account cascade succeeds whichever foreign key was created first, and no account-delete code path exists today.

## Critical

_None._

## Warning

1. **Missing projects delta in `store-test-timings`.** See Skipped #1. Fix it in that change before archiving either change.
   - It also needs a task to extend `GoodFlows.Projects.delete_project/2` for timing reports (`store-test-timings/tasks.md:13` tests the `409`, but no task implements it).

## Suggestion

_None._

## Alignment notes

- **Other active changes:** `store-test-timings` matches on slug grammar, `project_id` with RESTRICT, and apply order. It conflicts on the project delete rule (see Warning 1).
- **Canonical specs:** Each MODIFIED block keeps every canonical scenario word for word. Unmodified canonical requirements (Org, Host steps, Placeholders, Phase flags, Credential, Dry run, Run status, Snapshots) do not mention `/api/v1/recipes` paths or account-wide uniqueness, so none go stale.
- **Codebase assumptions verified:**
  - Current arities `list_recipes/1`, `get_recipe/2`, `create_recipe/2`, `replace_recipe/3`, `delete_recipe/2`, `request_run/3,4`, and `list_runs/2,3` become the claimed `/2`, `/3`, `/3`, `/4`, `/3`, `/5`, and `/4`.
  - `recipes_account_id_name_index` and `validate_no_org/2` exist, as does `20261101180000_create_recipes.exs`.
  - The `binary_id` keys and `:utc_datetime_usec` timestamps match the plan.
  - `ApiAuth :require_write_access` exists, and `path_params` is available in pipeline plugs.
  - `ChangesetJSON`, `RecipeJSON`, the schemas, `ApiSpec`, `SpryFixtures`, and `concurrency_test.exs` exist.
  - Workers, the reaper, and abandonment recovery do not look up recipes by id.

## What looks good

- The breaking change is explicit, and the design says there is no compatibility alias.
- The migration refuses to invent a project and explains the rollback limit on the unique index.
- Sprite admission stays account-wide, with a scenario that pins it.
- The `422` / `404` / `409` responses match across proposal, design, tasks, and specs.
- The `RENAMED` + `MODIFIED` delta mechanics are correct.
