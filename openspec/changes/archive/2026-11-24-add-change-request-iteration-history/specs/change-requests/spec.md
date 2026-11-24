# Spec Delta

## ADDED Requirements

### Requirement: A new Git facts report records its previous head and head kind

A Git facts report that stores a new row SHALL record `previous_head`, the change request's `head` before the report (null when it had none), and a `head_kind`: `first` when `previous_head` is null, `retarget` when it equals the reported head, and otherwise as the next two requirements say. An exact retry stores nothing and records no kind. `previous_head` and `head_kind` MUST NOT change after the row is stored.

#### Scenario: First head

- **WHEN** a client reports Git facts for head `H1` on a change request with no head
- **THEN** the stored report has `previous_head` null and `head_kind` `first`

### Requirement: A head that keeps the previous head is a fast-forward or a target merge

The previous head's merge base is that of its stored Git facts for the change request's `target_branch`, or else of its most recently stored ones. When `previous_head` is among the document's `commits`, `head_kind` MUST be `fast_forward` if `target.merge_base` equals the previous head's merge base, and `target_merged` otherwise.

#### Scenario: Fix commit on top

- **WHEN** Git facts for `H1` with merge base `B` are stored and a client reports `H2` whose `commits` include `H1`, with merge base `B`
- **THEN** the `H2` report has `previous_head` `H1` and `head_kind` `fast_forward`

#### Scenario: Target branch merged in

- **WHEN** Git facts for `H1` with merge base `B1` are stored and a client reports `H2` whose `commits` include `H1`, with merge base `B2`
- **THEN** the `H2` report has `head_kind` `target_merged`

### Requirement: A head that drops the previous head is a rebase or a rewrite

When `previous_head` is not among the document's `commits`, `head_kind` MUST be `rebase` if `target.merge_base` differs from the previous head's merge base and the document's commits, in order, have the same `changed_files` paths as the commits stored for `previous_head`. It MUST be `rewrite` otherwise, including when no Git facts are stored for `previous_head`.

#### Scenario: Clean rebase

- **WHEN** Git facts for `H1` with merge base `B1` and commits changing `[a.ex]` then `[b.ex]` are stored, and a client reports `H2` with merge base `B2`, without `H1` in its commits, and with commits changing `[a.ex]` then `[b.ex]`
- **THEN** the `H2` report has `head_kind` `rebase`

#### Scenario: Amended commit

- **WHEN** Git facts for `H1` with merge base `B` are stored and a client reports `H2` with merge base `B` that does not include `H1` in its commits
- **THEN** the `H2` report has `head_kind` `rewrite`

#### Scenario: Retry records nothing new

- **WHEN** a client reports `H1`, then `H2`, then the identical `H1` document again
- **THEN** the `H1` report still has `head_kind` `first` and the third report responds `200`

### Requirement: Verdict transitions are kept permanently

Each recompute of a `draft` or `open` change request whose verdict state, head or policy version differs from the stored verdict, or that stores its first verdict, MUST append one transition in the same transaction, holding `from_state`, `to_state`, `from_head`, `to_head`, `policy_version`, `cause`, `head_kind` and the time. `from_*` are null for the first verdict. Transitions MUST NOT be changed or deleted except with their change request; the event retention sweep MUST NOT delete them.

#### Scenario: Transitions outlive event retention

- **WHEN** the project event sweep deletes a change request's `verdict_changed` events older than 90 days
- **THEN** its verdict transitions are unchanged

### Requirement: A transition names its cause

A transition's `cause` MUST be `created` for the first verdict, `head` when the head changed, otherwise `policy` when the policy version changed, otherwise `inputs`. Its `head_kind` MUST be the kind of the Git facts row stored by the report that changed the head, and null for any other cause or when that report was a retry.

#### Scenario: Head change recorded

- **WHEN** a change request's verdict at `H1` is `blocked` and a client reports Git facts for `H2` with kind `fast_forward`, and the verdict becomes `pending`
- **THEN** a transition is recorded with `from_state` `blocked`, `to_state` `pending`, `from_head` `H1`, `to_head` `H2`, `cause` `head` and `head_kind` `fast_forward`

#### Scenario: Policy change recorded

- **WHEN** an admin writes policy version `5` and an `open` change request's verdict at an unchanged head moves from `needs_review` to `mergeable`
- **THEN** a transition is recorded with `cause` `policy` and `head_kind` null

#### Scenario: No change, no transition

- **WHEN** a recompute leaves the verdict state, head and policy version unchanged
- **THEN** no transition is recorded

### Requirement: Reason spans are kept permanently

Each recompute of a `draft` or `open` change request SHALL compare the new verdict's reasons, keyed by `rule`, `subject` and `outcome`, with the change request's open reason spans, in the same transaction. A key with no open span MUST open one with its key, the head, the policy version and the time. An open span whose key is gone MUST close with the head and the time. Spans MUST NOT change once closed and MUST be deleted only with their change request.

#### Scenario: Reasons-only change

- **WHEN** a change request at head `H` is `blocked` with two `must_failed` reasons, and a verify run clears one of them
- **THEN** that reason's span closes with `closed_head` `H` and `close_cause` `inputs`, the other span stays open, and no transition is recorded

#### Scenario: Unchanged reasons

- **WHEN** a recompute produces the same reasons as the open spans
- **THEN** no span is opened or closed

### Requirement: A closed span names its cause

