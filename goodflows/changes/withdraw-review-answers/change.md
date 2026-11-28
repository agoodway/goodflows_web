---
format: goodflows-change/1
id: withdraw-review-answers
status: approved
size: small
door: two_way
capabilities: [change-request-review, change-request-dashboard]
depends_on: []
goals:
  - {id: G1, text: "A reviewer approves a review item with one click, and adds a note only when they want to"}
  - {id: G2, text: "A reviewer takes back an approval given by mistake, leaving the item unanswered at the head"}
non_goals:
  - {id: N1, text: "Withdrawing answers through the API or the CLI"}
  - {id: N2, text: "Withdrawing request_change, reject or choose answers; a later answer already replaces those"}
  - {id: N3, text: "Undoing scenario set decisions"}
anti_goals:
  - {id: A1, text: "An approval or withdrawal that acts on a head other than the one the page showed"}
  - {id: A2, text: "A withdrawal that removes an answer someone gave after the page showed the approval"}
decisions:
  - id: D1
    question: Who may withdraw an approval?
    answer: "Any member who may answer the item at the head, not only the member who approved it."
    by: user
    why: "Accepted recommendation: anyone may already replace another member's answer with a later one, so limiting withdrawal to its author would protect nothing."
    rejected: [only the member who gave the approval]
  - id: D2
    question: Which item kinds offer withdrawal?
    answer: "Every kind whose answers include approve, except scenario_set_approval and diff_set_weakened."
    by: user
    why: "Accepted recommendation: approving those records an append-only decision on the set digest, and a weakened diff approval moves the diff baseline; withdrawing the answer could undo neither, so those items keep reject as the opposite answer."
    rejected: [every kind with approve, also withdrawing the set decision]
  - id: D3
    question: Where can an approval be withdrawn?
    answer: "Only in the dashboard; the API gets no withdraw route."
    by: user
    why: "Accepted recommendation: the request was for the dashboard button; an API route is a wire contract to add when a client needs it."
    rejected: [also DELETE on the item's answer in the API]
  - id: D4
    question: What does a withdrawal store and change?
    answer: "It ends the item's current approve answer at the head without storing a new answer, so the item is unanswered there; it records an answer_withdrawn event with item_id, kind, head and answer; and it recomputes the verdict, so an approval that made the verdict mergeable takes it back to needs_review."
    by: user
    why: "Accepted recommendation: the item then reads exactly as if it had never been answered, and the feed and history still show the approval and its withdrawal."
    rejected: [store a withdraw answer row, delete the answer row]
  - id: D5
    question: How does the Approve action work in the dashboard?
    answer: "The item's Approve is a split button. Its main part stores approve at the head the page showed with no confirmation and no note; its menu offers Approve with note, which opens the answer dialog. Once the item has a current approve at the head, Approve is replaced by Unapprove, which withdraws with no confirmation. The item's other answers stay as they are."
    by: user
    why: "tbrewer asked for a muted outlined split button whose default click approves without confirmation and that turns into an unapprove button once approved."
    rejected: [keep the confirmation dialog for every approve]
  - id: D6
    question: What happens when the item's current answer at the head is no longer an approve when Unapprove is confirmed?
    answer: "Nothing is stored and the page says the item's answer changed. A withdrawal acts only on a current approve answer."
    by: agent
    why: "A colleague's request_change given after the page loaded must not be removed by a click on an approval that is no longer there (A2)."
    rejected: [withdraw whatever answer is current]
left_to_builder:
  - "Wording and look of the split button, its menu and Unapprove, as long as the menu is reachable by keyboard and each control's accessible name says which item it answers."
  - "Wording of errors a person reads, with the bar that each error names the state at fault and what to do next (for example, the head moved: review the items at the new head)."
  - "How each requirement is tested, with the bar that breaking the behavior of any Must scenario fails an automated test."
---

## Why

tbrewer reviews many small items on a change request. Every Approve opened a confirmation dialog, which is one click too many for the common case, and an approval given by mistake could only be replaced by a request for change, never taken back. He asked for a split Approve button that approves on click, with approve-with-note in its menu, and for Approve to become Unapprove once the item is approved.

## Context

`GoodFlows.Review.answer/4` stores one answer per item and head under the change request's row lock; a later answer to the same item and head supersedes the earlier one and makes its open task stale, then the verdict is recomputed. Nothing ends an answer without storing another. `GoodFlows.Review.Items.resolve/3` counts an item as cleared from its current answer, so ending the answer alone reopens the item. The dashboard opens a dialog for every answer, bound to the head the page showed (`summarize-verdict-reasons` grouped the items and added bulk approval; this change keeps both).

## Approaches

1. End the current approve answer in place (set it superseded with no successor) and record an event. Picked: the packet, the verdict and the review count already read only current answers, so nothing else changes.
2. Store a `withdraw` answer row that items read as unanswered. Rejected: every reader of answers would need to learn a fifth answer that means no answer.
