---
format: goodflows-verification/1
change: add-stored-changes
base: c9f00e282448cedf2850788105cae33248590a6d
deltas:
  "stored-changes": c2661e3c1459e6fac3f119345e7382c3d68a132f2ac2a091f850a51ac01bec81
files:
  ".agents/skills/verify-goodflows/features/README.md": e428ec5132dd1ecb112479433d6b30d7202dac3da878b6f529718a1dcdc436eb
  ".agents/skills/verify-goodflows/features/stored-changes-api.md": 0d2ffd5f399d32c950c04620f14f31b0b08602d35a482b46ad9e2e073f6e11a2
  "app/lib/good_flows/change_requests.ex": 6ca60623a0648064695205be0d9b20f4ded7716860075bd802296d5b634f411d
  "app/lib/good_flows/project_events.ex": 001623bb814dcbab52cff3a9f46f19588143be838b6ad415f47eed8ab2097cc8
  "app/lib/good_flows/projects.ex": 84069582e7221531793da52f7a72969518e37ebb611d006bd4743d9494caad08
  "app/lib/good_flows/projects/project.ex": c1a1974812bdf26e88b74cf68f7fb3a05ec928ac030d7d64325c12630379c685
  "app/lib/good_flows/scenario_sets/document.ex": 5de7975ecdda601f5dd92a66c2b245943569d68e17add450dbd38b9374f8a06f
  "app/lib/good_flows/stored_changes.ex": 7ceb0e5b96dadb3c77b3f63faab7d6637c2e89a77470a9c0b233f1d34e2a9938
  "app/lib/good_flows/stored_changes/change.ex": 41c97c38adb5d887a19b88a3e06860f93b17d791e57ce39c6a8f97970c5f1448
  "app/lib/good_flows/stored_changes/push.ex": 8452aeca22c5491989f3aada99fd1bbb6080d9665e08bb1e652e8e541ba882dd
  "app/lib/good_flows/stored_changes/version.ex": a216c3808b1d747f54503dacbe030000ac38b7148ebf38073d57d97647782ac2
  "app/lib/good_flows_web/controllers/api/v1/project_controller.ex": cfd99dd21c285fdcab441603bae926d12d1244a9f0b18caf7800a8c97524a2c3
  "app/lib/good_flows_web/controllers/api/v1/stored_change_controller.ex": 8e40041560cd0baca1aed089519bbe74d77af20fad311eb817c600c96a96ecdc
  "app/lib/good_flows_web/controllers/api/v1/stored_change_json.ex": ae68cf282e11524e5c2704ab64c600a222633fbbd4e646ac206d6c434123e6e8
  "app/lib/good_flows_web/controllers/fallback_controller.ex": fe9a65c865a7e4680291fff0faadfe26d1eb9297e868fc49b1c7e1093e4583dd
  "app/lib/good_flows_web/plugs/body_parsers.ex": c2dc1ce364c8fd9191be50447feacf7933b167928f671553b410d263fb2f8e25
  "app/lib/good_flows_web/plugs/json_body.ex": 3a5f501a16b8cec084560c3d0703cb6530d49744a2714d218bfcd80e858b6232
  "app/lib/good_flows_web/router.ex": 65d19db35f4dcccc76f1f32eaeddc58d5f50eb5c78e9b0c91dc70a836a628b05
  "app/lib/good_flows_web/schemas/project_event.ex": bb3f939654ff43d34289550cbcf30b9b08c7e965b00bbe6192c1cb5228c48729
  "app/lib/good_flows_web/schemas/stored_change_archived_response.ex": 55ba330f82f950d99bced05a55250e183c2d6fc4bd8fa9834af1bc701b9df9b5
  "app/lib/good_flows_web/schemas/stored_change_file.ex": 46b9cea4997c8e138ea4c5ae0b4280b376c9dd133401e5344605413b0b227b63
  "app/lib/good_flows_web/schemas/stored_change_link.ex": 1f621bcd32a5c38453ca915da9b004e412d8e5b4ae6fa4708164d8db3cfa2653
  "app/lib/good_flows_web/schemas/stored_change_linked_response.ex": 99fb3e6d7f8c1c7cf7437cf565e9319ba7c7c827500dd3a1309cea6c77a308ef
  "app/lib/good_flows_web/schemas/stored_change_list_response.ex": 99f4a26e3d497804b1b9fb76801545e7029b229a3a99bf14e5ecb1019cd16032
  "app/lib/good_flows_web/schemas/stored_change_push_request.ex": 0ca44e869477d1f4ad4e2b59e23f85f80b94dcbac4e90cea0567d2e5f9291f56
  "app/lib/good_flows_web/schemas/stored_change_push_response.ex": 643c6e2e32368e303109248589ff835517218125d4b1a05c0f32b15b529ea420
  "app/lib/good_flows_web/schemas/stored_change_response.ex": d2d6cb5f43a54e8e2096b605199c0d3a43ecac530b57c271827d6fa7f5d2277f
  "app/lib/good_flows_web/schemas/stored_change_source.ex": 8a0367ede2e41e12662bf8f8af2154692e4d948ed76b19c65c5529dd60ae4d43
  "app/lib/good_flows_web/schemas/stored_change_version.ex": ebeb0dfb1dd81144749ba7ab6f7febd3cb4d019db79a95fcf141ff42d3b90f5d
  "app/lib/good_flows_web/schemas/stored_change_version_list_response.ex": 2c7714451b704118d7a23737cf2e26ac76a6ffeb42b27b00388fc369408533af
  "app/lib/good_flows_web/schemas/stored_change_version_response.ex": 2e35661b2ee1b8a845f6719837693c0a58d1993e69957bb6146d0bb981a02542
  "app/priv/repo/migrations/20261127175802_create_stored_changes.exs": 2fa898685a9eee7aeeea48cb0b0f3d9a65fa4c49c0d330b0937cd9ee70ac85a2
  "app/test/good_flows/migrations/create_projects_migration_test.exs": dc943af2a777965a84d2bafee04e62c6f32527627aa7808ff12fdc047694dc92
  "app/test/good_flows/stored_changes_concurrency_test.exs": d095e822ac09033729371bcf87103543e12cb4ed0e9e7a893b79c3a05ac5efcd
  "app/test/good_flows_web/controllers/api/v1/openapi_test.exs": 7825e0d53bba1003853f59837611cf87593f6bbb76630e8c4a0b02824c0f78e6
  "app/test/good_flows_web/controllers/api/v1/stored_change_controller_test.exs": 051299987e4b7bf9c5544d295d4260d3b84168bc691ed6239a7b3e12dec5136f
  "openspec/specs/project-events/spec.md": 6274102e0d64ff23a47b620bbf8793316e88ecff343e2a1f85486c4db2d760eb
  "openspec/specs/projects/spec.md": cf37c6854ff4f97fb7b3b0c560d4d2214fed6abf184b09013058d78a87e3efe7
