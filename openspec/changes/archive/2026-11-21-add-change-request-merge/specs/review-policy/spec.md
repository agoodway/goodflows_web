# Spec Delta

## MODIFIED Requirements

### Requirement: Active settings grow by phase
With `add-change-request-core`, `active_settings` SHALL hold every setting except `scenarios.*`, `evidence.ignore_paths`, `coverage.*` and `merge.*`. `add-change-request-grading` MUST add `scenarios.*`, `evidence.ignore_paths` and `coverage.*`, and `add-change-request-merge` MUST add `merge.*`, so a server that implements all four phases lists every setting. A setting missing from `active_settings` MUST NOT change any verdict.

#### Scenario: Later-phase settings are inactive
- **WHEN** a server that implements `add-change-request-core` and `add-change-request-grading` but not `add-change-request-merge` serves a version that sets `merge.regrade_merge_result` true
- **THEN** `active_settings` contains `claims.one_way_door`, `evidence.required_workflows` and `coverage.undriven_features` and does not contain `merge.regrade_merge_result`

#### Scenario: Inactive settings do not change verdicts
- **WHEN** a server that does not implement `add-change-request-merge` holds a leased change request whose lease `base` differs from its `merge_base`, and an admin writes a version that only sets `merge.regrade_merge_result` true
- **THEN** every recomputed verdict has the same `state` and `reasons` as before, with the new `policy_version`

#### Scenario: Merge settings are active
- **WHEN** a server that implements `add-change-request-merge` serves a policy version
- **THEN** `active_settings` contains every setting, including `merge.lease_ttl` and `merge.regrade_merge_result`
