## ADDED Requirements

### Requirement: The verdict panel summarizes an active verdict
Refs: D1, D9, D10, G1, A2
For a change request in state `draft` or `open` with a stored verdict, the verdict panel SHALL list every `blocked` and `pending` reason with its outcome, message and subject, blocked before pending, grouping reasons of the same rule and outcome into one entry that lists every subject. A `pending` `scenario_set_approval` reason that is a review item SHALL be listed with the pending reasons and link to its item. The `needs_review` reasons SHALL be summarized as one count of review items per item kind, each count linking to that kind's group in the review items, together with the change request's review count (items cleared of the total). The panel MUST NOT list a `needs_review` reason row by row. With no reasons it SHALL say that nothing blocks merging at the head.

### Requirement: The verdict at merge lists its reasons grouped by rule
Refs: D4, A2
For a merged change request, the verdict panel SHALL list the reasons stored with the merge report grouped by rule and outcome, each group with its outcome, message and every subject of its reasons. With no reasons at merge it SHALL say that nothing blocked the merge.

### Requirement: Review items are grouped by kind and show their subject
Refs: D2, G2
For a change request in state `draft` or `open`, the review items SHALL be grouped by item kind, each group showing its kind, the number of its items and how many are cleared. Each item SHALL show what it is about from its packet data: the path for `unmapped_area`; the feature and its changed paths for `undriven_feature`; the pattern and each matched file with its additions and deletions for `sensitive_path`; the door reason for `one_way_door`; the question text for `question`; the risk and location for `open_item`; the scenario and its result for `failed_scenario` and `not_run`; the claim and its proof level for `unproven_claim`; the capability, requirement and scenario for `spec_gap`; the scenario and how it changed for `diff_set_weakened`; the limit and the changed counts for `size`; and the set version and digest for `diff_only_set` and `scenario_set_approval`. Each item SHALL keep its current answer at the head, who gave it and when, its note, and its answer actions.

### Requirement: Unmapped and undriven items can be approved in bulk
Refs: D3, D5, D7, D8, G3, A1
A member who may answer the items SHALL be able to approve, in one action, every unanswered `unmapped_area` item, or every unanswered `undriven_feature` item, at the head the page showed. Before storing anything the page MUST list the items the action will approve and take an optional note of at most 10,000 UTF-8 bytes; the list MUST NOT change while it is open. The action SHALL store one `approve` answer per listed item, through the dashboard channel, in one transaction, with the effects of answering each item through the API. It MUST store nothing and say why when the change request is no longer `draft` or `open`, its head is no longer the one the page showed, a listed item is no longer an item at the head, or a listed item has an answer at the head. Items that already had an answer at the head when the list opened MUST keep it. No other item kind SHALL offer a bulk approval.
