## ADDED Requirements

### Requirement: Approve is one click with a note in its menu
Refs: D5, G1, A1
On a `draft` or `open` change request, an item whose answers include `approve` and that has no current `approve` at the head SHALL offer Approve as a split button to a member who may answer it. Its main part MUST store `approve` with no note at the head the page showed without asking for confirmation, with the effects and refusals of a dashboard answer. Its menu SHALL offer Approve with note, which asks for an optional note and stores `approve` with it at the head the page showed.

### Requirement: An approved item offers Unapprove
Refs: D2, D5, D6, G2, A1, A2
On a `draft` or `open` change request, an item with a current `approve` at the head, of a kind other than `scenario_set_approval` and `diff_set_weakened`, SHALL offer Unapprove in place of Approve to a member who may answer it. Unapprove MUST withdraw the approval at the head the page showed without asking for confirmation. When the withdrawal is refused the page SHALL say why and show the item as it is at the current head. The item's other answers SHALL stay offered.
