# Tasks

## 1. Storage

- [x] 1.1 Add a migration that creates `change_request_verdict_transitions` (columns and index from design D1, `change_request_id` on delete cascade), adds nullable `previous_head` and `head_kind` to `change_request_git_facts`, and nullable `merged_fix_iterations` and `merged_head_count` to `change_requests`; add the schema module and fields
- [x] 1.2 Verify the project event sweep test still passes and that a transition row survives a sweep that deletes the change request's events

## 2. Head classification

- [x] 2.1 In `report_git_facts_locked/3`, classify a newly stored report against the previous head's stored facts (design D3) and store `previous_head` and `head_kind`; verify tests for `first`, `retarget`, `fast_forward`, `target_merged`, `rebase`, `rewrite` (amend, and no stored facts for the previous head), and that an exact retry of an earlier head keeps its original kind
- [x] 2.2 Return `previous_head` and `head_kind` from the Git facts read and add them to the OpenAPI schema; verify a controller test and `openapi_test.exs`

## 3. Transitions

- [x] 3.1 Add the `head_kind:` option to `recompute/2` and write a transition in `record_verdict_changed/4` with the derived `cause` (design D2); verify tests for `created`, `head` (with kind), `policy`, `inputs` (a workflow run on the head), and no row when nothing changed
- [x] 3.2 Verify a transition is recorded for a `draft` change request and none for `closed` or `merged` ones

## 4. Reason spans

- [x] 4.1 Add `change_request_reason_spans` (columns and indexes from design D5) to the migration in 1.1, with its schema module
- [x] 4.2 In `recompute/2`, open and close spans by diffing the new reasons against open spans (design D5); verify tests for a reasons-only change (a verify run clears one of two `must_failed` reasons at the same head: that span closes with `inputs`, the other stays open, and no transition is recorded), a head change (closed with `head` and the head kind), an outcome change under a new policy (closed with `policy`, new span with the new outcome), and an answer that leaves the span open
- [x] 4.3 Close open spans with `merged` in `report_merge/3` and with `closed` in `transition/3`; verify that a reopen opens new spans and that a retried merge report changes no span
- [x] 4.4 Mark spans `inherited` for a change request with a stored verdict and no spans; verify a test that seeds a verdict without spans and recomputes

## 5. Merge counts

- [x] 5.1 In `report_merge/3`, compute `fix_iterations` and `head_count` (design D4) and store them through `merge_changeset/2`; verify the spec scenarios: two fixes after a block, rebase not counted, new head before any grade, no Git facts, and a pre-change Git facts row giving null
- [x] 5.2 Render `head_count` and `fix_iterations` in `merge` and add them to the `ChangeRequestMerge` schema; verify a retried merge report returns the stored values unchanged

## 6. Finish

- [x] 6.1 Run `mix precommit` and `goodflows run ci --jobs test`
