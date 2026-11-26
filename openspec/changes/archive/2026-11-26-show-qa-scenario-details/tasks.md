# Tasks

## 1. Reads

- [x] 1.1 Add `GoodFlows.ScenarioSets.Sections.split/2` (design D1); verify unit tests with the `goodflows-test` diff set v1 file and its six stored digests as a fixture (all match, heading line dropped), a set with group `###` headings and `####` scenarios, a heading inside a fenced block, CRLF line endings, a non-ASCII name, and a one-byte edit that makes one section `:unmatched`
- [x] 1.2 Add `VerifyRuns.scenario_details/2` (design D3); verify tests for a failed result with step, reason and two artifacts, an integer scenario ID, and an expired artifact
- [x] 1.3 Add `mdex` and `html_sanitize_ex` to `mix.exs` and `GoodFlowsWeb.ScenarioMarkdown.to_html/1` (design D2); verify tests that a numbered step with a nested `- Expect:` item renders as `ol > li > ul > li`, bold and code render, and `<script>`, an `onerror` attribute and a `javascript:` link do not survive

## 2. Table component

- [x] 2.1 Add the `:details` slot and `row_open` attr to `table/1` (design D4) and document them in `DESIGN.md` under `table/1`; verify a component test renders the details row only for open rows with the right `colspan`

## 3. Detail page

- [x] 3.1 Add the toggle column, `open_scenarios` assign and `toggle_scenario` event; verify LiveView tests that a row opens and closes, that `aria-expanded` follows, and that an open row stays open after a project event reload
- [x] 3.2 Render the scenario text in a `.scenario-markdown` block, or the unmatched note (design D1, D2); add the class to `app.css` under `@layer components` and to `DESIGN.md`; verify LiveView tests for a matched section showing its Why and Expect lines without the heading, a section with raw HTML rendering no `script` element, and a version whose digest does not match
- [x] 3.3 Render the failed step, reason and evidence list, and the no-result note (design D3); verify LiveView tests for a failed must, a `not_run` with a reason, an expired artifact and a set with no counted run
- [x] 3.4 Verify a LiveView test for a merged change request showing the same details from its stored verdict

## 4. Evidence download

- [x] 4.1 Add the route and `VerifyRunArtifactController` (design D5); verify controller tests for a redirect to the presigned URL, an expired artifact (404), an `uploading` run (404), an unknown artifact (404), a project of another account (redirect to `/dashboard`) and a signed-out user (redirect to log in)

## 5. Integration

- [x] 5.1 Render the page in both themes and at 400px wide with the verify-goodflows skill and inspect screenshots of an open row with a failed scenario and evidence, an open row with no result, and an unmatched section; verify the design tests in `test/good_flows_web/design/` pass
- [x] 5.2 Build the release Docker image and verify MDEx loads its precompiled NIF in it (render one section in a remote console)
- [x] 5.3 Run `mix precommit` in `app/` and verify it passes
