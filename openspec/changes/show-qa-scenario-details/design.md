# Design

## Context

See proposal.md for motivation. What the detail page has today (`GoodFlowsWeb.ChangeRequestLive.Show`):

- `set_evidence/4` loads the graded version with `ScenarioSets.get_version/3`, so `version.content` (the whole set file) and `version.sections` (`[{id, sha256}]`, sent by the CLI) are already in memory on every load. The page reads only `front_matter["scenarios"]` names.
- Each verdict row (`Rules.scenarios_view/1`) carries `run_id`, the newest counted run of that set; every row of a set has the same `run_id`, or nil when the set is not graded or no counted run grades it.
- `verify_runs.document` holds `results` (`{id, result, failed_step, reason, evidence}`) and `artifacts` (`{id, path, content_type, size, sha256}`); `verify_run_artifacts` holds `artifact_id`, `object_key` and `expired`. `VerifyRuns.download/1` presigns a GET with the cache download TTL.
- The goodflows CLI (`src/change_requests/markdown.rs`, `sections/3`) defines a section: under the body's `## Scenarios` heading up to the next heading of level 2 or less, a level 3 or 4 heading `<id>. <name>` with `<id>` in the front matter starts a section that runs to the next heading of the same or a higher level, or the end of the file. Headings inside ``` or ~~~ fences do not count. The section's bytes, heading line included, are hashed.
- The page reloads 500 ms after any project event and rebuilds every assign in `load/2`.

The six sections of change request #1 in `goodflows-test` (diff set v1) were split with a port of those rules and all six SHA-256s equal the stored `sections`.

## Goals / Non-Goals

**Goals:**
- Show everything stored about each graded scenario on the row that lists it: its text from the set file and, from the run its result came from, the failed step, reason and evidence artifacts.
- Show text only when it is provably the text the uploader's CLI hashed for that scenario.
- Render the text as Markdown without letting uploaded content put scripts, styles or unsafe links on the page.
- No migration, no API change.

**Non-Goals:**
- Rendering Mermaid diagrams or other fenced languages beyond a code block.
- Showing the set's other body sections (Setup, Checklist, Regression checks, Questions for the developer) or intent coverage rows.
- Results or evidence from runs other than the one the verdict used.

## Decisions

### D1. A server-side splitter that matches the CLI, checked against stored digests

