---
format: qa-scenarios/2
source: intent
change: "add-stored-changes-dashboard"
specs: uncommitted
review: null
scenarios:
  - id: 1
    name: "Any member opens the Changes pages"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "Changes pages are scoped to the account's projects"
        implied: true
  - id: 2
    name: "Unknown project, change and version redirect"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "Unknown projects, changes and versions redirect"
        implied: true
  - id: 3
    name: "No page offers to edit or delete a change"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "The Changes pages write nothing"
        implied: true
  - id: 4
    name: "List defaults to active changes, newest push first, and filters by URL"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "The Changes list filters and pages changes"
        implied: true
  - id: 5
    name: "Load more shows the 51st change"
    priority: should
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "The Changes list filters and pages changes"
        implied: true
  - id: 6
    name: "List rows show metadata and linked change requests"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "List rows show each change and its linked change requests"
        implied: true
  - id: 7
    name: "Empty project and empty filter"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "The list has empty states"
        implied: true
  - id: 8
    name: "Overview Changes card counts and lists active changes"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "The overview shows a Changes card"
        implied: true
  - id: 9
    name: "Change request page links its change id only when stored"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "A change request page links to its stored change"
        implied: true
  - id: 10
    name: "Detail header shows the version's fields, nulls and depends_on links"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "The detail page shows the version it opens"
        implied: true
  - id: 11
    name: "Detail page lists linked change requests or says there are none"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "The detail page shows linked change requests"
        implied: true
  - id: 12
    name: "Pushed HTML and script links are not rendered"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "File text renders only as sanitized Markdown"
        scenario: "Script in a pushed file"
  - id: 13
    name: "Front matter shows as a code block and the body as Markdown"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "File text renders only as sanitized Markdown"
        implied: true
  - id: 14
    name: "Other files are collapsed and a large file is plain text without a diff"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "Files are collapsed and large files are not rendered"
        implied: true
  - id: 15
    name: "History lists versions newest first and opens an earlier one"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "The History panel lists versions"
        implied: true
  - id: 16
    name: "A version lists added, removed and changed files against the one before"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "A version shows what changed from the version before it"
        implied: true
  - id: 17
    name: "A push refreshes the open pages and keeps their state"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "Pages update on project events"
        implied: true
  - id: 18
    name: "A change deleted while open redirects to the list"
    priority: must
    covers:
      - capability: "stored-changes-dashboard"
        requirement: "A change deleted while open redirects"
        implied: true
---

# QA: add-stored-changes-dashboard

Run these against a local GoodFlows server with `add-stored-changes` built, an account with project `web` and a second project `api`, an owner and a member with role `member`, and an `sk_` key of the account to push and delete changes through `POST` and `DELETE /api/v1/projects/:project/changes`.

## Scenarios

### 1. Any member opens the Changes pages (Must)

1. Push change `add-login` to `web`. Sign in as the member with role `member` and open `web`'s Changes list.
   - Expect: the list shows `add-login`.
2. Open `add-login` from the list.
   - Expect: the detail page for `add-login` opens.
3. Sign out and open the same detail URL.
   - Expect: the browser is sent to the log-in page, and no change content is shown.

### 2. Unknown project, change and version redirect (Must)

1. Open the Changes list with the slug of a project that belongs only to another account.
   - Expect: a redirect to the account's Projects page with a not-found flash, and none of that project's changes shown.
2. Push change `api-only` to `api`, then open `web`'s detail page for `api-only`.
   - Expect: a redirect to `web`'s Changes list with a not-found flash.
3. Open `add-login` in `web` with `?version=99`, then with `?version=abc`.
   - Expect: each redirects to `web`'s Changes list with a not-found flash.

### 3. No page offers to edit or delete a change (Must)

1. Sign in as the owner and open `web`'s Changes list, the `add-login` detail page and the project overview.
   - Expect: none of the three has a control that edits or deletes a stored change, and `add-login` is still stored afterwards.

### 4. List defaults to active changes, newest push first, and filters by URL (Must)

1. Push `a` with status `archived`, then `b` with status `approved`, then `c` with status `proposed`, and open the list.
   - Expect: the rows are `c` then `b`, and `a` is not listed.
2. Open the list with `?status=archived`, then `?status=all`, then `?status=bogus`.
   - Expect: Archived lists only `a`; All lists `c`, `b`, `a`; `bogus` lists `c`, `b` with Active selected.

### 5. Load more shows the 51st change (Should)

1. Push 51 changes with status `proposed` and open the list.
   - Expect: 50 rows and a Load more button.
2. Press Load more.
   - Expect: 51 rows, and no Load more button.

### 6. List rows show metadata and linked change requests (Must)

1. Push `add-login` twice with `size: small`, `door: two_way` and `capabilities: [auth]`, then open change requests 12 (`open`) and 9, later closed, both with change id `add-login`. Open the list.
   - Expect: the `add-login` row shows status, size `small`, door `two_way`, capability `auth`, version 2, the latest push time, and change requests 12 and 9 with their states.
2. Click change request 12 on the row.
   - Expect: change request 12's detail page opens.

### 7. Empty project and empty filter (Must)

1. Open the Changes list of a project with no stored changes.
   - Expect: an empty state that explains `goodflows change push` and says it needs a goodflows release newer than 0.10.0.
2. In `web`, which has only active changes, open `?status=archived`.
   - Expect: an empty state that names the Archived filter, not the push explanation.

### 8. Overview Changes card counts and lists active changes (Must)

1. In a project with 3 `proposed`, 4 `approved` and 2 `archived` changes, open the overview.
   - Expect: the Changes card shows 3 proposed and 4 approved, lists 5 active changes in latest-push order with no archived change among them, and links to the Changes list.
