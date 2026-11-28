---
format: qa-scenarios/2
source: intent
change: "withdraw-review-answers"
specs: uncommitted
review: null
scenarios:
  - id: 1
    name: "Approve with one click"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "Approve is one click with a note in its menu"
        implied: true
  - id: 2
    name: "Approve with a note from the menu"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "Approve is one click with a note in its menu"
        implied: true
  - id: 3
    name: "Unapprove reopens the item and the verdict"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "An approved item offers Unapprove"
        implied: true
      - capability: "change-request-review"
        requirement: "Members withdraw an approval in the dashboard"
        implied: true
  - id: 4
    name: "Another member's approval can be withdrawn"
    priority: must
    covers:
      - capability: "change-request-review"
        requirement: "Members withdraw an approval in the dashboard"
        implied: true
  - id: 5
    name: "Unapprove after the head moved stores nothing"
    priority: must
    covers:
      - capability: "change-request-review"
        requirement: "Members withdraw an approval in the dashboard"
        implied: true
      - capability: "change-request-dashboard"
        requirement: "An approved item offers Unapprove"
        implied: true
  - id: 6
    name: "Unapprove after a colleague requested a change stores nothing"
    priority: should
    covers:
      - capability: "change-request-review"
        requirement: "Members withdraw an approval in the dashboard"
        implied: true
  - id: 7
    name: "Set approval items offer no Unapprove"
    priority: should
    covers:
      - capability: "change-request-dashboard"
        requirement: "An approved item offers Unapprove"
        implied: true
---

# QA: withdraw-review-answers

Run against a local GoodFlows Web with two seeded account members and a project whose open change request has Git facts and claims with a one-way door at its head.

## Scenarios

### 1. Approve with one click (Must)

1. Open the change request and click the main part of Approve on the one-way door item.
   - Expect: no dialog opens; the item shows Approved by the member at the head, the review count reads 1 of 1 cleared and the verdict is Mergeable.

### 2. Approve with a note from the menu (Must)

1. On an unanswered item, open the Approve menu and choose Approve with note, enter `ok for v1` and confirm.
   - Expect: the item shows Approved with the note `ok for v1`.

### 3. Unapprove reopens the item and the verdict (Must)

1. On the item approved in scenario 1, click Unapprove.
   - Expect: no dialog opens; the item shows No answer and offers Approve again, the review count reads 0 of 1 cleared, the verdict is Needs review, and the event feed has one `answer_withdrawn` event for the item at the head.

### 4. Another member's approval can be withdrawn (Must)

1. Have the first member approve the item, then sign in as the second member and click Unapprove on it.
   - Expect: the item shows No answer and the `answer_withdrawn` event's actor is the second member.

### 5. Unapprove after the head moved stores nothing (Must)

1. Approve the item, report a new head through the API without reloading the page, then click Unapprove.
   - Expect: the page says a new head was reported, the approval at the old head is still current there, and no `answer_withdrawn` event is recorded.

### 6. Unapprove after a colleague requested a change stores nothing (Should)

1. Approve the item, have another member request a change on it through the API, then click Unapprove before the page reloads.
   - Expect: the page says the item's answer changed, and the colleague's requested change is still the item's answer.

### 7. Set approval items offer no Unapprove (Should)

1. Approve the intent scenario set item from the review items.
   - Expect: the item shows Approved and offers Reject, not Unapprove.