New `GoodFlows.ScenarioSets.Sections.split(content, sections)` returns `%{id => {:ok, text} | :unmatched}` for each `{id, sha256}` in `sections`. It ports `markdown::sections` on bytes (Elixir binaries are bytes, so offsets match Rust's): find the body after the front matter, collect ATX headings (1 to 6 `#` then a space) outside fences, take the `## Scenarios` range, and cut each level 3 or 4 heading whose title before the first `". "` is a known ID. A section is `{:ok, text}` only when `sha256(section) == sha256` from `sections`; otherwise `:unmatched`. `text` is the section's Markdown without its first line, since the row already shows the ID and name, with leading and trailing blank lines trimmed; D2 renders it.

Checking the digest makes drift between the two splitters visible instead of silent: if the CLI's rules change and the server's do not, the row says the text could not be matched rather than showing the wrong scenario's steps. The upload path is unchanged; the server still does not check section digests against the body on upload (qa-scenario-sets).

A section that is not found, appears twice, or does not match is `:unmatched`. The CLI refuses to upload a set with a missing or duplicate heading, so these only occur for sets uploaded by other clients.

Alternative considered: show the whole body once per set. Rejected because a reviewer reading one failed scenario would scroll through all of them, and the row is where the result is.

Alternative considered: split on upload and store the sections. Rejected because it needs a migration and a backfill, and the split is cheap (a set is at most 1 MiB).

### D2. Render with MDEx, sanitize with html_sanitize_ex

New deps: `{:mdex, "~> 0.14"}` and `{:html_sanitize_ex, "~> 1.5"}`. New `GoodFlowsWeb.ScenarioMarkdown.to_html(text)` runs:

1. `MDEx.to_html!(text, extension: [table: true, strikethrough: true, autolink: true], render: [unsafe: false], syntax_highlight: nil)`. `unsafe: false` drops raw HTML blocks and inline HTML at the parser. Syntax highlighting is off so code blocks carry no inline `style` attributes for the sanitizer to strip. The task-list extension stays off, because the sanitizer's allow list has no `input` and checklist boxes belong to the set's Checklist section anyway.
2. `HtmlSanitizeEx.markdown_html/1` on the result, as a second layer: only its Markdown tags (`p`, `ol`, `ul`, `li`, `code`, `pre`, `strong`, `em`, `a`, `table` and the like) and their listed attributes survive, and `a href` keeps only `http`, `https` and `mailto`.
3. `Phoenix.HTML.raw/1` of the sanitized string. This is the only `raw/1` on the page, and it is applied only to the sanitizer's output.

The two layers are deliberate: the parser setting keeps raw HTML out in the normal case, and the sanitizer bounds what reaches the page if an MDEx option or default changes. Images in the allow list point at `http`/`https` URLs, which the page's CSP (`img-src 'self' data: blob:`) already blocks, so a remote image cannot track readers; it shows as a broken image, which is acceptable for a format that does not use images in steps.

Rendering runs only for open rows (D4), when a row opens and on each reload, so a refresh renders at most the sections a member has open, each at most 1 MiB and usually under a kilobyte.

The rendered block uses a new `.scenario-markdown` class in `app.css` under `@layer components`: list markers and indents, paragraph spacing, `code` and `pre` in the tag style (2px radius, mono), `pre` scrolling inside its own box, tables in the data-table border style, links in the `text_link/1` color. No typography plugin is added. The class is documented in `DESIGN.md`.

Mermaid fences render as code blocks. Rendering diagrams is out of scope.

Alternative considered: plain pre-wrapped text. Rejected by tbrewer; numbered steps with nested Expect items and bold labels read much better rendered.

Alternative considered: Earmark. Rejected in favor of MDEx (CommonMark and GFM via comrak, maintained, ships precompiled NIFs).

### D3. Run details come from the row's run

For each set with a `run_id`, the page reads that run's results and artifacts with a new `VerifyRuns.scenario_details(project, run_ids)` that selects only `run_id`, `document->'results'` and `document->'artifacts'` plus the artifact rows' `artifact_id` and `expired`, and returns `%{run_id => %{scenario_id => %{failed_step, reason, evidence: [artifact]}}}` with each artifact's `id`, `path`, `content_type`, `size` and `expired`. At most two runs are read (one per set). Scenario IDs are matched in string form, as grading does.

The open row shows `Failed at <failed_step>` and the reason when set, for any result (a `not_run` result usually has a reason and no step). Evidence lists each artifact in the result's order: path, content type, human-readable size, and a `Download` link, or `Expired` without a link. A row whose set has no counted run says `No verify run result for this scenario.`

### D4. Open rows live in a server assign that survives reloads

`table/1` gains an optional `:details` slot and a `row_open` function of the row. When `row_open.(row)` is true, a second `<tr>` follows the row with one `<td colspan>` rendering the slot; below `md` it shows full width without a label, like the `:span` cell. The scenario table passes a toggle button in its first column (`aria-expanded`, `aria-controls` naming the details row, accessible name `Show details for <id>` / `Hide details for <id>`).

`Show` keeps `open_scenarios`, a `MapSet` of `{source, id}`, set in `mount/3` and changed only by a `toggle_scenario` event. `load/2` does not touch it, so a refresh keeps rows open; a key whose scenario no longer exists simply matches no row.

Alternative considered: `<details>` with `JS.ignore_attributes(["open"])`. Rejected because `<details>` cannot wrap a table row and its expanded content without breaking the table; and a server assign needs no client code and is testable in LiveView tests.

### D5. Evidence downloads go through a members-only redirect

New route in the `/dashboard/accounts/:account_id` scope, after `:load_account` (which refuses users who are not members of the account):

`GET /dashboard/accounts/:account_id/projects/:slug/verify-runs/:run_id/artifacts/:artifact_id`

`GoodFlowsWeb.VerifyRunArtifactController.show/2` resolves the project with `Projects.get_project/2`, the run with `VerifyRuns.get/2`, and the artifact by `artifact_id`. It redirects (`302`, external) to `VerifyRuns.download/1`'s URL when the run is `final` and the artifact is not expired; it responds `404` for an unknown project, run or artifact, a run that is not `final`, or an expired artifact. Presigned URLs are made per request and never rendered into the page or logged, so a page left open does not hold expired URLs and the HTML holds no bearer links.

Every member may download, matching who may view the page and the API, where any `sk_` key of the account may download. The page and the route do not show artifacts to `pk_` keys because neither is reachable with an API key.

### D6. Frozen change requests show the same details

A merged or closed change request's verdict names its versions and run IDs; versions and final runs are immutable, so the details read the same way. Artifacts expire 30 days after merge, and their rows then show `Expired`.

## Risks / Trade-offs

- [The splitter drifts from the CLI] → The digest check turns drift into `:unmatched`, not wrong text. A unit test uses the real `goodflows-test` diff set v1 file and its stored digests as a fixture, so a port bug fails CI.
- [Each refresh re-splits up to two sets and reads up to two runs' results] → Content is already loaded; splitting is linear in its size. The run read is one query over at most two rows with a JSON projection. Refreshes are debounced to two per second per open page.
- [Rendering untrusted Markdown] → Two layers: MDEx with `unsafe: false`, then `HtmlSanitizeEx.markdown_html/1`; tests feed script tags, event-handler attributes and `javascript:` links through the real pipeline and assert none survive. The CSP has no `'unsafe-inline'` for scripts, so an escaped script would still not run.
- [MDEx is a NIF] → It ships precompiled binaries for the release's Linux targets; the Docker build must fetch the one for its platform, checked in task 5.2.
- [Large evidence lists] → A result's `evidence` is bounded by the run's 200 artifacts; the list is in the collapsed row, so it costs nothing until opened beyond the rendered markup. The details row renders only when open.
