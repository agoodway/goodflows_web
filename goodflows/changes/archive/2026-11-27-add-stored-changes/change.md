---
format: goodflows-change/1
id: add-stored-changes
status: archived
size: project
door: one_way
capabilities: [stored-changes]
depends_on: []
goals:
  - {id: G1, text: "A goodflows change can be stored on the server before any change request exists for it"}
  - {id: G2, text: "Every push of a change is kept, so its history can be read later"}
  - {id: G3, text: "A UI can list, read and follow stored changes through the same API the CLI uses"}
  - {id: G4, text: "A change request opened later for a change is linked to the stored change"}
non_goals:
  - {id: N1, text: "Creating a change request from a stored change, such as seeding its intent scenario set from the stored qa-scenarios.md; a later change does that"}
  - {id: N2, text: "Editing a stored change on the server; the repository files stay the source of truth"}
  - {id: N3, text: "Running the full goodflows change validate on the server"}
anti_goals:
  - {id: A1, text: "A stored change deleted while a change request still links to it"}
  - {id: A2, text: "A push that is lost or silently overwrites an earlier version"}
decisions:
  - id: D1
    question: Is the server copy the source of truth, or a mirror of the repository files?
    answer: A mirror. The CLI pushes the files; nothing on the server edits them
    by: user
    why: The change is written and reviewed in the repository
    rejected: [server copy is the source of truth and the CLI pulls it]
  - id: D2
    question: Keep every pushed version, or only the latest?
    answer: Keep every pushed version as history
    by: user
    why: The history of a change is worth reading
    rejected: [keep only the latest version]
  - id: D3
    question: Is qa-scenarios.md stored with the change, or only through the change request's scenario-set upload?
    answer: Stored with the change on the server
    by: user
    why: The intent set is part of the change and exists before any change request
    rejected: [keep qa-scenarios.md only in the existing scenario-set upload]
  - id: D4
    question: Can a stored change be deleted once a change request links to it?
    answer: "No"
    by: user
    why: A change request's change must stay readable
    rejected: [allow the delete]
  - id: D5
    question: What must a push pass on the server?
    answer: "Only what the server relies on: change.md front matter with format goodflows-change/1, a valid id and a status of proposed, approved or archived, and, when present, qa-scenarios.md as a valid qa-scenarios/2 intent set whose change equals the id. The full goodflows change validate stays the client's job"
    by: user
    why: "Accepted recommendation: the server does not copy the CLI's validator, so the two cannot drift"
    rejected: [run every goodflows change validate rule on the server]
  - id: D6
    question: What does a push byte for byte equal to the latest version do?
    answer: Creates no version and returns the latest version with duplicate true; that version keeps the source of the push that created it
    by: user
    why: "Accepted recommendation: re-pushing an unchanged change should not fill the history with copies"
    rejected: [store a new version for every push]
  - id: D7
    question: Which files may a push carry?
    answer: "change.md (required), qa-scenarios.md, verification.md, and specs/<capability>/spec.md where capability may be nested as area/name under goodflows change validate's capability rule. Any other path is 422"
    by: user
    why: "Accepted recommendation: these are the files of a goodflows change, and the CLI's capability rule allows nested names"
    rejected: [accept any path under the change directory]
  - id: D8
    question: Which API keys may do what?
    answer: "Any sk_ key of the account pushes, reads and deletes. A pk_ key lists changes and reads change and version metadata, but a request for file text is 403 rather than a 200 without the text"
    by: user
    why: "Accepted recommendation: file text is change content, which pk_ keys do not see on change requests either, and the CLI expects a 403"
    rejected: [pk_ keys read file text, a 200 with the text left out]
  - id: D9
    question: How are archived changes handled?
    answer: An archived status is mirrored like any other. Once the latest version is archived, a later push with that id is 409 unless it is identical to that version, which is a duplicate as in D6. The id comes only from change.md's front matter
    by: user
    why: "Accepted recommendation: an archived change is finished, and reusing its id would mix two changes in one history; the CLI refuses this locally too"
    rejected: [accept pushes over an archived change, take the id from the URL]
  - id: D10
    question: What does a delete remove, and do stored changes block project deletion?
    answer: A delete removes the change and every version. Stored changes block project deletion, as change requests do
    by: user
    why: "Accepted recommendation: a half-deleted history is worse than none, and project deletion follows the existing change request rule"
    rejected: [delete only the latest version, let project deletion remove stored changes]
  - id: D11
    question: How do change requests and stored changes link?
    answer: "Through the existing (project, change_id) pair. Opening a change request does not need a stored change. A stored change's read returns its linked change requests as number and state, and a refused delete's 409 returns the same list"
    by: user
    why: "Accepted recommendation: change_id already links change requests, dependencies and intent sets, and the CLI needs the numbers to explain a refused delete"
    rejected: [a new foreign key from change requests to stored changes, require a stored change before opening a change request]
  - id: D12
    question: What are the size limits and how long are versions kept?
    answer: At most 100 files and 2 MiB of file text per push; every version is kept until the change is deleted
    by: user
    why: "Accepted recommendation: goodflows changes are a few small text files, and the history is the point"
    rejected: [prune old versions]
  - id: D13
    question: Do pushes and deletes reach the project event feed?
    answer: Yes. A push that stores a version and a delete each record a project event
    by: user
    why: "Accepted recommendation: a UI follows the feed to update live"
    rejected: [no events]
  - id: D14
    question: What happens when two pushes of one change arrive at once?
    answer: Each gets the next version number and neither is lost. There is no expected-version check
    by: user
    why: "Accepted recommendation: the server is a mirror, so the last push is the repository's latest state"
    rejected: [reject a push whose expected version is stale]
  - id: D15
    question: What are the routes and response shapes?
    answer: "POST /api/v1/projects/:project/changes with {files, source}: 201 with the new version, or 200 with duplicate true and the latest version; both carry replaced_version, the number of the version that was latest before the push: null for a new change, and the latest version N for a duplicate. GET /changes takes limit, cursor and status and returns next_cursor. GET /changes/:change_id returns the latest version. GET /changes/:change_id/versions lists versions, each with its number, its own status, pushed_at, source and latest; GET /changes/:change_id/versions/:n returns one version with the change's latest_status. DELETE /changes/:change_id"
    by: user
    why: "Accepted recommendation: it follows the feature index sync and the existing list routes, and it answers the CLI change's contract questions. tbrewer chose N rather than null for a duplicate's replaced_version, matching the CLI change's assumption"
    rejected: [take the id in the push URL, make the CLI read the change before a push to learn the replaced version]
  - id: D16
    question: What provenance does a push carry?
    answer: "source: {commit, branch, dirty}. commit is a SHA or null when the repository has no commits, branch is a name or null on a detached HEAD, dirty is a boolean. The server stores it with the version without checking it against anything"
    by: user
    why: "Accepted recommendation: a reader can tell which commit a version came from, and the server has no Git access to check it"
    rejected: [no provenance]
  - id: D18
    question: Which change.md fields does the server read beyond format, id and status?
    answer: "size (small or project), door (one_way or two_way), capabilities (a list of capability names under the D24 rule) and depends_on (a list of ids under the D24 rule), stored for listing when well formed and null otherwise; a list with any bad entry is null as a whole, and a malformed field does not refuse the push"
    by: agent
    why: Approach A keeps a few fields for a UI to list and filter, and D5 limits what refuses a push
    rejected: [refuse a push whose size, door, capabilities or depends_on is malformed]
  - id: D19
    question: What does a pk_ key see of a version's metadata?
    answer: "Only what the two list routes return: the change list (id, latest version number, status, size, door, capabilities, depends_on, last push time) and the versions list (number, status, pushed_at, source, latest), with the pusher null. A pk_ request for an unknown id is 403 too, as for a known one"
    by: agent
    why: "Change request reads redact personal fields such as user_id for pk_ keys, D8 hides content, and answering 403 for unknown ids too does not reveal which ids exist"
    rejected: [a redacted change read for pk_ keys with file paths and linked change requests, 404 for an unknown id]
  - id: D20
    question: Can an id be pushed again after its change was deleted?
    answer: Yes, as a new change whose versions start again at 1
    by: agent
    why: The delete removed the history (D10), so nothing is left to continue
    rejected: [refuse a deleted id forever]
  - id: D21
    question: How is the change list ordered, and what are the page limits?
    answer: "Newest latest push first, ties broken by id; limit 1 to 200, default 50, as the existing list routes use. A change pushed again while a client pages may be missed or repeated by that pass; clients follow the project event feed for live updates"
    by: agent
    why: A UI shows recently pushed changes first, the limits match the feature index version list, and a snapshot cursor is not worth its cost when the event feed already reports every push
    rejected: [order by id]
  - id: D22
    question: How do the durable OpenSpec specs that conflict with this change stay true?
    answer: "The same branch updates openspec/specs/projects/spec.md (stored changes join the project deletion blockers) and openspec/specs/project-events/spec.md (the new event types and their fields join the closed type list and the OpenAPI enum)"
    by: agent
    why: "Both capabilities live only in openspec/specs/, so a goodflows delta cannot amend them, and leaving them unchanged would contradict this change"
    rejected: [move projects and project-events into goodflows/specs/ first]
  - id: D23
    question: What status does each size limit answer with?
    answer: "422 for more than 100 files or more than 2,097,152 UTF-8 bytes of file text; 413 for a request body over 16 MiB, set well above the JSON escaping of 2 MiB of text"
    by: agent
    why: "The file and text limits are content rules like the other 422s, and a body cap at 2 MiB would refuse a push of exactly 2 MiB of text once JSON escaping grows it; 16 MiB matches the git-facts upload"
    rejected: [413 for every limit, a body cap equal to the text limit]
  - id: D24
    question: Which id and capability names does the server accept?
    answer: "An id is 1 to 64 bytes matching [a-z0-9][a-z0-9-]*, the change request change_id rule. A capability path is one or more /-separated segments, each matching [a-z0-9][a-z0-9-]*, as goodflows change validate 0.10.0 accepts"
    by: agent
    why: "Every stored id can then be linked by a change request (G4), and the capability rule is written down because the server cannot run the CLI"
    rejected: [allow a leading -, accept any path segment]
  - id: D25
    question: How do a delete, a change request open and a push of the same id interact when they race?
    answer: "They are serialized per (project, change id). A change request committed before the delete commits makes it 409. A push that commits after the delete starts a new change at version 1; one that commits before it is removed with the change"
    by: agent
    why: "A plain check-then-delete breaks A1, and opening a change request already takes a per-(project, change_id) lock to join"
    rejected: [check then delete without a lock]
  - id: D26
    question: Does the versions list page, and does a version record who pushed it?
    answer: "The versions list pages with limit (1 to 200, default 50), cursor and next_cursor, newest first. Each version shows its pusher's user_id to sk_ keys and null to pk_ keys"
    by: agent
    why: "Versions are kept forever (D12), the feature index version list pages the same way, and feature index versions and change requests already record and redact the actor this way"
    rejected: [return every version in one response, record no pusher]
  - id: D27
    question: Which body keys and input sizes does a push accept beyond the file limits?
    answer: "Exactly files and source at the top level and exactly commit, branch and dirty in source; any other key is 422, as on the other strict JSON routes. A path is at most 512 bytes; branch is 1 to 256 bytes with no control characters, the change request branch rule. A file containing U+0000 is 422 naming its path"
    by: agent
    why: "The existing strict routes refuse unknown keys, and unbounded paths or branch names would be stored forever and break indexes with a 500"
    rejected: [ignore unknown keys, no path or branch limit]
  - id: D28
    question: Which refusal wins when several apply, and what does a successful delete answer?
    answer: "413 for the body cap first, then 422 for the body shape, paths, limits and change.md, then 422 for qa-scenarios.md, then 409 for an archived change. A delete answers 204 with no body, and deleting an id that does not exist is 404"
    by: agent
    why: "The id must come from a valid change.md before the archived check can run, and 204 matches project delete"
    rejected: [409 before content checks, 200 with a body on delete]
  - id: D29
    question: Does each row of the change list carry the change requests that link it?
    answer: "Yes. Each row of GET /changes carries change_requests, every change request of the project whose change_id equals the row's id, as number and state ordered by number, and [] when none, in the shape the change read returns. sk_ and pk_ keys both see it. This amends D19, whose change list fields did not include it"
    by: agent
    why: "Found while building: tbrewer asked for it through the delegating thread. The CLI's D16 has goodflows change list print each change's linked change request numbers, and a pk_ key may list changes but gets 403 on the change read, so the list is the only route where it can see them. pk_ keys already read change request numbers and states on the change request routes, so this reveals nothing new"
    rejected: [linked change requests on the change read only]
  - id: D30
    question: Does the key access requirement state what a pk_ key sees in the versions list?
    answer: "Yes. In the versions list a pk_ key sees only each version's number, status, pushed_at, source and latest, with the pusher null, as D19 already says"
    by: agent
    why: "Found while building: the code renders only D19's fields to pk_ keys in the versions list, but the requirement said only that pk_ keys list versions with the pusher null, so it was silent on the other fields"
    rejected: [leave the field list to D19 alone]
  - id: D31
    question: "How are the build's four held questions settled: the push's strict JSON refusals, the versions list's 404 and 422, scenario 15's event count, and a code on the archived 409?"
    answer: "A push body that is not valid JSON is 400, and one that is not application/json is 415, as on the other strict JSON routes. On the versions list an unknown id is 404 for every key, pk_ included, and a malformed limit or cursor is 422. Scenario 15 step 2 expects one change_deleted event naming add-logout. The archived 409 body is errors: {error: change_archived, detail}"
    by: user
    why: "tbrewer's answers, given 2026-11-27, to the build's held questions: yes to each recommendation, with the change re-approved with these edits"
    rejected: [leave the transport refusals and the versions list's 422 unstated, 403 for pk_ keys on an unknown id's versions list, one event of any type naming add-logout, a detail message only on the archived 409]
