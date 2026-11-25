# Tasks

## 1. Report

- [x] 1.1 In `GoodFlows.Calibration.report/2`, build one entry per defect of the merged change requests with `lane`, `policy_version`, `rules` (distinct sorted `merge.reasons` rules) and `globs` (sorted matching globs from the same matching as `glob_stats/3`); verify a test where one defect matches a glob and fired `path_match`, and another is in `gaps` with `rules` `[]` and `globs` `[]`
- [x] 1.2 Order entries by `recorded_at` then `id`, both descending, and cut at 500 with `defects_truncated`; verify a test with 501 defects that the list has 500, `defects_truncated` is true, and the lane counts still include all 501
- [x] 1.3 Add `unattributed_defect_count` for the project's unattributed defects with `recorded_at` in `[from, to)`; verify tests that one recorded inside the window counts, one recorded at `to` does not, and neither changes any lane, rule, glob, `gaps` or `unmatched_defect_count`

## 2. API

- [x] 2.1 Render entries in `CalibrationController` with `redact?` from the key, reusing the `DefectJSON` defect shape; verify controller tests that an `sk_` key sees `ticket` and a `pk_` key sees `ticket` null
- [x] 2.2 Add `defects`, `defects_truncated` and `unattributed_defect_count` to `CalibrationResponse` in `GoodFlowsWeb.ApiSpec`; verify `openapi_test.exs` and a response-schema assertion in the controller test
- [x] 2.3 Verify the existing test that reading the report creates no policy version and recomputes no verdict still passes

## 3. Finish

- [x] 3.1 Run `mix precommit` and `goodflows run ci --jobs test`
