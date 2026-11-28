## ADDED Requirements

### Requirement: Members withdraw an approval in the dashboard
Refs: D1, D2, D3, D4, D6, G2, A1, A2
A signed-in account member SHALL be able to withdraw the current `approve` answer of an item at the change request's head, through the dashboard only, for any item kind except `scenario_set_approval` and `diff_set_weakened`, whoever gave the approval. The withdrawal SHALL end that answer without storing a new one, so the item has no answer at the head; make the answer's `open` task `stale` if it has one; record an `answer_withdrawn` project event with `data` `item_id`, `kind`, `head` and `answer` and the member as actor; and recompute the verdict, in one transaction under the change request's lock. It MUST store and record nothing when the change request is not `draft` or `open`, the head is not the one the member was shown, the item is not an item at the head or is of an excluded kind, or the item's current answer at the head is not `approve`.

#### Scenario: Withdrawing the last approval takes the verdict back to needs_review
- **WHEN** a member withdraws the only approval of the only item of a `mergeable` verdict
- **THEN** the item has no answer at the head and the verdict is `needs_review` with 0 of 1 cleared
