## MODIFIED Requirements

### Requirement: Change request pages are reached from the Projects page
The Projects page SHALL link each project's slug to the project overview, which links to the change request list. The pages SHALL keep the Projects item active in the sidebar and show the breadcrumbs Dashboard, Projects, the project slug linking to the project overview, Change requests and, on the detail page, `#<number>`.

#### Scenario: Projects page links to the overview
- **WHEN** a member views the Projects page
- **THEN** each project slug links to that project's overview

#### Scenario: Projects page links to the list
- **WHEN** a member opens a project's overview from the Projects page
- **THEN** the overview links to that project's change request list

#### Scenario: Breadcrumb links to the overview
- **WHEN** a member opens change request 42 of project `web`
- **THEN** the breadcrumb `web` links to `web`'s overview

## ADDED Requirements

### Requirement: Workflow runs at head link to their runs
Each run in the detail page's workflow runs panel SHALL link to that run's detail page in the run history.

#### Scenario: Required workflow run
- **WHEN** change request 42's panel shows run X for required workflow `ci`
- **THEN** the `ci` row links to run X's detail page