open: []
---

# Verification: add-stored-changes

What each verifier checked. Reports are under `.goodflows/build/add-stored-changes/`.

- **verify-spec-1** (spec to code): went through all 18 ADDED requirements of the `stored-changes` delta and the D22 edits to `openspec/specs/projects/spec.md` and `openspec/specs/project-events/spec.md`. 17 requirements were built as written. One row (spec-1): the push's OpenAPI operation did not list 408. Targeted tests: 53 tests, 0 failures.
- **verify-drift-1** (code to spec): matched each client-visible behavior to a requirement, including the edits to existing modules (`change_requests.ex`, `document.ex`, `json_body.ex`, `body_parsers.ex`, the fallback, projects and project events). Rows: drift-1, the same missing 408. drift-2, the versions-list 422 for a malformed `limit` or `cursor`, which no requirement states; that question went to a person and is answered by D31.
- **verify-bars-1** (decisions, goals, anti-goals, left_to_builder bars): checked D1 to D28, G1 to G4, A1 and A2, N1 to N3. Rows: bars-1, a branch C1/DEL control-character test. bars-2, error details for the 403 and 404 answers. bars-3, the `pk_` versions-list fields go past D19. bars-4, the delete race test could not fail. bars-5, versions-list paging tests, added by fix-4 after D31.
- **verify-qa-1** (live QA): drove all 18 scenarios over the JSON API with `sk_` and `pk_` keys on a fresh seeded instance, run `20261127T181359Z-966c8ba`. 18 of 18 passed. Rows: qa-1, no feature file mapped the stored-change code. qa-2, the wording of scenario 15's step 2, answered by D31.
- **fix-1**: repaired drift-1 (408 in the OpenAPI document), bars-1 (DEL and U+0085 branch cases), bars-2 (specific 403 and 404 details), bars-3 (`pk_` versions-list fields), bars-4 (two lock-ordered delete race tests driven through `pg_locks`), qa-1 (the `stored-changes-api` feature file) and extra-1 (D29: each list row carries `change_requests`). It showed each fix's test failing against a mutation of the code.
- **verify-specdrift-2** (fix-1 in both directions): every fixed requirement was built as written. D29 is recorded correctly and loads its links in one query per page. Row sd2-1: no requirement text stated the `pk_` versions-list restriction.
- **verify-barsqa-2** (fix-1 bars and live QA): no anti-goal was violated, and each changed test would fail on a plausible wrong implementation. The live rerun, `20261127T183723Z-966c8ba`, passed scenarios 1, 2, 8, 10 to 15 and 18, plus a hand check of D29. Rows: bq2-1 (no project filter test) and bq2-2 (no number-order test) for `page_links`.
- **fix-2**: repaired sd2-1 (D30, plus the requirement sentence), bq2-1 (a change request in a second project) and bq2-2 (rows stored out of number order). Each was shown failing against a mutation.
- **verify-3** (fix-2): confirmed all three repairs, re-running the `page_links` mutations in a scratch copy. No rows.
- **fix-3**: repaired the two `mix credo --strict` rows from the close gate. `race/2` now delegates to `await_go/3`. `delete_project/2` now uses an ordered `@delete_blockers` list in the same order as the old `cond`. No credo disable comments were added and `.credo.exs` was not changed. Targeted tests: 73 tests, 0 failures.
- **Held questions answered (D31)**: the four questions held open at close-2 were answered by tbrewer, who said yes to each recommendation and re-approved the change. They are recorded as decision D31 (`by: user`): the push's 400 and 415, the versions list's 404 for every key and 422 for a malformed `limit` or `cursor`, the wording of scenario 15 step 2, and the archived 409's `errors.error` `change_archived`.
- **fix-4**: applied D31. The three requirements now state the answers and cite D31. The versions-list 404 names the id. The archived 409 carries `error: "change_archived"` and has a new `StoredChangeArchivedResponse` OpenAPI schema. `qa-scenarios.md` scenario 15 step 2 now reads "one `change_deleted` event naming `add-logout`", and no other line changed. New tests cover 400/415, versions-list paging, its 422s and the 404 for both key types, and the coded 409. Full `mix test`: 1913 tests, 0 failures.
- **verify-4** (fix-4): verified all four answers against the requirement text, the code and the live API, run `20261127T192825Z-fb7fe25`. Scenarios 2, 7, 9, 12 and 15 passed. D31 is cited on all three edited requirements, and nothing else in `change.md` or `qa-scenarios.md` changed. One row, v4-1: no test checked that the push's 409 references `StoredChangeArchivedResponse`. The orchestrator fixed it with a test in the OpenAPI route test that asserts the 409 `$ref` names that schema.
- **Close gate**: `goodflows run ci --env orb` passed all 8 jobs (compile, test, deps, format, credo, doctor, sobelow and dialyzer) after fix-3, and again after fix-4 and the v4-1 test.

