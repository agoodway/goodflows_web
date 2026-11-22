## MODIFIED Requirements

### Requirement: Grading policy settings take effect
From this phase the verdict SHALL apply the review policy's `scenarios`, `evidence.ignore_paths` and `coverage` settings, which `active_settings` lists as the review-policy capability requires. Each rule below MUST add one reason per subject with a stable `rule`, a `subject` (an array of strings, in the order given) and a message, and combine by the phase-1 precedence `pending > blocked > needs_review > mergeable`.

#### Scenario: Settings reported active
- **WHEN** a client reads the project's review policy
- **THEN** the active settings include `scenarios.require_approved_intent`, `scenarios.should_failures`, `scenarios.spec_gaps`, `scenarios.approver`, `scenarios.diff_only`, `evidence.ignore_paths`, `coverage.unmapped_areas` and `coverage.undriven_features`

### Requirement: A diff-only change request needs review
With `scenarios.require_approved_intent` true and `scenarios.diff_only` `needs_review`, a change request that has a diff set and no intent set MUST get reason `diff_only_set` with outcome `needs_review` and `subject` `[]` at every head. With `scenarios.diff_only` `weakening` or `ignore`, `diff_only_set` MUST NOT fire.

#### Scenario: Diff set only
- **WHEN** change request 43 links no OpenSpec change, has a diff set for its head, every Must passed, the policy requires an approved intent set, and `scenarios.diff_only` is `needs_review`
- **THEN** the verdict has a `diff_only_set` reason and is at least `needs_review`

#### Scenario: New head keeps the reason
- **WHEN** `scenarios.diff_only` is `needs_review` and a diff set is uploaded for a new head of change request 43
- **THEN** the recomputed verdict still has a `diff_only_set` reason

#### Scenario: Diff-only ignored
- **WHEN** change request 43 links no OpenSpec change, has a diff set naming its head, a counted run passed every scenario, the policy requires an approved intent set, and `scenarios.diff_only` is `ignore`
- **THEN** the verdict has no `diff_only_set` reason and no scenario reason holds it from `mergeable`

#### Scenario: Weakening mode has no per-head reason
- **WHEN** `scenarios.diff_only` is `weakening` and the current diff version of change request 43 drops no Must of its baseline
- **THEN** the verdict has no `diff_only_set` and no `diff_set_weakened` reason

### Requirement: A diff set must name the head
A diff version names head H when its `revision` is H or a prefix of it. Otherwise it names H when it is a prefix of exactly one commit in H's `git-facts.commits` and every later commit's changed files match `evidence.ignore_paths`. When the current diff version does not name the head, the verdict MUST be `pending` with reason `diff_set_revision` whose `subject` is `[<revision>]` as written, and that diff set MUST NOT be graded.

#### Scenario: Push after the diff set
- **WHEN** the diff set names `aaaa…` and the client reports `git-facts` for head `bbbb…`, whose commit after `aaaa…` changes `app/lib/good_flows/caches.ex`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason for `aaaa…`

#### Scenario: New diff set for the head
- **WHEN** a diff version naming `bbbb…` is uploaded
- **THEN** the `diff_set_revision` reason is gone

#### Scenario: Short SHA of the head
- **WHEN** the head is `bbbb123` followed by 33 more hex characters and the current diff version has `revision: bbbb123`
- **THEN** the verdict has no `diff_set_revision` reason and the diff set is graded

#### Scenario: Short SHA of another commit
- **WHEN** the head starts with `bbbb123`, the current diff version has `revision: aaaa123`, and no commit in the head's `git-facts.commits` starts with `aaaa123`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason whose `subject` is `["aaaa123"]`

#### Scenario: Docs-only push after the diff set
- **WHEN** the current diff version has `revision` `aaaa123`, commit `aaaa123…` is in head H's `git-facts.commits`, the only later commit changes `docs/usage.md`, and `ignore_paths` is `["docs/**"]`
- **THEN** the verdict has no `diff_set_revision` reason and the diff set is graded at H

#### Scenario: Commit not in the facts
- **WHEN** the current diff version names a commit from before a rebase that is not in H's `git-facts.commits` and is not a prefix of H
- **THEN** the verdict is `pending` with a `diff_set_revision` reason

#### Scenario: Ambiguous short SHA
- **WHEN** the current diff version has `revision` `aaaa123`, H does not start with `aaaa123`, and two earlier commits in H's `git-facts.commits` start with `aaaa123`
- **THEN** the verdict is `pending` with a `diff_set_revision` reason whose `subject` is `["aaaa123"]`

### Requirement: Verdict includes scenario results
The verdict response SHALL include `scenarios` with, per set (`intent`, `diff`), `version`, `digest`, `approved`, `graded`, and per scenario `id`, `priority`, `result` and the `run_id` it came from; the diff set also has `accepted` and `baseline_version`; `coverage` with the feature index `version`, `unmapped_areas` and per mapped feature `id` and `driven`; and `counted_runs`. The stored verdict MUST record the approved digest, the diff baseline digest, counted run IDs and index version among its input digests.

