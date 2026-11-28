---
paths:
  - "app/lib/good_flows_web/live/stored_change_live/**"
  - "app/lib/good_flows_web/components/stored_change_components.ex"
  - "app/lib/good_flows_web/scenario_markdown.ex"
  - "app/lib/good_flows_web/live/change_request_live/show.ex"
  - "app/lib/good_flows_web/live/project_live/show.ex"
  - "app/assets/css/app.css"
  - "app/test/good_flows_web/live/stored_change_live_test.exs"
  - "app/test/good_flows_web/live/change_request_live_test.exs"
  - "app/test/good_flows_web/live/project_live/show_test.exs"
  - "app/test/good_flows_web/scenario_markdown_test.exs"
  - ".agents/skills/verify-goodflows/features/stored-changes-dashboard.md"
  - "goodflows/specs/stored-changes-dashboard/**"
  - "goodflows/changes/add-stored-changes-dashboard/**"
  - "goodflows/changes/archive/*-add-stored-changes-dashboard/**"
---

# Stored changes dashboard

Any member of an account reads the goodflows changes stored under one of its projects in the dashboard, before or while a change request builds them: a Changes list per project, a detail page for each change and each of its versions with a History panel and line diffs against the version before, a Changes card on the project overview, and a link from a change request page to the change it builds. The pages only read; pushes and deletes happen through the [Stored changes API](./stored-changes-api.md), and open pages update within about 2 seconds of one.

## Sub-features

- `changes-page-list` lists the project's changes, newest push first, filtered by `?status=active` (the default, and what an unknown value falls back to), `archived` or `all`, 50 rows at a time with `#load-more`. Each row shows status, size, door, capabilities, version, push time and its linked change requests with their states.
- `changes-page-empty` shows `#changes-empty` (`No changes stored yet`, explaining `goodflows change push`) for a project with no stored change, and `#changes-filter-empty` naming the filter with a `#empty-show-all` button when only the filter is empty.
- `changes-page-detail` opens a change's latest version, or `?version=N`, with the version panel (status, size, door, capabilities, `depends_on` links for stored ids, commit, branch, dirty, pusher, push time), the linked change requests or `#no-change-requests`, and the files with `change.md` expanded and the others collapsed. File text renders only as sanitized Markdown, front matter as a code block. An unknown project redirects to Projects, and an unknown change or a bad version to the Changes list, each with a not-found flash.
- `changes-page-history` lists the versions newest first in `#history`, 50 at a time with `#history-load-more`, marks the viewed one, and opens an earlier one at `?version=N` with `#not-latest-notice` linking to the latest.
- `changes-page-diff` lists in `#version-changes` each file added, removed or changed against the version before, with a keyboard-focusable line diff region for a changed file, or a `[data-role=no-diff]` reason when a file is too large or the diff too long.
- `changes-page-live` refreshes the open list and detail pages on a push, keeping the filter, loaded rows and expanded files, leaves a `?version=N` page on its version, and redirects a page whose change was deleted to the list with a flash.
- `changes-overview-card` shows `#changes-card` on the project overview: counts of proposed and approved changes, the 5 latest active changes, `#changes-link` to the list, the push empty state for a project with no change, and `#no-active-changes` when every change is archived.
- `changes-cr-link` links a change request page's change id to its stored change (`#change-id-link`), or shows it as plain text (`#change-id-tag`) when no change with that id is stored in the project.

## How to get to it (user POV)

- On a project's overview (`/dashboard/accounts/<account-id>/projects/<slug>`), the `Changes` card and its `All changes` link.
- Open `/dashboard/accounts/<account-id>/projects/<slug>/changes` directly, with `?status=archived` or `?status=all`. The breadcrumb reads `Dashboard / Projects / <slug> / Changes`.
- Choose a change id in the list or the card, or open `…/changes/<change-id>` and `…/changes/<change-id>?version=<n>`.
- On a change request page, the change id under `Change`.

## Driving it with control-goodflows

Preconditions:

- Baseline state and `$C login` succeeded. An Acme Corp private key created on the API keys page, as in [API keys](./api-keys.md), exported as `GF_API_KEY`.
- A project `web` created with that key: `$C api changes-web POST /api/v1/projects '{"slug":"web"}'` returns 201. Every change below is pushed with `POST /api/v1/projects/web/changes`, as in [Stored changes API](./stored-changes-api.md).
- `ACCOUNT` holds Acme Corp's id, read from the URL `/dashboard` redirects to, and `P="$GF_URL/dashboard/accounts/$ACCOUNT/projects/web"`.

