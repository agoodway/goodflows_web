# Proposal

## Why

The QA scenarios panel on the change request detail page lists each scenario's ID, name, priority and result, and nothing else. A reviewer who wants to know what a scenario checks, or why it failed, has to fetch the set file and the verify run through the CLI or API. Both are already stored: `scenario_set_versions.content` keeps the whole set file, with each scenario's Why line, numbered steps and Expect lines under `## Scenarios`, and `sections` keeps the CLI's SHA-256 of each scenario's section. The counted verify run's `document.results` keeps each scenario's `failed_step`, `reason` and `evidence` artifact IDs, and its artifacts are in object storage. The page loads the version's content today but renders only front matter names.

## What Changes

- **Expandable scenario rows.** Each row of a set's scenario table gets a toggle that opens a full-width row below it. Open rows stay open when the page refreshes on project events.
- **Scenario text.** The open row shows the scenario's section of the set file, Why line, steps and Expect lines, rendered from Markdown with MDEx and sanitized with html_sanitize_ex, without the heading line the row already shows. The server splits the body with the same rules as `goodflows cr scenarios upload` and shows a section only when its SHA-256 equals the digest stored for that scenario; otherwise the row says the text could not be matched to the set file.
- **Run result details.** The open row shows, from the verify run the row's result came from, the failed step and reason when set, and the scenario's evidence: each artifact's path, content type and size, linking to a download, or marked `Expired` once retention deleted it.
- **Evidence downloads.** A new dashboard route, for signed-in members of the project's account, redirects to a short-lived presigned URL for one artifact of one final verify run. Presigned URLs are made per click and never rendered into the page.
- Merged and closed change requests show the same details from the stored verdict's versions and runs.
- Out of scope: rendering Mermaid diagrams, the set's other body sections (summary, Setup, Checklist, Regression checks, Not covered, Questions for the developer) and group setup headings, intent coverage rows, inline previews of artifacts, results from runs other than the one the row's result came from, and any API change.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `change-request-dashboard`: scenario rows expand to show the scenario's text, the run's failed step and reason, and evidence links; a new artifact download route for members.
- `qa-scenario-sets`: a new requirement lets the dashboard split a stored body into scenario sections for display, while uploads keep parsing only the front matter.

## Impact

- New `GoodFlows.ScenarioSets.Sections`: splits a set body into scenario sections with the CLI's rules and checks them against the stored digests. Not called on the upload path.
- `GoodFlows.VerifyRuns`: a read of the results and artifact rows of a few runs, for the page.
- `GoodFlowsWeb.CoreComponents.table/1`: an optional `:details` slot and `row_open` function that render a full-width row under an open row; `DESIGN.md` documents it.
- `GoodFlowsWeb.ChangeRequestLive.Show` and its tests: toggle event, open-row state kept across reloads, the expanded row.
- New `GoodFlowsWeb.VerifyRunArtifactController` and a route in the `:load_account` dashboard scope.
- New `GoodFlowsWeb.ScenarioMarkdown`: renders a section with MDEx (raw HTML off) and sanitizes it with `HtmlSanitizeEx.markdown_html/1`; a `.scenario-markdown` class in `app.css` styles the result.
- New dependencies: `mdex` (precompiled NIF) and `html_sanitize_ex`.
- No migration, no change to API responses or the OpenAPI document.
