# Spec Delta

## ADDED Requirements

### Requirement: Grading policy settings take effect
From this phase the verdict SHALL apply the review policy's `scenarios`, `evidence.ignore_paths` and `coverage` settings, which `active_settings` lists as the review-policy capability requires. Each rule below MUST add one reason per subject with a stable `rule`, a `subject` (an array of strings, in the order given) and a message, and combine by the phase-1 precedence `pending > blocked > needs_review > mergeable`.

#### Scenario: Settings reported active
- **WHEN** a client reads the project's review policy
- **THEN** the active settings include `scenarios.require_approved_intent`, `scenarios.should_failures`, `scenarios.spec_gaps`, `scenarios.approver`, `evidence.ignore_paths`, `coverage.unmapped_areas` and `coverage.undriven_features`

### Requirement: An approved intent set is required
With `scenarios.require_approved_intent` true and a linked OpenSpec change, the verdict MUST be `pending` with reason `scenario_set_approval` while the change request has no intent set or its current intent version's digest is not approved (its latest decision is not `approve`). The reason's `subject` MUST be `[<current digest>]`, or `[]` when no intent set exists.

#### Scenario: No intent set yet
- **WHEN** change request 42 links `add-export`, has no intent set, and the policy requires an approved intent set
- **THEN** the verdict is `pending` with a `scenario_set_approval` reason whose `subject` is `[]`

#### Scenario: Unapproved edit
- **WHEN** digest `d1` was approved and version 2 with digest `d2` is uploaded
- **THEN** the verdict is `pending` with a `scenario_set_approval` reason with `subject` `["d2"]`

#### Scenario: Rejected digest
- **WHEN** digest `d2` is current and its latest decision is a rejection
- **THEN** the verdict is `pending` with a `scenario_set_approval` reason with `subject` `["d2"]`

#### Scenario: Default policy
- **WHEN** a project on policy version 0 has a change request linking `add-export` with no intent set
- **THEN** no `scenario_set_approval` reason is added

#### Scenario: Approval not required
- **WHEN** `require_approved_intent` is false and the current intent version is unapproved
- **THEN** no `scenario_set_approval` reason is added and the intent set's results are graded

### Requirement: Set approval is graded before Git facts
Before any Git facts are reported for the change request's current head, the `scenario_set_approval` and `scenario_set_missing` rules SHALL still run, since they read no Git facts, so a person can approve the intent set before code exists. Every other grading rule reads the head and MUST NOT run while `git_facts_missing` fires.

#### Scenario: Intent set uploaded before code
- **WHEN** change request 42 links `add-export`, has no Git facts, the policy requires an approved intent set, and its current intent version has unapproved digest `d1`
- **THEN** the verdict is `pending` with head null and exactly two reasons: `git_facts_missing` with `subject` `[]` and `scenario_set_approval` with `subject` `["d1"]`

#### Scenario: Approved before code
- **WHEN** digest `d1` of change request 42 is approved and no Git facts are reported
- **THEN** the verdict is `pending` with only the `git_facts_missing` reason

### Requirement: A change request without a linked change needs a scenario set
With `scenarios.require_approved_intent` true, a change request with no linked OpenSpec change MUST be `pending` with reason `scenario_set_missing` (`subject` `[]`) while it has no diff set. With `require_approved_intent` false, including policy version 0, no scenario set is required and `scenario_set_missing` MUST NOT fire.

#### Scenario: No change and no diff set
- **WHEN** change request 43 links no OpenSpec change, has no diff set, and the policy requires an approved intent set
- **THEN** the verdict is `pending` with a `scenario_set_missing` reason

#### Scenario: Nothing required
- **WHEN** `require_approved_intent` is false and change request 43 has no scenario set
- **THEN** no scenario reason is added

### Requirement: A diff-only change request needs review
With `scenarios.require_approved_intent` true, a change request that has a diff set and no intent set MUST get reason `diff_only_set` with outcome `needs_review` and `subject` `[]` at every head.

#### Scenario: Diff set only
- **WHEN** change request 43 links no OpenSpec change, has a diff set for its head, every Must passed, and the policy requires an approved intent set
- **THEN** the verdict has a `diff_only_set` reason and is at least `needs_review`

