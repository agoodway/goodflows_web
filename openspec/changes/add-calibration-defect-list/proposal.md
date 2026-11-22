# Proposal

## Why

The calibration report (`GET /api/v1/projects/:project/calibration`) counts merges and defects by lane, policy version, rule and path glob, but it never says which defects those counts come from. The only list it returns is `gaps`, the numbers of defective change requests merged with no reasons. An admin who sees `path_match` with `fired_with_defects_count: 2`, or a `bypass` lane with `defect_rate: 0.6`, cannot tell which defects, tickets or severities are behind the number without paging `GET .../defects` and matching each defect to a change request, lane and policy version by hand. Clients cannot do that match either, because the report does not say which change requests merged in its window.

Defects that no merged change request contains (`attribution: "unattributed"`) are left out of the report entirely, so a project with many of them looks better calibrated than it is.

## What Changes

- The report gains `defects`: every defect attributed to a change request merged in the window, newest `recorded_at` first. Each entry carries the defect's own fields (`id`, `change_request`, `commit`, `attribution`, `severity`, `ticket`, `recorded_at`) and the calibration context already computed for its change request: `lane`, `policy_version`, `rules` (the rules in its `merge.reasons`) and `globs` (the policy `paths` globs its files match).
- The list holds at most 500 entries. `defects_truncated` is true when more defects exist; every count in the report still covers all of them.
- `ticket` is null in the report for a `pk_` key, the same as `GET .../defects`.
- The report gains `unattributed_defect_count`: the project's unattributed defects whose `recorded_at` is in `[from, to)`. They are counted, not listed, and belong to no lane.
- Companion CLI change in agoodway/goodflows: `goodflows policy calibration` prints the lanes, rules and globs as summary lines and the defects as a table, instead of dumping the report.

## Capabilities

### Modified Capabilities

- `review-calibration`: the report lists its defects with their lane, policy version, rules and globs, redacts tickets for public keys, and counts unattributed defects.

## Impact

- `GoodFlows.Calibration.report/2` already loads these defects (`defects_of/1`) and each one's files (`glob_stats/3`); the change reuses them and adds one count query. No migration.
- `CalibrationController` needs the key type to redact `ticket`, as `DefectController` does.
- OpenAPI: new `defects`, `defects_truncated` and `unattributed_defect_count` fields on `CalibrationResponse`.
- Existing fields keep their meaning, so current clients are unaffected.
- Out of scope: paging the defect list, per-lane severity breakdowns, and listing unattributed defects (`GET .../defects` already lists them).
