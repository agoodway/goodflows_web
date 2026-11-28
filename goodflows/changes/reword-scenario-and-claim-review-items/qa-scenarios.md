---
format: qa-scenarios/2
source: intent
change: "reword-scenario-and-claim-review-items"
specs: uncommitted
review: null
scenarios:
  - id: 1
    name: "Unanswered items of every kind read as needing an answer"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "An unanswered review item reads as needing an answer"
        implied: true
  - id: 2
    name: "Diff-only item explains the decision and answers stay approve"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "The diff-only item says what the reviewer decides"
        implied: true
  - id: 3
    name: "Diff-only item shows the set version, counts, results and link"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "The diff-only item shows the set it is about"
        implied: true
  - id: 4
    name: "Unproven-claim item explains the decision with the policy's level"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "The unproven-claim item says what the reviewer decides"
        implied: true
  - id: 5
    name: "Each claim shows its proof, the wanted proof and what it points at"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "Each unproven claim shows the proof it has and the proof wanted"
        implied: true
  - id: 6
    name: "Changed files list on the claim item"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "The unproven-claim item offers the files changed at the head"
        implied: true
  - id: 7
    name: "API diff-only item data carries the version"
    priority: must
    covers:
      - capability: "change-request-review"
        requirement: "Diff-only item data carries the set version"
        implied: true
  - id: 8
    name: "Reworded reason messages keep item ids and earlier answers"
    priority: must
    covers:
      - capability: "change-request-review"
        requirement: "The diff-only and proof reasons explain themselves"
        implied: true
  - id: 10
    name: "Diff-only item for a set that does not name the head"
    priority: must
    covers:
      - capability: "change-request-dashboard"
        requirement: "The diff-only item shows the set it is about"
        implied: true
  - id: 11
    name: "A new diff set version clears the diff-only confirmation"
    priority: must
    covers:
      - capability: "change-request-review"
        requirement: "A new diff set version clears diff-only answers"
        implied: true
  - id: 9
    name: "Confirming the diff-only item leaves the diff set Not accepted"
    priority: should
    covers:
      - capability: "change-request-dashboard"
        requirement: "The diff-only item says what the reviewer decides"
        implied: true
---

# QA: reword-scenario-and-claim-review-items

Run against a seeded GoodFlows dashboard with a project whose review policy has `scenarios.require_approved_intent` true, `scenarios.diff_only` `needs_review` and `claims.min_proof_level` `ran`, and a change request with Git facts at its head, a diff scenario set and no intent set, a claims file with one `pointed` safe-because fact and one `walked` fact, a synced feature index with `coverage.unmapped_areas` `needs_review`, and one changed file outside every feature. The Git facts include one renamed file.

## Scenarios

### 1. Unanswered items of every kind read as needing an answer (Must)

1. Open the change request page as a member.
   - Expect: every unanswered review item, including the diff-only, unproven-claim and any unmapped file item, shows the state "Needs an answer" with neutral styling; no item shows "No answer".
2. Answer one unmapped file item with approve.
   - Expect: that item shows its approved state and the others still show "Needs an answer".

### 2. Diff-only item explains the decision and answers stay approve (Must)

1. Look at the group for the diff set with 12 scenarios.
   - Expect: the group is titled "Confirm scenarios written with the change"; the item says no scenarios were approved before the change was built, that the 12 scenarios grading it were written with the change, and that a person decides whether they are enough; the words "diff-only" do not appear on the item.
   - Expect: its buttons say "Confirm these scenarios" and "Ask for more scenarios"; no button on the item says "Approve".
2. Click "Confirm these scenarios" and confirm the dialog.
   - Expect: the dialog uses the same words; `GET /api/v1/projects/<slug>/change-requests/<n>/review` returns the item with `answer.answer` `approve`.

### 3. Diff-only item shows the set version, counts, results and link (Must)

