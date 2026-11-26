## ADDED Requirements

### Requirement: Run summaries list failed jobs
Each run summary SHALL include `failed_jobs`: the `name` of each result whose `status` is `failed` or `timed_out`, in result order, with repeats kept for partitions, and `[]` when there is none. Runs stored before this field existed MUST return the same value as if they were stored now.

#### Scenario: Failed jobs
- **WHEN** a stored document has results `compile` passed, `test` failed, `lint` timed_out and `deploy` cancelled, in that order
- **THEN** its summary `failed_jobs` is `["test", "lint"]`

#### Scenario: Passed run
- **WHEN** a stored document's results all passed or were skipped
- **THEN** its summary `failed_jobs` is `[]`

#### Scenario: Run stored before failed jobs were recorded
- **WHEN** a run stored before this change had a `failed` result `test`
- **THEN** its summary `failed_jobs` is `["test"]`