## Not verified

- **openspec CLI.** It is not installed, so the D22 edits to `openspec/specs/projects/spec.md` and `openspec/specs/project-events/spec.md` were reviewed against the code but not validated by openspec.
- **verify-barsqa-2 not_run.** Scenarios 3, 4, 5, 6, 7, 9, 16 and 17 were not rerun live after fix-1, because the repair did not touch them. All of them passed in verify-qa-1. Scenario 17 (concurrent pushes) was judged from the tests, since the repair touched the delete race and not the push race.
- **Live runs on a dirty tree.** Both live runs, verify-qa-1 and verify-barsqa-2, were made before the commit. Neither was uploaded, so goodflows does not count either one.
- **No live run of fix-2 and fix-3 on their own.** Those repairs were checked with tests and the close gate. verify-4's live run included them, but drove only scenarios 2, 7, 9, 12 and 15; the other scenarios were not_run there, because fix-4 did not touch them.
- **Live runs on a dirty tree, again.** verify-4's run was built from `fb7fe25` plus the uncommitted fix-4 diff, so goodflows does not count it either.
- **v4-1 test.** The orchestrator's test was checked by the close gate only; no verifier reviewed it.
- **Feature recipe.** verify-specdrift-2 did not drive the `stored-changes-api` feature recipe itself. verify-barsqa-2 recorded its 7 sub-features as passing.
- **Blocker order.** fix-3 found that no test catches a change in the order of the `@delete_blockers` list. The order was kept identical to the old `cond`.