left_to_builder:
  - Table layout, how file text and parsed fields are stored, and how the identical-push comparison is computed, as long as it compares the set of paths and every file's bytes
  - Project event type names and payloads, as long as each names the change id and, for a push, the version number
  - Response field names not fixed by D15 and D16, and the OpenAPI schema names
  - "Wording of errors a person reads, with the bar that each error names the input or state at fault and what to do next: the path, the field, the limit, or the linked change request numbers"
  - How each requirement is tested, with the bar that breaking the behavior of any Must scenario fails an automated test
---

## Why

tbrewer wants goodflows changes stored on the server before a change request exists for them, so the change a team plans is visible, with its history, from the start. Later a change request is created from a stored change. The Space this work comes from builds a UI that helps users manage changes, so the API must serve a UI as well as the CLI.

## Context

A goodflows change is a `goodflows/changes/<id>/` directory: `change.md` with `goodflows-change/1` front matter, spec deltas under `specs/<capability>/spec.md`, `qa-scenarios.md`, and `verification.md` once the build is verified. Today it lives only on disk; `goodflows change validate|verified|archive` work on the files.

The server already keys on the change id. `change_requests.change_id` links a change request to its change (`goodflows cr open --change <id>` sets it, even before code exists), change request `dependencies` are change ids, and an intent scenario set's `change` must equal the change request's `change_id`. Change requests block project deletion. The feature index is the closest pattern: each sync is an immutable version, an equal sync returns `duplicate: true` with `200`, a new one `201`, `sk_` keys write and `pk_` keys read. Change request reads redact content and personal fields for `pk_` keys. The project event feed (`GoodFlows.ProjectEvents`) records change request activity for live clients.

The companion CLI change `add-stored-changes` in agoodway/goodflows adds `goodflows change push|list|show|pull|versions|delete` against this API; its decision D30 records the contract it assumes, which D15 and D16 answer.

## Approaches

- **Files verbatim plus a few parsed fields (picked).** A UI shows the files, and the server does not track the CLI's format rules beyond what it relies on.
- **Parse goals, decisions and requirements into tables.** Richer queries for a UI, but every format change in the CLI needs a server change, and the server would grow a second validator.
- **One opaque archive per push.** Cheapest to store, but a UI cannot show what is inside without unpacking it.