#### Scenario: New head keeps the reason
- **WHEN** a diff set is uploaded for a new head of change request 43
- **THEN** the recomputed verdict still has a `diff_only_set` reason

### Requirement: A diff set must name the head
A diff version names the head when its `revision` is the head or a prefix of it. When the current diff version does not name the change request's head, the verdict MUST be `pending` with reason `diff_set_revision` whose `subject` is `[<revision>]` as written, and that diff set MUST NOT be graded until a version naming the head is uploaded.

#### Scenario: Push after the diff set
- **WHEN** the diff set names `aaaa…` and the client reports `git-facts` for head `bbbb…`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason for `aaaa…`

#### Scenario: New diff set for the head
- **WHEN** a diff version naming `bbbb…` is uploaded
- **THEN** the `diff_set_revision` reason is gone

#### Scenario: Short SHA of the head
- **WHEN** the head is `bbbb123` followed by 33 more hex characters and the current diff version has `revision: bbbb123`
- **THEN** the verdict has no `diff_set_revision` reason and the diff set is graded

#### Scenario: Short SHA of another commit
- **WHEN** the head starts with `bbbb123` and the current diff version has `revision: aaaa123`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason whose `subject` is `["aaaa123"]`

### Requirement: Each graded set needs a counted run
A graded set is the approved current intent version (or the current intent version when approval is not required) and the current diff version naming the head. When no run counts for a graded set at the head, the verdict MUST be `pending` with reason `scenario_results_missing` whose `subject` is `[<source>]`.

#### Scenario: Approved but not graded
- **WHEN** the intent set is approved and no final clean run grades its digest at the head
- **THEN** the verdict is `pending` with a `scenario_results_missing` reason for `intent`

#### Scenario: Only a dirty run
- **WHEN** the only run grading the approved digest at the head has `dirty` true
- **THEN** the verdict is `pending` with a `scenario_results_missing` reason for `intent`

### Requirement: Must scenarios must pass
For each graded set, a `must` scenario whose result from the newest counted run is `failed` or `not_run` MUST add reason `must_failed` with outcome `blocked` and `subject` `[<source>, <scenario id>]`, so the same ID in the intent and diff sets gives two reasons.

#### Scenario: Must failed
- **WHEN** the newest counted run has `S1` (`must`) `failed`
- **THEN** the verdict is `blocked` with a `must_failed` reason for `S1`, unless a `pending` reason also fired

#### Scenario: Must not run
- **WHEN** the newest counted run has `S2` (`must`) `not_run`
- **THEN** the verdict has a `must_failed` reason for `S2` with outcome `blocked`

#### Scenario: Diff set Must fails
- **WHEN** the intent set's Musts all passed and the diff set's Must `D1` failed
- **THEN** the verdict is `blocked` with a `must_failed` reason for `D1`

### Requirement: Should failures follow the policy
For each graded set, a `should` scenario whose result from the newest counted run is `failed` MUST add reason `should_failed`, and one whose result is `not_run` MUST add reason `should_not_run`, both with `subject` `[<source>, <scenario id>]` and the outcome of `scenarios.should_failures` (`needs_review`, or no reason when `ignore`). `could` results MUST add no reason.

#### Scenario: Should failed
- **WHEN** `should_failures` is `needs_review` and `S4` (`should`) failed
- **THEN** the verdict has a `should_failed` reason for `S4` and is at least `needs_review`

#### Scenario: Should failures ignored
- **WHEN** `should_failures` is `ignore` and `S4` (`should`) failed
- **THEN** no `should_failed` reason is added

#### Scenario: Should not run
- **WHEN** `should_failures` is `needs_review` and the newest counted run has `S4` (`should`) `not_run`
- **THEN** the verdict has a `should_not_run` reason for `S4` and is at least `needs_review`

#### Scenario: Could failed
- **WHEN** `S5` (`could`) failed
- **THEN** no reason is added for `S5`

### Requirement: Spec gaps follow the policy
Each `coverage` row with `status` `no_check` in the graded intent version MUST add reason `spec_gap` with `subject` `[<capability>, <requirement>, <scenario>]` (in that order), with the outcome of `scenarios.spec_gaps` (`needs_review`, or no reason when `ignore`), unless the claims at the head close it.

