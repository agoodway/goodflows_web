# project-overview Specification

## Purpose

Gives account members one dashboard page per project that shows, at a glance, whether its workflows pass on the default branch, what ran recently, which change requests need attention and which goodflows changes are planned, and links to the run, change request and Changes pages.

## Requirements

### Requirement: The project overview is scoped to the account
The dashboard SHALL serve a project overview at `/dashboard/accounts/:account_id/projects/:slug`. It MUST require a signed-in user who is a member of the account, and every member, whatever their role, SHALL see it. A slug that names no project of the account MUST redirect to the account's Projects page with the error flash `Project not found` and MUST NOT show another account's data.

#### Scenario: Member opens the overview
- **WHEN** a signed-in member with role `member` opens the overview of project `web` in their account
- **THEN** the page shows `web`'s slug, its default branch, its Change requests card, below it its Changes card and below that its Runs card

#### Scenario: Project of another account
- **WHEN** a signed-in user opens the overview with their own account ID and the slug of a project that belongs only to another account
- **THEN** they are redirected to their account's Projects page with the flash `Project not found`

### Requirement: The overview shows navigation context
The overview SHALL keep the Projects item active in the sidebar and show the breadcrumbs Dashboard, Projects and the project slug.

#### Scenario: Breadcrumbs
- **WHEN** a member opens the overview of project `web`
- **THEN** the breadcrumbs read Dashboard, Projects, `web`, and the Projects sidebar item is active

### Requirement: The Runs card shows default branch health
The Runs card SHALL list, for each workflow that has a run on the project's default branch, that workflow's newest run there (by `started_at`, then `run_id`), with its outcome, start time and duration. A run whose checkout was dirty SHALL count. Each line SHALL link to the run's detail page.

#### Scenario: Latest run per workflow
- **WHEN** project `web` has default branch `main`, workflow `ci` ran on `main` and failed at 10:00 and passed at 11:00, and workflow `lint` ran only on `feature/x`
- **THEN** the card shows one line for `ci` with outcome passed and no line for `lint`

#### Scenario: Dirty run counts
- **WHEN** the newest `ci` run on `main` has `source.dirty` true
- **THEN** the card shows that run for `ci`

### Requirement: The Runs card shows recent runs
The Runs card SHALL show the project's 5 most recent runs from any branch, by `started_at` then `run_id`, excluding runs folded under a stored parent as the run list does, with the same row content as the run list, and a link to the run list.

#### Scenario: Recent runs
- **WHEN** a project has 8 runs and none has a parent
- **THEN** the card shows the 5 newest and a link to the run list

### Requirement: The Runs card has an empty state
A project with no runs SHALL show an empty state in the Runs card that explains how to upload a run with the `goodflows` CLI and links to the account's API keys page.

#### Scenario: No runs
- **WHEN** a member opens the overview of a project with no workflow runs
- **THEN** the Runs card shows the empty state with a link to API keys

### Requirement: The Change requests card summarizes active change requests
The Change requests card SHALL show how many `draft` or `open` change requests have each verdict state (`mergeable`, `needs_review`, `blocked`, `pending`), counting one with no stored verdict as `pending`, and the 5 most recently updated `draft` or `open` change requests with their verdicts, each linking to its detail page, and a link to the change request list.

#### Scenario: Verdict counts
- **WHEN** a project has open change requests with verdicts `blocked`, `blocked` and `mergeable`, a draft with no verdict, and a merged change request
- **THEN** the card shows 1 mergeable, 0 needs review, 2 blocked and 1 pending

#### Scenario: No active change requests
- **WHEN** a project has only merged and closed change requests
- **THEN** the card shows zero counts, says no change request is active, and links to the change request list

### Requirement: The Changes card summarizes active stored changes
The Changes card SHALL show the number of the project's stored changes whose latest status is `proposed` and the number whose latest status is `approved`, the 5 most recently pushed changes with those statuses, each linking to its detail page, and a link to the Changes list. A project with no stored changes SHALL show an empty state in the card that explains pushing a change with `goodflows change push` and that the command needs a goodflows release newer than 0.10.0. A project whose stored changes are all archived SHALL show both counts as 0 and say that no change is active.

#### Scenario: Counts and active changes
- **WHEN** a project has 3 `proposed`, 4 `approved` and 2 `archived` stored changes
- **THEN** the card shows 3 proposed and 4 approved, lists the 5 most recently pushed active changes and links to the Changes list

#### Scenario: No stored changes
- **WHEN** a member opens the overview of a project with no stored changes
- **THEN** the Changes card shows the push empty state

#### Scenario: Only archived changes
- **WHEN** every stored change of a project is archived
- **THEN** the card shows 0 proposed and 0 approved and says no change is active

### Requirement: The overview updates live
The overview SHALL refresh every card when a run of the project is stored or a project event is recorded, without a page reload.

#### Scenario: New run
- **WHEN** a member has the overview open and a run of workflow `ci` on the default branch is uploaded
- **THEN** the `ci` line and the recent runs show that run without a reload
