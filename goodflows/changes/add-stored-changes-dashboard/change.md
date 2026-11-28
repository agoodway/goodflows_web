---
format: goodflows-change/1
id: add-stored-changes-dashboard
status: approved
size: project
door: two_way
capabilities: [stored-changes-dashboard]
depends_on: [add-stored-changes]
goals:
  - {id: G1, text: "The team can see planned changes in the dashboard before any change request exists for them"}
  - {id: G2, text: "The team can read a change's history: every pushed version and what each push changed"}
non_goals:
  - {id: N1, text: "Artifacts on a change, such as screenshots, videos and other files; they wait for their own server change"}
  - {id: N2, text: "Editing or deleting a stored change from the dashboard"}
  - {id: N3, text: "Comparing two versions of the reader's choice; a version is compared only with the one before it"}
anti_goals:
  - {id: A1, text: "Pushed file text running as HTML or script in a member's browser"}
decisions:
  - id: D1
    question: Who sees the Changes pages?
    answer: Every member of the account, whatever their role, as on the other project pages
    by: user
    why: "Accepted recommendation: every other project page is open to all members, and the pages write nothing"
    rejected: [owners and admins only]
  - id: D2
    question: Can a stored change be deleted from the dashboard?
    answer: No. Delete stays in the CLI in this change
    by: user
    why: "Accepted recommendation: the server copy mirrors the repository, so a dashboard delete comes back on the next push, and it would be the pages' only write"
    rejected: [owners and admins delete from the detail page]
  - id: D3
    question: How is pushed file text shown?
    answer: "Each file's body renders as Markdown through the sanitizer the change request page uses for scenario Markdown, with raw HTML dropped, and a link keeps its target only when its URL uses http, https or mailto; any other link, including a relative link between files of a change, shows as its text. The YAML front matter of a file shows as a plain code block above its body"
    by: user
    why: "Accepted recommendation: file text comes from any sk_ key and is untrusted, and goals and decisions live in the front matter, which the server does not parse"
    rejected: [parse the front matter into goals and decisions on the dashboard, show every file as plain text]
  - id: D4
    question: How does a reader see what a push changed?
    answer: Each version lists the files it added, removed or changed compared with the version before it, with a line diff for each changed file. Version 1 lists every file as added
    by: user
    why: "Accepted recommendation: the history of a change is the goal, and the server has no diff route, so the dashboard compares the two versions"
    rejected: [compare any two versions, show versions without what changed]
  - id: D5
    question: What does the Changes list show by default, and how is it ordered and paged?
    answer: "Active (latest status proposed or approved) by default, with Archived and All filters kept in the URL as ?status=active|archived|all; newest latest push first; 50 rows with Load more"
    by: user
    why: "Accepted recommendation: archived changes are finished and would crowd out the planned ones; the paging matches the change request list"
    rejected: [all statuses by default]
  - id: D6
    question: Does the project overview show changes?
    answer: A Changes card with the number of changes whose latest status is proposed and, separately, the number whose latest status is approved, the 5 most recently pushed active changes each linking to its page, and a link to the Changes list
    by: user
    why: "Accepted recommendation: the team sees planned changes where it already looks"
    rejected: [a header link only]
  - id: D7
    question: Does a change request page link to its stored change?
    answer: Its change id links to the stored change's page when one exists for the project, and stays a plain tag when none does
    by: user
    why: "Accepted recommendation: the (project, change_id) pair already links them on the server"
    rejected: []
  - id: D8
    question: Where are linked change requests shown?
    answer: On each list row and on the detail page, as number and state, each linking to its change request page. On the detail page a change with none says that no change request exists for it
    by: user
    why: "Accepted recommendation: a reader sees which planned changes are already being built"
    rejected: [detail page only]
  - id: D9
    question: What happens when a change is deleted while a member has it open?
    answer: The page redirects to the Changes list with a flash saying the change was deleted
    by: user
    why: "Accepted recommendation: stale content that no longer exists on the server cannot be trusted"
    rejected: [keep the stale content with a notice]
  - id: D10
    question: How do the pages stay current?
    answer: A committed project event for the project refreshes the page within 2 seconds, keeping the list's filter and loaded rows, the version being viewed, and which files are expanded
    by: user
    why: "Accepted recommendation: the change request pages promise the same, and pushes and deletes reach the project event feed"
    rejected: [reload by hand]
  - id: D11
    question: How does the detail page stay usable for a large version (100 files, 2 MiB)?
    answer: change.md is expanded and every other file collapsed until opened. A file over 262,144 UTF-8 bytes shows as plain text instead of rendered Markdown and gets no line diff, and the page says why
    by: user
    why: "Accepted recommendation: one large push should not make the page slow"
    rejected: [render and diff every file]
  - id: D12
    question: How many versions does the History panel show?
    answer: The newest 50, with Load more
    by: user
    why: "Accepted recommendation: versions are kept forever"
    rejected: [every version at once]
  - id: D13
    question: What are the page routes?
    answer: "/dashboard/accounts/:account_id/projects/:slug/changes for the list and /dashboard/accounts/:account_id/projects/:slug/changes/:change_id for the detail page, with ?version=N for an earlier version"
    by: agent
    why: The routes sit beside the change request pages, and ?version=N is how the review policy page opens a version
    rejected: [a /versions/:n path segment]
  - id: D14
    question: What does an unknown project, change or version do?
    answer: A slug that names no project of the account redirects to the account's Projects page with a project-not-found flash. A change id with no stored change, or a version that is not a positive integer or not stored, redirects to the project's Changes list with a not-found flash. No other account's data is shown
    by: agent
    why: An unknown project redirects as on the change request pages; an unknown change or version goes to the Changes list so the reader stays in the project
    rejected: [a 404 page, redirect an unknown change to the Projects page as an unknown change request does]
  - id: D15
    question: Which version does a refresh show after a new push?
    answer: A page opened without ?version shows the new latest version; a page opened with ?version=N keeps showing version N, and marks it as not the latest
    by: agent
    why: A reader of the latest wants the latest, and a reader of an old version chose it
    rejected: [always jump to the latest]
  - id: D16
    question: What does the detail page show about a version?
    answer: "The change id, version number, the version's own status, size, door, capabilities, depends_on (each id linking to its stored change when one exists for the project), the source commit or that it had none, the branch or that HEAD was detached, whether the checkout was dirty, the pusher's email, and the push time. A field the server stored as null shows as not given"
    by: agent
    why: These are the fields the server stores with a version
    rejected: []
  - id: D17
    question: What does a project with no stored changes show?
    answer: The list and the overview card show an empty state that explains pushing a change with goodflows change push and says it needs a goodflows release that has that command, newer than 0.10.0. A filter that matches nothing shows an empty state naming the filter
    by: agent
    why: "The runs card's empty state explains its CLI command the same way; goodflows 0.10.0 has no change push yet, so a member on it would otherwise be told to run a command that does not exist"
    rejected: [name the exact first CLI version, which is not released yet]
  - id: D18
    question: How do the durable OpenSpec specs that this change contradicts stay true?
    answer: "The same branch updates openspec/specs/project-overview/spec.md to include the Changes card and adds to openspec/specs/change-request-dashboard/spec.md a requirement that the linked change id links to the stored change"
    by: agent
    why: Both capabilities live only in openspec/specs/, so a goodflows delta cannot amend them, which is how add-stored-changes handled the same problem
    rejected: [move project-overview and change-request-dashboard into goodflows/specs/ first]
  - id: D19
    question: Where do the Active filter and the card's counts come from, when the add-stored-changes list takes a single status and returns no counts?
    answer: The dashboard reads them through the server's code; this change adds no API parameter
    by: agent
    why: Two single-status lists cannot be merged into one cursor page order, and the dashboard reads through the server's code, not the API
    rejected: [add status=active to the API in this change, merge two API lists in the page]
  - id: D20
    question: Does a changed file get a line diff when only one of its two versions is over the size limit?
    answer: No. A changed file gets no line diff when either version is over 262,144 UTF-8 bytes, and the page says so
    by: agent
    why: Diffing a large file against a small one costs as much as diffing two large ones
    rejected: [diff when the newer version is under the limit]
  - id: D21
    question: What counts as a file's YAML front matter?
    answer: Only text between a first line that is --- and the next line that is ---, each ignoring one trailing carriage return. A file whose first --- is never closed has no front matter and renders whole as its body
    by: agent
    why: "It is the rule GoodFlows.FrontMatter applies when the server accepts change.md and qa-scenarios.md, so a CRLF file the server accepted shows its front matter; an unclosed block cannot be told apart from body text"
    rejected: []
  - id: D22
    question: What does an open page do when its change was deleted and pushed again before the page refreshed?
    answer: It treats the change as deleted and redirects with the deleted flash, as in D9, when the change's version 1 is not the version 1 the page loaded
    by: agent
    why: The new change shares only its id with the old one, so showing its versions would show a different change under the old page
    rejected: [show the new change's versions]
  - id: D23
    question: Which links in pushed text keep their target?
    answer: "Only links whose URL starts with the scheme http:, https: or mailto:. Relative, fragment, protocol-relative (//host) and javascript: links show as their text. The change pages apply this on top of the change request page's Markdown parser and sanitizer, and the change request page's rendering is unchanged"
    by: agent
    why: "Found by the review: the shared sanitizer keeps any link with no scheme, so relative links would become broken in-app links and //host links would leave the site, against D3 and A1. Changing the shared renderer would silently change the change request page"
    rejected: [change the shared renderer for both pages, keep scheme-less links]
  - id: D24
    question: How is the line diff kept from making a page slow?
    answer: A changed file gets no line diff when its two versions together have more than 10,000 lines, as well as when either is over the size limit (D20), and the page says why
    by: agent
    why: "A line diff's cost grows with lines times edits, so a byte limit alone lets one push of many short lines stall every member who opens it, and the page must still refresh within 2 seconds (D10)"
    rejected: [a time budget per diff, no line limit]
  - id: D25
    question: Where does the newest History entry link?
    answer: To the page without ?version, so a reader who returns to the latest keeps following new pushes (D15)
    by: agent
    why: The review policy page sends its current version to the bare URL the same way
    rejected: [link every entry with ?version=N]
  - id: D26
    question: What does the overview card show when every stored change is archived?
    answer: Both counts as 0 and a line saying no change is active, not the push empty state
    by: agent
    why: The Change requests card says no change request is active the same way, and the push explanation would wrongly tell the team to set up pushing
    rejected: [the push empty state, an empty card]
left_to_builder:
  - Page layout, components, file order and how the line diff looks, following DESIGN.md (including its timestamp format and the dashboard's short commit form) and the shared components
  - Sidebar and breadcrumbs, following the change request pages' pattern
  - Whether diffs or file renders are cached across refreshes, as long as a refresh meets the 2-second target of D10
  - How the dashboard reads stored changes, through the stored-changes context add-stored-changes builds, and how the diff is computed
  - How a pusher who is no longer an account member is shown, as long as no other account's data appears
  - "Wording of flashes, empty states and notices, with the bar that each names the input or state at fault and what to do next: the missing change or version, the filter, the file over the size limit"
  - How each requirement is tested, with the bar that breaking the behavior of any Must scenario fails an automated test
---

## Why

tbrewer wants the team to see planned changes and their history before any change request exists. The Space this comes from has the goal "Build and maintain a UI that helps users manage changes"; this is its first read-only view of stored goodflows changes.

## Context

This change depends on `add-stored-changes`, which stores each push of a `goodflows/changes/<id>/` directory on the server as an immutable version, lists changes and versions, links a stored change to change requests through the project and `change_id`, and records pushes and deletes in the project event feed. The dashboard pages read those stored changes. Until that change merges, a copy of it sits in `goodflows/changes/add-stored-changes/` so validate can resolve the dependency.

The server stores each file's text as pushed and parses only `format`, `id`, `status`, `size`, `door`, `capabilities` and `depends_on` from `change.md`. The server copy is a read-only mirror, a change linked by a change request cannot be deleted, and `pk_` keys cannot read file text; the dashboard reads as an account member, not through an API key, so key rules do not apply to it.

Today's dashboard has a project overview (`ProjectLive.Show`) with Change requests and Runs cards, change request list and detail pages (`ChangeRequestLive`), and a review policy page (`ReviewPolicyLive.Show`) that opens immutable versions with `?version=N` and a History panel. Pages subscribe to `GoodFlows.ProjectEvents.topic/1` and reload shortly after an event. The change request page renders scenario Markdown with `GoodFlowsWeb.ScenarioMarkdown` (MDEx with raw HTML off, then `HtmlSanitizeEx.markdown_html/1`) and shows the linked `change_id` as a tag.

## Approaches

- **Changes pages of their own (picked).** A Changes list and a change detail page under the project, linked from the overview and from change requests. A change without a change request has a home, which is the point.
- **Extend the change request pages.** Fewer pages, but a change with no change request has no page for its history, and the change request page is already the largest in the app.
- **An overview card and a detail page, without a list.** Smallest, but changes cannot be browsed or filtered and older ones fall off the card.