- **Empty list.** Run `$C browser open "$P/changes"` and `$C browser wait '#changes-empty'`. It reads `No changes stored yet` and names `goodflows change push`. The overview `$P` shows `#changes-card-empty`.
- **List and filter.** Push `a` (`archived`), then `b` (`approved`), then `c` (`proposed`), a second apart. Open `$P/changes`: the `#changes` rows are `c` then `b`. Open `?status=archived` (only `a`), `?status=all` (`c`, `b`, `a`) and `?status=bogus` (`c`, `b`, with Active selected in `#changes-filter`).
- **Linked change requests.** Open a change request with `change_id` `c` (`$C api changes-cr POST /api/v1/projects/web/change-requests '{"title":"C","source_branch":"feat/c","change_id":"c"}'`). The list row shows `#change-c-cr-<n>` with its state; clicking it opens that change request's page.
- **Change id link.** On that change request page, `#change-id-link` goes to `$P/changes/c`. A change request whose `change_id` is not stored shows `#change-id-tag` and no link.
- **Detail.** Push `add-login` with `size: small`, `door: two_way`, `capabilities: [auth]`, `depends_on: [c, add-ghost]`, a `qa-scenarios.md` and a `specs/auth/spec.md`. Open `$P/changes/add-login`: `#change-version` is 1, `#depends-on-c` is a link and `#depends-on-add-ghost` is not, `#no-change-requests` is shown, `change.md` is expanded with its front matter in a code block, and `$C browser click '#files li[data-path="qa-scenarios.md"] button'` expands that file.
- **Sanitizing.** Push a version whose `change.md` body holds `<script>alert(1)</script>`, `<img src=x onerror=alert(1)>` and `[x](javascript:alert(1))`. `$C browser eval` finds no `script` or `img` element and no `onerror` inside `#files`, and no `a[href^="javascript:"]` on the page.
- **History and diff.** Push a version that edits one line of `change.md`, removes `specs/auth/spec.md` and adds `verification.md`. `#history` lists the versions newest first with `Latest` and `Viewed` on the newest. `#version-changes` has `li[data-change=changed]` for `change.md` with a `[data-role=line-diff]` region, `li[data-change=removed]` and `li[data-change=added]`. Click `Version 1` in `#history`: the URL has `?version=1`, `#not-latest-notice` links to the latest, and every file of version 1 is listed as added. `?version=99` and `?version=abc` redirect to `$P/changes` with a not-found flash in `#flash-error`.
- **Live update.** With `$P/changes?status=all` and `$P/changes/add-login` (a file expanded) open, push a new version of `add-login`. Within 2 seconds and without a reload the list shows the new push time with All still selected, and the detail page shows the new `#change-version` with the file still expanded. Push and delete an unlinked change while its page is open: the page lands on `$P/changes` and `#flash-error` reads `Change <id> was deleted from project web. …`.
- **Overview card.** Open `$P`. `#changes-count-proposed` and `#changes-count-approved` match the active changes, `#active-changes` lists at most 5 with no archived one, and `#changes-link` opens the list.
- **Proof.** Keep a screenshot and an ARIA snapshot (`$C browser snapshot -s '#changes'`, `'#history-panel'`, `'#version-changes-panel'`, `'#changes-card'`) for each step, and the `api/changes-*` pushes.

## Gotchas

- The pages never write. To change what they show, push or delete through the API with a private key; a public key cannot push.
- List order is by latest push time, so pushes in the same second can tie. Leave a second between pushes when order is the proof.
- A change's latest status `archived` refuses every non-identical push of that id (409). Use a new id for each scenario that needs a fresh change.
- A change that a change request links cannot be deleted, so the deleted-while-open redirect needs a change no change request links.
- Change request numbers are assigned by the server per project, so read them from the response instead of assuming a number.
- `#files` row ids are the base64url of the path; select a file by `li[data-path="<path>"]` instead.
- The Globex member role in the seed is `member`, so use Globex Industries' `globex-api` project for a member's view; Acme Corp has the seeded user as owner.
- Line diffs are omitted with a `[data-role=no-diff]` reason when either version is over the render limit or the diff is too long, and the comparison loads after the page (`#version-changes-pending`), so wait for `#version-changes li` before reading it.