#### Scenario: Spec gap reviewed
- **WHEN** `spec_gaps` is `needs_review`, the approved intent set has a `no_check` row for `exports` / `Export is audited` / `Audit entry written`, and no claim covers it
- **THEN** the verdict has a `spec_gap` reason with `subject` `["exports", "Export is audited", "Audit entry written"]`

#### Scenario: Default ignores spec gaps
- **WHEN** the project uses policy version 0 and the intent set has a `no_check` row
- **THEN** no `spec_gap` reason is added

### Requirement: A proven claim closes a spec gap
Spec gaps SHALL be evaluated against the claims at the head. A `no_check` row MUST NOT add `spec_gap` when a `safe_because` entry of those claims has `covers` equal to the row's `{capability, requirement, scenario}` and a `proof` at or above `claims.min_proof_level`. A covering entry below the minimum leaves the `spec_gap` reason in place, and `proof_below_minimum` fires as usual. A claims upload already recomputes the verdict.

#### Scenario: No claims at the head
- **WHEN** the head has no claims and the intent set has a `no_check` row
- **THEN** the verdict is `pending` with `claims_missing`, and the row is judged once claims for the head are uploaded

#### Scenario: Covered at the minimum
- **WHEN** `spec_gaps` is `needs_review`, `min_proof_level` is `ran`, and a `safe_because` entry with `proof` `ran` and evidence has `covers` `{capability: exports, requirement: "Export is audited", scenario: "Audit entry written"}` matching a `no_check` row
- **THEN** no `spec_gap` reason is added for that row

#### Scenario: Covered below the minimum
- **WHEN** the same row is covered by an entry with `proof` `walked` and `min_proof_level` is `ran`
- **THEN** the verdict has the `spec_gap` reason for that row and a `proof_below_minimum` reason naming the entry's `fact`

#### Scenario: Covers another scenario
- **WHEN** the only covering entry has `covers` with `scenario` `Audit entry removed` and the `no_check` row's `scenario` is `Audit entry written`
- **THEN** the verdict has the `spec_gap` reason for that row

### Requirement: Unmapped changed areas follow the policy
Each changed file of the head that is an unmapped area in the current feature index MUST add reason `unmapped_area` with `subject` `[<path>]`, with the outcome of `coverage.unmapped_areas` (`needs_review`, `blocked`, or no reason when `ignore`).

#### Scenario: New directory
- **WHEN** `unmapped_areas` is `needs_review` and the head changes `app/lib/good_flows/new_thing.ex`, which no feature maps
- **THEN** the verdict has an `unmapped_area` reason for that path

### Requirement: Changed features must be driven
Each feature that a changed file maps to and that is undriven at the head MUST add reason `undriven_feature` with `subject` `[<feature id>]`, with the outcome of `coverage.undriven_features` (`needs_review`, `blocked`, or no reason when `ignore`).

#### Scenario: Feature not driven
- **WHEN** `undriven_features` is `blocked`, the head changes a file of `checkout`, and no counted run lists `checkout` `passed`
- **THEN** the verdict is `blocked` with an `undriven_feature` reason for `checkout`, unless a `pending` reason also fired

#### Scenario: Feature driven
- **WHEN** a counted run lists `{id: "checkout", result: "passed"}`
- **THEN** no `undriven_feature` reason is added for `checkout`

### Requirement: Coverage needs a feature index
When the project has never synced a feature index and `coverage.unmapped_areas` or `coverage.undriven_features` is not `ignore`, the verdict MUST be `pending` with one reason `feature_index_missing` (`subject` `[]`) in place of both coverage rules. When both are `ignore`, as in policy version 0, no coverage reason is added.

#### Scenario: No index
- **WHEN** the project has no feature index and `undriven_features` is `blocked`
- **THEN** the verdict is `pending` with one `feature_index_missing` reason and no `unmapped_area` or `undriven_feature` reasons

#### Scenario: Coverage off
- **WHEN** the project has no feature index and both coverage settings are `ignore`
- **THEN** no `feature_index_missing` reason is added

