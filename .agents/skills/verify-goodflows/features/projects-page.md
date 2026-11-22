---
paths:
  - "app/lib/good_flows_web/live/project_live/**"
  - "app/lib/good_flows/projects.ex"
  - "app/lib/good_flows/projects/**"
  - "app/test/good_flows_web/live/project_live_test.exs"
---

# Projects page

A signed-in owner or admin lists, creates, edits, and deletes the current account's projects on the dashboard's Projects page. A plain member of the account sees the same list without any controls to change it.

## Sub-features

- `projects-page-empty` shows `#projects-empty` (`No projects yet`) with a `Create project` button (`#empty-new-project-btn`) when the account has no projects. The header button `#new-project-btn` appears only once a project exists.
- `projects-page-create` creates a project from `#create-project-form` with a slug and a default branch (prefilled `main`). The flash reads `Project “<slug>” created.` and a row `projects-<uuid>` appears.
- `projects-page-validate` keeps the dialog open with the slug rule as the visitor types an invalid slug, and `has already been taken by another project in this account` after submitting a used one.
- `projects-page-edit` changes only the default branch from `#edit-project-form`, with the flash `Project “<slug>” updated.`
- `projects-page-delete` deletes a project after the `Delete project` confirmation, with the flash `Project “<slug>” deleted.` A project that still has recipes, test reports, workflow runs, change requests, or verify runs stays, and `#flash-error` reads `“<slug>” still has recipes, so it can't be deleted.` (or the matching blocker).
- `projects-page-member-readonly` shows a member the list with no create, edit, or delete buttons, and `#projects-read-only` reads `Only account owners and admins can create, edit, or delete projects.` When the account has no projects, the empty state reads `An account owner or admin can create projects.` without a button.

## How to get to it (user POV)

- Choose `Projects` under `// Overview` in the dashboard sidebar.
- Open `/dashboard/accounts/<account-id>/projects` directly. The breadcrumb reads `Dashboard / Projects`.

## Driving it with control-goodflows

Preconditions:

- Baseline state, `$C login` succeeded, and the dashboard shows Acme Corp (owner).
- Acme Corp has no projects (true for a fresh launch).

- **Open the page.** Run `$C browser click '#sidebar a[href$="/projects"]'` and `$C browser wait '#projects-empty'`. The `h1` reads `Projects` and `#new-project-btn` is absent.
- **Validate.** Run `$C browser click '#empty-new-project-btn'`, `$C browser wait '#create-project-form'`, and `$C browser fill '#project_slug' 'Not Valid'`. The form shows `must be 1 to 64 bytes of lowercase letters, digits, `_`, and `-`, starting with a letter or digit`.
- **Create.** Run `$C browser fill '#project_slug' verify-ui` and `$C browser click '#create-project-form button[type=submit]'`, then `$C browser wait --text "created."`. `#flash-info` reads `Project “verify-ui” created.`, the dialog is gone, and `#new-project-btn` is shown.
- **Duplicate.** Dismiss the flash (`$C browser click '#flash-info'`), open `#new-project-btn`, submit `verify-ui` again, and the form shows `has already been taken by another project in this account`. `$C browser press Escape` closes it.
- **Edit.** Run `$C browser find role button click --name "Edit verify-ui"`, `$C browser fill '#edit-project-form #project_default_branch' trunk`, and `$C browser click '#edit-project-form button[type=submit]'`. `#flash-info` reads `Project “verify-ui” updated.` With an Acme `sk_` key exported, `$C api page-show GET /api/v1/projects/verify-ui` returns `default_branch` `trunk`.
- **Blocked delete.** Create a recipe with `$C api page-recipe POST /api/v1/projects/verify-ui/recipes '{"name":"verify-recipe"}'`. Run `$C browser find role button click --name "Delete verify-ui"`, `$C browser wait '#delete-confirm-modal'`, and `$C browser click '#delete-confirm-modal-confirm'`. `#flash-error` reads `“verify-ui” still has recipes, so it can't be deleted.` and the row stays.
- **Delete.** Delete the recipe through the API (204), dismiss the flash, and confirm the delete again. `#flash-info` reads `Project “verify-ui” deleted.`, `#projects-empty` returns, and `$C api page-gone GET /api/v1/projects/verify-ui` returns 404.
- **Member view.** Switch to Globex Industries (see [Account dashboard](./account-dashboard.md)) and open `Projects`. The seeded `globex-api` row is listed with default branch `main`, `#projects-read-only` is shown, and `#new-project-btn`, `#empty-new-project-btn`, and every `Edit` or `Delete` button (`[id^=edit-]`, `[id^=delete-]`) are absent.
- **Proof.** Keep screenshots of the empty state, the invalid and duplicate errors, the created row, the edit dialog, the delete confirmation, the blocked and deleted flashes, and the member view, plus `$C db "select slug, default_branch from projects order by slug" projects-page/db-rows.txt`.

## Gotchas

- Flashes use curly quotes (`“verify-ui”`). Wait with `--text "created."`, `"updated."`, or `"deleted."` rather than typing the quotes.
- `Create project` names the header button, the empty-state button, and the dialog's submit. Submit with `#create-project-form button[type=submit]`.
- The create and edit dialogs both use the field ID `project_default_branch`. Scope it to the open form.
- Row, edit, and delete IDs use the project UUID. Use the accessible names `Edit <slug>` and `Delete <slug>` instead.
- The page cannot add recipes, so a blocked delete needs a recipe made through the API first.
- Only Globex Industries is seeded with a project. Acme Corp starts empty so the owner recipe can check the empty state first.
- Flashes cover the top-right of the header for a few seconds. Click the flash before clicking near it.