2. Open the overview of a project with no stored changes.
   - Expect: the card shows the push empty state.
3. Open the overview of a project whose only stored changes are archived.
   - Expect: the card shows 0 proposed and 0 approved and says no change is active, not the push empty state.

### 9. Change request page links its change id only when stored (Must)

1. Open change request 12, whose change id `add-login` is stored in `web`.
   - Expect: the change id links to `add-login`'s detail page.
2. Open a change request whose change id has no stored change in `web`.
   - Expect: the change id is shown as plain text with no link.

### 10. Detail header shows the version's fields, nulls and depends_on links (Must)

1. Push `add-login` with source commit `a1b2c3d4e5f6...`, branch `feat/login`, dirty true, and `depends_on: [add-users, add-ghost]`, where only `add-users` is stored. Open it.
   - Expect: status, version 1, size, door, capabilities, commit `a1b2c3d`, branch `feat/login`, dirty, the pusher's email and the push time are shown; `add-users` links to its page and `add-ghost` is not a link.
2. Push a new version with commit null, branch null and a malformed `size`.
   - Expect: the page shows no commit, a detached HEAD, and size not given.

### 11. Detail page lists linked change requests or says there are none (Must)

1. Open `add-login`, which change requests 12 and 9 link.
   - Expect: both are listed with their states, each linking to its page.
2. Open a stored change that no change request links.
   - Expect: the page says no change request exists for it.

### 12. Pushed HTML and script links are not rendered (Must)

1. Push `add-login` whose `change.md` body contains `<script>alert(1)</script>`, `<img src=x onerror=alert(1)>` and `[x](javascript:alert(1))`, and open it.
   - Expect: no alert runs, the page has no `script` or `img` element from the file and no `onerror` attribute, and no link has a `javascript:` URL.
2. Push a version whose body links `[a](//evil.example/x)` and `[b](#top)`, and open it.
   - Expect: `a` and `b` show as text with no `href`.

### 13. Front matter shows as a code block and the body as Markdown (Must)

1. Open `add-login`, whose `change.md` has front matter with `goals:` and a body with `## Why` and a link to `specs/auth/spec.md`.
   - Expect: the front matter appears as a code block with `goals:` in it, `## Why` renders as a heading, and the link to `specs/auth/spec.md` shows as its text with no `href`.
2. Push a version whose `verification.md` starts with `---` and has no closing `---` line, and expand it.
   - Expect: the whole file renders as Markdown body and no front matter code block is shown for it.

### 14. Other files are collapsed and a large file is plain text without a diff (Must)

1. Push `add-login` with `change.md`, `qa-scenarios.md` and `specs/auth/spec.md`, and open it.
   - Expect: `change.md` is expanded and the other two are collapsed until opened.
2. Push a version whose `verification.md` is 300,000 bytes and contains `## Heading`, and another change to it in the next version. Open the latest and expand `verification.md`.
   - Expect: it shows as plain text with `## Heading` literally, the page says it is too large to render, and no line diff is shown for it.
3. Push a version that shrinks `verification.md` to 1,000 bytes and open it.
   - Expect: `verification.md` is listed as changed with no line diff, and the page says why.

### 15. History lists versions newest first and opens an earlier one (Must)

1. Push `add-login` three times with different content, statuses `proposed`, `proposed`, `approved`, and open it.
   - Expect: the History panel lists 3, 2, 1 with their own statuses, push times, pushers and commits, and marks 3 as viewed.
2. Click version 1.
   - Expect: the URL has `?version=1`, the header shows version 1 with status `proposed`, it says this is not the latest version and links to it, and History marks 1 as viewed.
3. Click version 3 in History, then push a fourth version.
   - Expect: the URL has no `?version`, and within 2 seconds the page shows version 4.
4. Push 55 versions of another change and open it.
   - Expect: History shows 50, and Load more shows the other 5.

### 16. A version lists added, removed and changed files against the one before (Must)

1. Push `add-login` version 1 with `change.md` and `specs/auth/spec.md`, then version 2 that edits one line of `change.md`, removes `specs/auth/spec.md` and adds `qa-scenarios.md`. Open version 2.
   - Expect: `qa-scenarios.md` is listed as added, `specs/auth/spec.md` as removed, `change.md` as changed with a line diff showing the edited line, and nothing else as changed.
2. Open version 1.
   - Expect: both of its files are listed as added.
3. Push version 3 with a `specs/auth/spec.md` of 6,000 short lines, then version 4 that replaces them with 6,000 different short lines, both under 262,144 bytes, and open version 4.
   - Expect: the file is listed as changed with no line diff, the page says why, and the page loads within 2 seconds.

### 17. A push refreshes the open pages and keeps their state (Must)

1. Open the list with `?status=all` after Load more, the `add-login` detail page without `?version` with `qa-scenarios.md` expanded, and the same change at `?version=1`, each in its own tab. Push a new version of `add-login`.
   - Expect: within 2 seconds and without a reload, the list shows the new push time with the All filter and every loaded row kept; the first detail tab shows the new version with `qa-scenarios.md` still expanded; the `?version=1` tab still shows version 1.
2. With the overview open, push a new `proposed` change.
   - Expect: within 2 seconds the Changes card's proposed count goes up by one.

### 18. A change deleted while open redirects to the list (Must)

1. Open a stored change that no change request links, then delete it with `DELETE /api/v1/projects/web/changes/<id>`.
   - Expect: within 2 seconds the page redirects to `web`'s Changes list with a flash saying the change was deleted, and the change is not listed.
2. Open another unlinked change, then delete it and push it again with different content within the same second.
   - Expect: the page redirects to the Changes list with the deleted flash instead of showing the new change's version 1.
