---
format: qa-scenarios/2
source: intent
change: "summarize-verdict-reasons"
specs: uncommitted
review: null
scenarios:
  - id: 1
    name: "Verdict panel summarizes needs-review reasons and lists pending ones"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "The verdict panel summarizes an active verdict"
        implied: true
  - id: 2
    name: "Summary counts link to their review group"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "The verdict panel summarizes an active verdict"
        implied: true
  - id: 3
    name: "Merged change request lists reasons grouped by rule"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "The verdict at merge lists its reasons grouped by rule"
        implied: true
  - id: 4
    name: "Review items are grouped and each shows its subject"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "Review items are grouped by kind and show their subject"
        implied: true
  - id: 5
    name: "Bulk approve unanswered unmapped files"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "Unmapped and undriven items can be approved in bulk"
        implied: true
  - id: 6
    name: "Bulk approve after the head moved stores nothing"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "Unmapped and undriven items can be approved in bulk"
        implied: true
  - id: 8
    name: "Bulk approve after a colleague answered a listed item stores nothing"
    priority: should
    covers:
      - capability: "change-request-dashboard"
        requirement: "Unmapped and undriven items can be approved in bulk"
        implied: true
  - id: 7
    name: "No bulk action on other kinds"
    priority: should
    covers:
      - capability: "change-request-dashboard"
        requirement: "Unmapped and undriven items can be approved in bulk"
        implied: true
---

# QA: summarize-verdict-reasons

Run against a local GoodFlows Web with a seeded account member, a project whose change request has a stored verdict at its head, and that head's Git facts.

## Scenarios

### 1. Verdict panel summarizes needs-review reasons and lists pending ones (Must)

1. Open an open change request whose verdict has a pending `claims_missing` reason, one `path_match` reason and 14 `unmapped_area` reasons.
   - Expect: the Verdict reasons panel lists the pending reason with its head commit.
   - Expect: the needs-review part is one summary naming 1 sensitive path and 14 unmapped files with 0 of 15 cleared, and no unmapped file path appears in the panel.

### 2. Summary counts link to their review group (Must)

1. On the same page, follow the 14 unmapped files link in the summary.
   - Expect: the page moves to the Unmapped area group of the review items, which holds 14 items.

### 3. Merged change request lists reasons grouped by rule (Must)

1. Open a merged change request whose reasons at merge include three `unmapped_area` reasons and one `one_way_door` reason.
   - Expect: the panel is titled Verdict at merge, shows one unmapped area group listing all three paths and one one-way door group, and shows no review items.

### 4. Review items are grouped and each shows its subject (Must)

1. Open the change request from scenario 1.
   - Expect: the review items show a Sensitive path group with the pattern and the matched migration file with its additions and deletions, and an Unmapped area group with 14 items, each naming its file.
2. Approve one unmapped item with the per-item Approve action.
   - Expect: that item shows the approval with who gave it and when, and the group shows 1 of 14 cleared.

### 5. Bulk approve unanswered unmapped files (Must)

1. On the change request from scenario 4, request a change on one unmapped item with a note, then open the group's bulk approve action.
   - Expect: the confirmation lists the 12 unanswered files, not the approved one or the one with a requested change.
2. Confirm with the note `docs and tests`.
   - Expect: 12 new approve answers are stored at the head through the dashboard channel with that note, the requested change is kept, and the review count reads 13 of 15 cleared.

### 6. Bulk approve after the head moved stores nothing (Must)

1. Open the bulk approve confirmation for the unmapped files, then report a new head for the change request through the API before confirming.
2. Confirm.
   - Expect: no answer is stored, and the page says the head changed and to review again.

### 8. Bulk approve after a colleague answered a listed item stores nothing (Should)

1. Open the bulk approve confirmation for the unmapped files, then have another member request a change on one listed file before confirming.
2. Confirm.
   - Expect: no approve answer is stored, the colleague's requested change is kept, and the page says items were answered meanwhile.

### 7. No bulk action on other kinds (Should)

1. Open a change request with one-way door, sensitive path, question and undriven feature items.
   - Expect: only the Undriven feature group offers a bulk approve action.
