---
format: goodflows-verification/1
change: add-stored-changes-dashboard
base: 3aee6c4c7a2cf731b314b27c4cda07f8ec41cc5e
deltas:
  "stored-changes-dashboard": 60a433e4c1ff90e8f16a3a5de0cbc91a842bf61dd898c56b03186c79fe27fff3
files:
  "app/assets/css/app.css": 2327af91be974bd98bedc57a275ecf9cba155559cb06e46284f84d9174a87d02
  "app/lib/good_flows/stored_changes.ex": 54a7d71b869d4540bf118c42c7ff9fb884863484a542f83afa58ca7dd820ade9
  "app/lib/good_flows/stored_changes/files.ex": 8032ca6ae6ac4e66f6e8befa557adddb64f5d4e59905bd35546cd5f5b5c72023
  "app/lib/good_flows_web/components/stored_change_components.ex": f02863ca8d5c59c825be6f1ad982f3b683a90ba840afc4786f305dc653b9b5c3
  "app/lib/good_flows_web/live/change_request_live/show.ex": c0fc01c36d40221759c9d9913340362c25eead55d9108a11ca5a4c260064ffc1
  "app/lib/good_flows_web/live/project_live/show.ex": fd1a1d0a7dc4767eedee96fa0ff46776c88486544096750910d42382f0339320
  "app/lib/good_flows_web/live/stored_change_live/index.ex": 814e543a5347c87116ab8587ace15f6ad7776456f63287fb2fc2e7b1b4e21e4a
  "app/lib/good_flows_web/live/stored_change_live/show.ex": bbb4b191d2252ffde54fd9b7c6053c5e62c7e228a49177fa0eea33bea8a3cd7a
  "app/lib/good_flows_web/router.ex": 6fb39b731c269c6033aca4e1c864ef78b313afae04a1a0d62837cdbb03a47628
  "app/lib/good_flows_web/scenario_markdown.ex": 8ec53e1ff997f5731dee8e9b4cfb5ce0adabb9cc58b5beafa1c40116ac835847
  "app/test/good_flows_web/live/change_request_live_test.exs": 3f3ee9d3923d873fcea0939ceddd049c7f5b90acb34b46dd102bccaa7c61ad09
  "app/test/good_flows_web/live/project_live/show_test.exs": 7f60447519f66ce1d990f24e9adf900d8b19e18f562bcc6fb1c512bba87bf53f
  "app/test/good_flows_web/live/stored_change_live_test.exs": 5d61b60033b93b43226ffbd582954d3ba24cb583d604e4835c01050313b05e21
  "app/test/good_flows_web/scenario_markdown_test.exs": eb313ff5f01ffa8d996fab687c405e8dd37459d7f1cac4cf6f62403e7f94695c
  "openspec/specs/change-request-dashboard/spec.md": 928451bdd34f832a80058c2565ae6eeaf93505b990d26074bbd032b3d036400b
  "openspec/specs/project-overview/spec.md": 56f37888f523da9bd0b2a170218603db822fcc5bd8382715f99fa88dcf612d0e
open: []
---

# Verification: add-stored-changes-dashboard

`held.md` is empty, so nothing is open.

## What each verifier checked

- **verify-spec-1 (spec to code):** walked each ADDED requirement of the stored-changes-dashboard delta against the branch, and ran the LiveView tests (101 tests, 0 failures). Found 3 suggestions: upper-case link schemes lost their href, image sources were not filtered, and a delete during load crashed the page.
- **verify-drift-1 (code to spec):** checked the delta edits since approval (D27), the durable OpenSpec edits D18 calls for, and that qa-scenarios.md did not change. Found that `?version[]=1` crashed the page, and that the requirement said nothing about images.
- **verify-bars-1 (decisions and bars):** ran validate, the LiveView, design-guard and Markdown tests, then measured the line diff. Myers diff was quadratic: 2,000+2,000 lines took 2.9 s and 1.3 GB, and larger files killed the VM. Also found test gaps (byte limit, UTF-8, D27 cases, link forms), missing next-step text in notices, `dom_id` collisions, and a card link built without `~p`.
- **verify-qa-1 (QA run mode):** drove every scenario in qa-scenarios.md with verify-goodflows, with a visual pass against DESIGN.md. Found the whitespace in the skip row, a 175,000 px plain-text block, and a monospace "Not given".
- **fix-1:** fixed all 14 rows from round 1. It set a per-file diff cap of 1,000 lines (D28) computed on the connected mount, filtered images to http(s) (D29), lower-cased schemes, made load handle a deleted change, guarded `parse_version`, added the next-step notices, base64 `dom_id`, the `~p` card link and the CSS fixes, and added tests for each row.
- **verify-recheck-2:** confirmed 13 of the 14 fixes. Found that the per-file cap still let one version of 100 files at the cap take 24.7 s.
- **verify-qa-2:** re-drove every scenario after fix-1, because fix-1 changed how the page loads and diffs. Found two suggestions: a monospace dash for a missing Size or Door, and the flash for a non-string version.
- **fix-2:** added a per-version budget of 1,000 diffed lines in path order (D30), muted dashes, and a separate flash sentence, with tests.
- **verify-recheck-3:** confirmed fix-2 with worst-case timings (at most about 0.3 s) and page-open timings in the running app (under 2 s). It re-drove scenarios 2, 6 and 16 only. Found that D30 counted unchanged lines, so ordinary edits lost the diffs D4 promises (a person row), and that no test covered a small file after a budget skip.
- **fix-3:** both limits now count only the changed region, after trimming the common leading and trailing lines (D31). Added a 3-context-line skip row, a three-file test, a long-file test and a test of a small file after a budget skip. Mutation checks failed as expected.
- **verify-recheck-4:** confirmed both rows. It checked the rows with a 5,000-case property check (0 mismatches), re-measured the worst cases (at most about 0.34 s; the page opens within 2 s, slowest about 1.5 s), and confirmed D31's provenance, that no `by: user` decision was edited, and that qa-scenarios.md is unchanged. It re-drove scenario 16 and a realistic three-file push, and the full suite passed (1966 tests). Rows: none.

## QA runs

- `.verify/goodflows/20261128T100756Z-6daa969/`: verify-qa-1, all scenarios.
- `.verify/goodflows/20261128T103857Z-6daa969/`: verify-qa-2, all scenarios again.
- `.verify/goodflows/20261128T111217Z-6daa969/`: verify-recheck-3, scenarios 2, 6 and 16 only.
- `.verify/goodflows/20261128T113218Z-6daa969/`: verify-recheck-4, scenario 16 and the realistic push only.

The later runs re-drove only the scenarios their fixes affected, so their outcome is `partial` by design. Every run folder passed `goodflows cr validate`. Each run was made on a dirty tree, so it predicts the verdict and was not uploaded.

## Not verified

No check was reported not_verified. Timings come from a 4-core orb. Visuals were checked in light mode at 1280 px only.
