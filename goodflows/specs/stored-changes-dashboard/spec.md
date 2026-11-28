# stored-changes-dashboard Specification

## Requirements

### Requirement: Changes pages are scoped to the account's projects
The dashboard SHALL serve a Changes list at `/dashboard/accounts/:account_id/projects/:slug/changes` and a change detail page at `/dashboard/accounts/:account_id/projects/:slug/changes/:change_id`, which shows the latest version, or version `N` with `?version=N`. Both MUST require a signed-in user who is a member of the account; every member, whatever their role, SHALL see them.

### Requirement: Unknown projects, changes and versions redirect
A slug that names no project of the account MUST redirect to the account's Projects page with a not-found flash. A change id with no stored change in the project, or a `version` that is not a positive integer or names no stored version of the change, MUST redirect to the project's Changes list with a not-found flash. No Changes page SHALL show another account's data.

### Requirement: The Changes pages write nothing
The Changes list, the detail page and the overview's Changes card SHALL offer no action that edits or deletes a stored change.

### Requirement: The Changes list filters and pages changes
The list SHALL show the project's stored changes by latest push time, newest first, 50 per page, with a Load more button while more exist. A filter SHALL select Active (latest status `proposed` or `approved`, the default), Archived or All, kept in the URL as `?status=active|archived|all`; any other value SHALL be treated as Active.

### Requirement: List rows show each change and its linked change requests
Each row SHALL link to the change's detail page and show the change id, its latest status, size, door, capabilities, latest version number, latest push time, and every change request of the project with that `change_id`, as number and state, each linking to its change request page.

### Requirement: The list has empty states
A project with no stored changes SHALL show an empty state that explains pushing a change with `goodflows change push` and that the command needs a goodflows release newer than 0.10.0. When the filter matches nothing in a project that has stored changes, the page SHALL show an empty state naming the filter.

### Requirement: The overview shows a Changes card
The project overview SHALL show a Changes card with the number of stored changes whose latest status is `proposed` and the number whose latest status is `approved`, the 5 most recently pushed changes with those statuses, each linking to its detail page, and a link to the Changes list. A project with no stored changes SHALL show the empty state of the list in the card; a project whose stored changes are all archived SHALL show both counts as 0 and say that no change is active.

### Requirement: A change request page links to its stored change
On a change request's detail page, the linked change id SHALL link to the stored change's detail page when the project has a stored change with that id, and SHALL stay plain text when it has none.

### Requirement: The detail page shows the version it opens
The detail page SHALL show the change id, the version number, the version's own status, size, door, capabilities, depends_on, the source commit, the source branch, whether the checkout was dirty, the pusher's email and the push time. A field stored as null SHALL be shown as not given, a capabilities or depends_on list stored empty as none, a null commit as no commit and a null branch as a detached HEAD. Each depends_on id SHALL link to that stored change when the project has it. A version that is not the latest SHALL say so and link to the latest.

### Requirement: The detail page shows linked change requests
The detail page SHALL list every change request of the project with the change's id, as number and state, each linking to its change request page, and SHALL say that no change request exists for the change when there is none.

### Requirement: File text renders only as sanitized Markdown
Each file of the version SHALL be shown by path, with its YAML front matter, when it has one, as a plain code block and its body rendered as Markdown with raw HTML dropped, through the same Markdown parser and sanitizer the change request page uses for scenario Markdown. A link SHALL keep its target only when its URL starts with the scheme `http:`, `https:` or `mailto:`; every other link, including a relative, fragment, protocol-relative or `javascript:` link, SHALL show as its text with no target. An image SHALL keep its source only when its URL starts with `http:` or `https:`; any other image SHALL show as its alt text. No pushed text SHALL reach the page as HTML any other way. Front matter SHALL be only the text between a first line that is `---` and the next line that is `---`, each ignoring one trailing carriage return; a file without both renders whole as its body.

#### Scenario: Script in a pushed file
- **WHEN** a version's `change.md` body contains `<script>alert(1)</script>` and a `[x](javascript:alert(1))` link
- **THEN** the page contains no `script` element from the file and no link with a `javascript:` URL

### Requirement: Files are collapsed and large files are not rendered
`change.md` SHALL be expanded and every other file collapsed until the member opens it. A file over 262,144 UTF-8 bytes SHALL be shown as plain text, escaped, instead of rendered Markdown, and the page SHALL say why.

### Requirement: The History panel lists versions
The detail page SHALL have a History panel listing the change's versions newest first, 50 at a time with Load more, each with its number, its own status, push time, pusher and source commit, and marking the version being viewed. Each entry SHALL link to that version with `?version=N`, except the latest, which SHALL link to the page without `?version`.

### Requirement: A version shows what changed from the version before it
The detail page SHALL list, for the version it opens, the files added, removed and changed compared with the version numbered one less, and SHALL list every file of version 1 as added. A changed file's changed region SHALL be the lines of its two versions left after removing the lines they share at the start and at the end. Each changed file SHALL get a line diff unless either version of it is over 262,144 UTF-8 bytes or its changed region has more than 1,000 lines. The line diffs of one version SHALL cover at most 1,000 changed-region lines together: changed files are taken in path order, and a changed file whose changed region would take that total past 1,000 lines SHALL get no line diff. A changed file without a line diff SHALL say why.

### Requirement: Pages update on project events
While a member has a Changes page or the project overview open, a committed project event for that project SHALL refresh it without a reload within 2 seconds of the event. A refresh MUST keep the list's filter and the rows already loaded, the version being viewed, and which files are expanded. A detail page opened without `?version` SHALL show the new latest version after a push; one opened with `?version=N` SHALL keep showing version N.

### Requirement: A change deleted while open redirects
When the change a member has open on its detail page is deleted, the page SHALL redirect to the project's Changes list with a flash saying the change was deleted. A change deleted and pushed again before the page refreshes SHALL count as deleted when its version 1 is not the version 1 the page loaded.