1. Upload diff set version 2 with 12 scenarios, 9 of them Must, and a counted verify run with 10 passed, 1 failed and 1 scenario without a result.
   - Expect: the item shows v2 and the short digest, 12 scenarios and 9 Must, 10 passed, 1 failed and 1 not run.
2. Click the item's link to the scenarios.
   - Expect: the page moves to the diff set's scenario list on the same page.

### 4. Unproven-claim item explains the decision with the policy's level (Must)

1. Look at the group for the claims with two facts below `ran`.
   - Expect: the group is titled "Check a claim yourself"; the item says 2 claims about why the change is safe have less proof than the policy asks for, says in plain words that the policy wants a command or test that ran, and does not use "safe-because", "unproven" or "false".
   - Expect: its buttons say "Confirm the claim" and "Ask for stronger proof".
2. Click "Ask for stronger proof", enter a note and confirm.
   - Expect: the API returns the item with `answer.answer` `request_change` and the note.
3. Change the policy's `claims.min_proof_level` to `walked` and reload with one `pointed` fact left below it.
   - Expect: the item says 1 claim, singular, and names the walked level's meaning instead of a run.

### 5. Each claim shows its proof, the wanted proof and what it points at (Must)

1. Look at the `pointed` claim on the item.
   - Expect: it shows the fact, its proof as a pointer to a line to read and the wanted proof as a command or test that ran, and its location, such as `scripts/control:216`, marked as what the claim points at.
2. Look below the claims.
   - Expect: one line explains stated, pointed, walked and ran in that order, shown once for the item, not once per claim.
3. Give the `walked` fact two evidence references and reload.
   - Expect: that claim lists both references.

### 6. Changed files list on the claim item (Must)

1. Look at the unproven-claim item.
   - Expect: a changed files control is closed and no file path from it is visible.
2. Open it.
   - Expect: it lists every path in the head's Git facts `diff.files`, the same number of paths as the seeded Git facts report, with the old path beside a renamed file.

### 7. API diff-only item data carries the version (Must)

1. `GET /api/v1/projects/<slug>/change-requests/<n>/review` with the diff set at version 2.
   - Expect: the `diff_only_set` item's `data.version` is 2, and `data.digest`, `data.revision` and `data.scenarios` hold the same values and shapes as before the change.

### 8. Reworded reason messages keep item ids and earlier answers (Must)

1. On a change request whose two items were answered before the change, note both items' ids and answers, deploy the change, and have the verdict recomputed at the same head, for example by setting a new review policy version with the same settings.
   - Expect: `goodflows cr verdict` prints the new diff-only message about scenarios written with the change and a proof message with the right singular or plural and no "safe-because".
   - Expect: the review packet shows the same item ids for both items, with their earlier answers still applied.
2. Read a verdict stored before the change through the API.
   - Expect: its reason messages are the old ones, unchanged.

### 10. Diff-only item for a set that does not name the head (Must)

1. Push a new head without uploading a diff set that names it, and open the page.
   - Expect: the diff-only item still shows the version, digest, scenario and Must counts and the link, says the set does not name the head, shows no passed, failed or not-run counts, and does not say the scenarios grade the change.
   - Expect: the API item has `data.graded` false.

### 11. A new diff set version clears the diff-only confirmation (Must)

1. Confirm the diff-only item while the diff set is at version 1, then upload diff set version 2 at the same head.
   - Expect: the item shows "Needs an answer" and v2, and the API returns the item with `answer` null.
2. Confirm the unproven-claim item, then upload a new diff set version.
   - Expect: the unproven-claim item keeps its answer.
3. Push a new head with no other change after confirming the diff-only item.
   - Expect: no action offers to re-apply the earlier diff-only answer.

### 9. Confirming the diff-only item leaves the diff set Not accepted (Should)

1. Confirm the diff-only item, then look at the diff set section.
   - Expect: the diff set still shows Not accepted, and the verdict's `scenarios.diff.accepted` is false.