### Requirement: Verdict includes scenario results
The verdict response SHALL include `scenarios` with, per set (`intent`, `diff`), `version`, `digest`, `approved`, `graded`, and per scenario `id`, `priority`, `result` and the `run_id` it came from; `coverage` with the feature index `version`, `unmapped_areas` and per mapped feature `id` and `driven`; and `counted_runs`. The stored verdict MUST record the approved digest, counted run IDs and index version among its input digests.

#### Scenario: Results in the verdict
- **WHEN** a counted run R2 has `S1` `passed`
- **THEN** the verdict's `scenarios.intent` lists `{id: "S1", priority: "must", result: "passed", run_id: R2}` and `counted_runs` contains R2

#### Scenario: Public key reads coverage
- **WHEN** a `pk_` key reads the verdict
- **THEN** scenario IDs, priorities, results, counts and `coverage.version` are shown, `coverage.unmapped_areas` is null, each mapped feature has `id` null and `driven` as computed, and no `reason`, `failed_step`, thread link or artifact URL is present

#### Scenario: Private key reads coverage
- **WHEN** an `sk_` key reads the same verdict
- **THEN** `coverage.unmapped_areas` lists the unmapped paths and each mapped feature has its `id`

### Requirement: Grading inputs recompute the verdict
The verdict of every `draft` or `open` change request affected SHALL be recomputed in the transaction that uploads a scenario set version or records an approval or rejection on it, or makes a verify run `final` whose digest is one of its current set digests. A transaction that creates a feature index version MUST recompute every `draft` and `open` change request of its project, in that transaction up to a configured count (default 100) and otherwise in a background job.

#### Scenario: Run commit recomputes
- **WHEN** a verify run grading change request 42's approved digest at its head becomes `final`
- **THEN** the verdict of change request 42 read right after the commit uses that run

#### Scenario: Approval recomputes
- **WHEN** a client approves the current intent digest of change request 42
- **THEN** the verdict read right after has no `scenario_set_approval` reason

### Requirement: Change requests record the runs they counted
Each change request SHALL keep the set of verify runs that counted in any verdict computed for it, including verdicts for earlier heads, so artifact retention can tell when every change request that counted a run is `merged` or `closed`.

#### Scenario: Run counted at an earlier head
- **WHEN** run R counted for change request 42 at head A, and a later head B no longer counts it
- **THEN** R stays recorded as counted by change request 42

## MODIFIED Requirements

### Requirement: JSON upload bodies are strict
JSON bodies on change request routes MUST follow the workflow-run upload rules: a body over a server-configured limit (default 16 MiB for Git facts, 1 MiB for scenario sets, 64 KiB otherwise) returns `413`, a non-JSON Content-Type or a Content-Encoding other than `identity` returns `415`, malformed JSON returns `400`, and duplicate keys, U+0000 in a string, non-integer numbers, and integers above 2^53-1 return `422`. Validation errors MUST NOT echo submitted values.

#### Scenario: Duplicate key
- **WHEN** a Git facts document contains the key `head` twice
- **THEN** the API responds `422` with `has a duplicate key` on `body` and stores nothing

#### Scenario: Oversized Git facts
- **WHEN** a client declares a Content-Length one byte over the Git facts limit
- **THEN** the API responds `413` without reading the body and stores nothing

#### Scenario: Oversized scenario set
- **WHEN** a client uploads a scenario set body of 1,048,577 bytes
- **THEN** the API responds `413` and stores nothing

#### Scenario: Malformed JSON
- **WHEN** a client creates a change request with the body `{`
- **THEN** the API responds `400` and stores nothing

### Requirement: The verdict covers only the last reported head
The verdict MUST be computed for the change request's current head only. Inputs for other heads, including claims and workflow runs on earlier heads, MUST NOT affect it. The one exception is a verify run on an earlier commit that counts for the head under the verify-runs rule for when a run counts for a change request.

#### Scenario: Workflow passed on an earlier head
- **WHEN** `ci` passed on `H1`, the head is now `H2`, and `ci` has no run on `H2`
- **THEN** the verdict is `pending` with a `required_workflow_missing` reason whose `subject` is `["ci"]`

#### Scenario: Verify run before a docs-only commit
- **WHEN** a final clean verify run graded the approved intent digest on `H1`, and the head is now `H2`, whose only commit after `H1` changes paths matching `evidence.ignore_paths`
- **THEN** the run counts for the verdict at `H2`
