## ADDED Requirements

### Requirement: An unanswered review item reads as needing an answer
Refs: D3, G3, G4, A2
For every item kind, an item with no answer at the head SHALL show the state "Needs an answer", styled as a neutral state and not as a failure. Answered states of other kinds are unchanged; an answered `diff_only_set` or `unproven_claim` item SHALL read as being about the scenarios or the claim, not the change request.

### Requirement: The diff-only item says what the reviewer decides
Refs: D1, D2, D4, D13, G1, G4, A2
The `diff_only_set` group SHALL be titled "Confirm scenarios written with the change" and its item SHALL explain, with the count of scenarios in the graded diff set version, that no scenarios were approved before the change was built, that the scenarios grading it were written with the change, and that a person decides whether they are enough. Its answer dialog SHALL show the same explanation, not the reason message. Its answer buttons, dialog and accessible names SHALL say "Confirm these scenarios" for `approve` and "Ask for more scenarios" for `request_change`; the answers stored and sent MUST stay `approve` and `request_change`. Answering it MUST NOT change the diff set's Accepted or Not accepted status.

### Requirement: The diff-only item shows the set it is about
Refs: D5, D6, D12, G2
The `diff_only_set` item SHALL show the diff set version and short digest, its number of scenarios and of Must scenarios, and a link to that set's scenarios on the same page. When the set is graded at the head, it SHALL also show how many passed, failed and were not run (a scenario without a result counts as not run). When it is not graded, it SHALL say the set does not name the head, show no result counts, and MUST NOT say the scenarios grade the change.

### Requirement: The unproven-claim item says what the reviewer decides
Refs: D1, D2, D7, D13, G1, G4, A2
The `unproven_claim` group SHALL be titled "Check a claim yourself" and its item SHALL explain, with the number of claims and the right singular or plural, that those claims about why the change is safe have less proof than the policy asks for, what that proof is in plain words, and that a person decides whether the claims hold, one answer covering all of them. It MUST NOT say or imply that a claim is false. Its answer dialog SHALL show the same explanation, not the reason message. Its answer buttons, dialog and accessible names SHALL say "Confirm the claim", in a plural form when the item holds more than one claim, for `approve` and "Ask for stronger proof" for `request_change`; any action that re-applies an earlier answer to the item SHALL use the same verb; the answers stored and sent MUST stay `approve` and `request_change`.

### Requirement: Each unproven claim shows the proof it has and the proof wanted
Refs: D8, G2
For each claim, the `unproven_claim` item SHALL show the fact; the claim's proof level and the policy's minimum level, each with its plain meaning; the claim's location, marked as what the claim points at; and its evidence references when it has any. The item SHALL show once the meaning of all four levels in order: stated, pointed, walked, ran.

### Requirement: The unproven-claim item offers the files changed at the head
Refs: D9, G2
The `unproven_claim` item SHALL offer the list of every changed file in the head's Git facts, with the old path beside the path of a renamed or copied file, from the head the packet shows, closed until the reviewer opens it; until then the page MUST NOT carry the list's paths. Without Git facts at the head the list SHALL be absent. The `unproven_claim` item data MUST NOT change.