A span closed by a recompute MUST record `close_cause` derived as for a transition (`head`, `policy` or `inputs`) and, for `head`, the `head_kind` of the report that moved the head. A reason whose `outcome` changes MUST close its span and open a new one. A merge report MUST close every open span with `merged`, and a move to `closed` with `closed`. A reopen opens new spans on its recompute.

#### Scenario: Fixed by a new head

- **WHEN** a `must_failed` span is open at `H1` and a client reports `H2` (`fast_forward`) whose verdict lacks that reason
- **THEN** the span closes with `closed_head` `H2`, `close_cause` `head` and `close_head_kind` `fast_forward`

#### Scenario: Outcome changed by policy

- **WHEN** a `path_match` span with outcome `needs_review` is open and a new policy version makes that reason `blocked`
- **THEN** the `needs_review` span closes with `close_cause` `policy` and a `blocked` span opens for the same rule and subject

#### Scenario: Merged past a reason

- **WHEN** a change request with an open `one_way_door` span is reported merged
- **THEN** the span closes with `close_cause` `merged`

### Requirement: A span measures the reason, not its answer

A span MUST stay open while its reason is in the verdict, whether or not its review item has an `approve` or `choose` answer. Review wait time is derived from review answers, whose `item_id` is the reason's `rule` and subject digest.

#### Scenario: Approved reason stays open

- **WHEN** a `one_way_door` span is open and a reviewer approves its item, making the verdict `mergeable`
- **THEN** the span is still open

### Requirement: Spans for reasons from before this change are marked inherited

When a change request has a stored verdict and no reason spans, its next recompute MUST open spans for keys already in the stored verdict with `inherited` true and `opened_at` the time of that recompute, so their durations are lower bounds.

#### Scenario: Open change request at deploy

- **WHEN** an `open` change request's stored verdict has a `spec_gap` reason, it has no spans, and a workflow run on its head triggers a recompute that keeps the reason
- **THEN** a `spec_gap` span opens with `inherited` true

### Requirement: The merge record counts fix iterations

A merge report SHALL store `fix_iterations` with the merge: the number of the change request's transitions with `cause` `head` and `head_kind` `fast_forward` or `rewrite` whose `from_head` had an earlier transition to `blocked` or `needs_review`. It MUST be null when any of its Git facts rows has no `head_kind`. It MUST NOT change after the merge is recorded.

#### Scenario: Two fixes after a block

- **WHEN** a change request was `blocked` at `H1`, a client reported `H2` (`fast_forward`), it became `needs_review` at `H2`, a client reported `H3` (`rewrite`), it became `mergeable`, and it is reported merged
- **THEN** `merge.head_count` is `3` and `merge.fix_iterations` is `2`

#### Scenario: Rebases are not fixes

- **WHEN** a change request was `blocked` at `H1`, a client reported `H2` with kind `rebase`, and it is reported merged
- **THEN** `merge.head_count` is `2` and `merge.fix_iterations` is `0`

#### Scenario: New head before any grade

- **WHEN** a change request's verdict at `H1` was only ever `pending`, a client reported `H2` (`fast_forward`), and it is reported merged
- **THEN** `merge.fix_iterations` is `0`

#### Scenario: History from before this change

- **WHEN** a change request has a Git facts row stored before this change and is reported merged
- **THEN** `merge.head_count` counts every head and `merge.fix_iterations` is null

### Requirement: The merge record counts heads

A merge report SHALL store `head_count` with the merge: the number of distinct heads with stored Git facts for the change request. It MUST NOT change after the merge is recorded.

#### Scenario: Merge without Git facts

- **WHEN** a client reports a merge for a change request that has no Git facts
- **THEN** `merge.head_count` is `0` and `merge.fix_iterations` is `0`

#### Scenario: Retarget counts one head

- **WHEN** Git facts for `H1` are stored for targets `a` and `main` and the change request is reported merged
- **THEN** `merge.head_count` is `1`

### Requirement: Git facts reads return the head kind

`GET .../change-requests/:number/git-facts/:head` SHALL include `previous_head` and `head_kind` of the stored report, both null for a report stored before they existed.

#### Scenario: Git facts head kind

- **WHEN** a report for `H2` was stored with `previous_head` `H1` and `head_kind` `fast_forward`, and a client reads `git-facts/H2`
- **THEN** the read has `previous_head` `H1` and `head_kind` `fast_forward`

## MODIFIED Requirements

### Requirement: The merge record keeps the verdict at merge
The response's `merge` MUST hold `merged_commit`, `target_branch`, `merged_at`, the `head`, the `verdict_state`, `policy_version` and `reasons` of the verdict at that head, `merged_without_mergeable_verdict`, `merged_without_lease`, `head_count` and `fix_iterations`. `head_count` and `fix_iterations` MUST be null for a merge recorded before they existed. These values MUST NOT change after the merge is recorded.

#### Scenario: Verdict stored with the merge
- **WHEN** an `open` change request whose verdict at head `H` is `needs_review` under policy version `4` with one `one_way_door` reason is reported merged
- **THEN** `merge` has `head` `H`, `verdict_state` `needs_review`, `policy_version` `4`, and `reasons` with that `one_way_door` reason

#### Scenario: Merge record after a policy change
- **WHEN** a change request was merged under policy version `4` and an admin then writes version `5`
- **THEN** its `merge.policy_version` is still `4` and `merge.reasons` are unchanged

#### Scenario: Merge recorded before the counts existed
- **WHEN** a client shows a change request merged before `head_count` and `fix_iterations` were added
- **THEN** `merge.head_count` and `merge.fix_iterations` are null
