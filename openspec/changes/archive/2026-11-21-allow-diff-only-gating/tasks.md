# Tasks

## 1. Policy setting

- [x] 1.1 Add `scenarios.diff_only` (`needs_review | weakening | ignore`, default `needs_review`) to `GoodFlows.ReviewPolicies.Document`: allowed key, validation, version 0 and `effective` default, and `active_settings`; verify with cases in `review_policies_test.exs` for accept, `blocked` refused with `422` on `policy.scenarios.diff_only`, and an older policy reading `needs_review`
- [x] 1.2 Add `diff_only` to the review policy OpenAPI schema (`GoodFlowsWeb.Schemas.ReviewPolicyDocument`); verify `openapi_test.exs` passes

## 2. Revision names the head

- [x] 2.1 Pass the facts' `commits` and the policy's ignore globs into `Grading.set`, and extend `Grading.names_head?` so a `revision` that is not a prefix of the head names it when it is a prefix of exactly one `commits[].sha` and `Grading.counts?` holds for that SHA at the head; verify with `grading_rules_test.exs` `names_head?` cases for a docs-only push, a code push, a pre-rebase commit and an ambiguous short SHA, plus a `grading_test.exs` "runs that count" case where a diff-set run counts after a docs-only push

## 3. Baseline and weakening rule

- [x] 3.1 Add a diff `accepted` flag and baseline lookup (newest accepted diff version, else version 1) in `GoodFlows.ScenarioSets`, and update the `approved_digests/1` doc and `Decision` moduledoc to cover both sources; verify with `scenario_sets_test.exs` cases for no decision, an accepted version, and decisions `approve` then `reject` inserted directly
- [x] 3.2 Make `diff_only_set` fire only under `diff_only` `needs_review`, and add `diff_set_weakened` (`needs_review`, subject `["diff", <id>]`) for each baseline Must removed or demoted in a graded diff set with no linked change and no intent set under `weakening`, from `ScenarioSets.changes(baseline, current)`; verify with `grading_rules_test.exs` rule-table cases for demotion, weakening kept on a later version, renamed Must, edited Must (no reason), accepted weakening, ungraded set, linked change without an intent set, and `ignore`
- [x] 3.3 Have `Grading` add `accepted`, `baseline` (`version`, `digest`) and the weakened entries to the diff set map; add `accepted` and `baseline_version` to the verdict's `scenarios.diff`, `diff_baseline_digest` to the stored input digests, and `diff_set_weakened` to the verdict reason schema; verify with a `change_request_grading_flow_test.exs` case reading the verdict and an `openapi_test.exs` check that the reason rule enum lists `diff_set_weakened`

## 4. Review items and answers

- [x] 4.1 Add the `diff_set_weakened` item kind to `GoodFlows.Review.Items` and packet data (`id`, `change`, priorities, current and baseline `version` and `digest`, `edited_musts`), with answers `["approve", "reject"]` and the `scenarios.approver` check; add it to the review item kind enum; verify with `items_test.exs`, a `review_controller_test.exs` case for a refused author under `other_member`, and `openapi_test.exs`
- [x] 4.2 Give `ScenarioSets.record_decision` a `source` (default `intent`) for its stale-digest check. In the answer transaction, after storing the answer, record an `approve` decision on the current diff digest with the completing answer's membership and key when every `diff_set_weakened` item of the stored verdict has a current `approve` answer, and a `reject` decision plus a task on a `reject` answer; verify with `change_request_review_flow_test.exs` cases for accepting the only weakening (verdict `mergeable`, reason gone), one of two accepted (`review` `{"items": 2, "cleared": 1}`), the decision made by the completing member, the next push after acceptance, a rejection, and a repeated rejection with the same note adding one decision row
- [x] 4.3 Supersede every unsuperseded `diff_set_weakened` answer of the change request, and make their open tasks `stale`, in the transaction that stores a diff version; verify with `change_request_review_flow_test.exs` cases for a re-upload at the same head resetting the answer, and an earlier answer not completing a later version
- [x] 4.4 Add `source` to `scenario_set_approved` and `scenario_set_rejected` event data and to the `ProjectEvent` schema description; verify with `event_controller_test.exs` cases for an intent approval and a diff acceptance and rejection
- [x] 4.5 Return `accepted` on scenario set upload, list and version reads (`ScenarioSetJSON` takes `accepted` with `approved`), as stored for `pk_` keys, and keep the diff approval and rejection routes `404`; update the scenario set OpenAPI schemas; verify with `scenario_set_controller_test.exs` (including the upload response and a diff version reading `accepted` after a docs-only push) and `openapi_test.exs`

## 5. Integration

- [x] 5.1 Run an end-to-end diff-only flow in `change_request_grading_flow_test.exs` under `require_approved_intent` true and `diff_only` `weakening`: upload v1 and pass a run; push and upload v2 demoting a Must, pass a run on v2's digest, and accept it through the packet; push v3 keeping v2's scenarios, record a passing run on v3's digest at the new head, and verify the verdict reaches `mergeable` without new answers
- [x] 5.2 Run `goodflows run ci` from the repository root and verify the final summary reports success
