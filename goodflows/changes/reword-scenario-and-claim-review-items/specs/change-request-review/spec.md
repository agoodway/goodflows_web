## ADDED Requirements

### Requirement: Diff-only item data carries the set version
Refs: D6, D11, D12, A1
A `diff_only_set` item's `data` SHALL carry `version`, the graded diff set version, and `graded`, whether that version names the head, besides `digest`, `revision` and `scenarios`, which MUST keep their values and shapes.

### Requirement: The diff-only and proof reasons explain themselves
Refs: D10, G1, A1
The `diff_only_set` reason message SHALL say that no approved scenarios came before the change and that a person must confirm the scenarios written with it are enough. The `proof_below_minimum` reason message SHALL give the number of claims about why the change is safe whose proof is below the policy's minimum, with the right singular or plural, and name that minimum. Both reasons' rule, outcome and subject, and their items' ids, MUST stay as they are. No migration or backfill SHALL rewrite the messages of stored verdicts or merge reports; a verdict recomputed after the change carries the new messages.

### Requirement: A new diff set version clears diff-only answers
Refs: D14, A2
Storing a new diff set version SHALL supersede every `diff_only_set` answer of the change request, as it supersedes `diff_set_weakened` answers, so the item has no answer until someone answers it again. A `diff_only_set` answer MUST NOT be re-applied to a later head. `unproven_claim` answers SHALL keep today's behavior.