#### Scenario: Results in the verdict
- **WHEN** a counted run R2 has `S1` `passed`
- **THEN** the verdict's `scenarios.intent` lists `{id: "S1", priority: "must", result: "passed", run_id: R2}` and `counted_runs` contains R2

#### Scenario: Diff baseline in the verdict
- **WHEN** diff version 2 was accepted and version 4 is current and unaccepted
- **THEN** the verdict's `scenarios.diff` has `version` 4, `accepted` false and `baseline_version` 2

#### Scenario: Public key reads coverage
- **WHEN** a `pk_` key reads the verdict
- **THEN** scenario IDs, priorities, results, counts and `coverage.version` are shown, `coverage.unmapped_areas` is null, each mapped feature has `id` null and `driven` as computed, and no `reason`, `failed_step`, thread link or artifact URL is present

#### Scenario: Private key reads coverage
- **WHEN** an `sk_` key reads the same verdict
- **THEN** `coverage.unmapped_areas` lists the unmapped paths and each mapped feature has its `id`

### Requirement: Answers resolve needs_review
A verdict whose highest-precedence outcome is `needs_review` SHALL become `mergeable` when every review packet item at the current head has a current answer of `approve` or `choose`. A reason is cleared when every item made from it is, so an `open_items` reason needs all of its `question` and `open_item` items. An item whose current answer is `request_change` or `reject`, or that has no answer, MUST keep the verdict at `needs_review`. The reasons MUST stay in the verdict after they are cleared, except `diff_set_weakened` reasons, which are gone once the answers accept the diff digest and make it the baseline.

#### Scenario: All items approved
- **WHEN** change request 42 has `one_way_door` and `size` items at head `a1b2c3d…`, and both are answered `approve` at that head
- **THEN** the verdict at `a1b2c3d…` is `mergeable` and still lists both reasons

#### Scenario: One item asks for a change
- **WHEN** one of two items is answered `approve` and the other `request_change`
- **THEN** the verdict stays `needs_review`

#### Scenario: Question answered by choose
- **WHEN** the only item is a `question` answered `choose` with option `keep`
- **THEN** the verdict is `mergeable`

#### Scenario: Last approval
- **WHEN** the last open item is answered `approve`
- **THEN** the verdict read right after the `201` is `mergeable`

#### Scenario: Accepted weakening leaves the verdict
- **WHEN** the only item at head H is `diff_set_weakened` for `S3` and it is answered `approve`
- **THEN** the verdict read right after the `201` is `mergeable` and has no `diff_set_weakened` reason

## ADDED Requirements

### Requirement: A diff set's baseline
A change request's diff baseline SHALL be the newest diff version whose digest is accepted (its latest decision is `approve`), or version 1 when none is.

#### Scenario: No accepted version
- **WHEN** the diff set has versions 1 to 3 and no decision
- **THEN** the baseline is version 1

#### Scenario: Accepted version
- **WHEN** diff version 2's digest is accepted and version 3 is current
- **THEN** the baseline is version 2

#### Scenario: Latest decision decides
- **WHEN** the stored decisions on version 2's digest are `approve` and then `reject`, and no other diff digest is accepted
- **THEN** the baseline is version 1

### Requirement: A weakened diff set needs review
With `scenarios.require_approved_intent` true, `scenarios.diff_only` `weakening`, a graded diff set, no linked OpenSpec change and no intent set, each Must scenario of the baseline that the current version removes, or demotes to `should` or `could`, MUST add reason `diff_set_weakened` with outcome `needs_review` and `subject` `["diff", <id>]`. An edited section of a Must, with its priority kept, MUST NOT add a reason.

#### Scenario: Must demoted after a failure
- **WHEN** the baseline is version 1 with Must `S3`, and version 2, current and naming the head, has `S3` as `should`
- **THEN** the verdict has a `diff_set_weakened` reason with `subject` `["diff", "S3"]` and is at least `needs_review`

#### Scenario: Weakening kept on a later version
- **WHEN** version 2 demoted Must `S3`, no version was accepted, and version 3 keeps `S3` as `should`
- **THEN** the verdict at version 3 still has a `diff_set_weakened` reason for `S3`

#### Scenario: Renamed Must
- **WHEN** the baseline has Must `S3` and the current version has no `S3` but a new Must `S7`
- **THEN** the verdict has a `diff_set_weakened` reason for `S3`

#### Scenario: Edited Must
- **WHEN** the current version changes the section of Must `S3` and keeps it `must`
- **THEN** no `diff_set_weakened` reason is added

#### Scenario: Accepted weakening
- **WHEN** version 2, which demoted Must `S3`, was accepted, and version 3 for a new head keeps `S3` as `should`
- **THEN** the verdict at version 3 has no `diff_set_weakened` reason

#### Scenario: Diff set not graded
- **WHEN** the current diff version weakens its baseline and does not name the head
- **THEN** the verdict is `pending` with `diff_set_revision` and has no `diff_set_weakened` reason

#### Scenario: Linked change without an intent set
- **WHEN** change request 42 links `add-export`, has no intent set, and its current diff version weakens its baseline under `weakening`
- **THEN** the verdict is `pending` with `scenario_set_approval` and has no `diff_set_weakened` reason
