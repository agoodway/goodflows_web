---
format: goodflows-change/1
id: reword-scenario-and-claim-review-items
status: approved
size: project
door: two_way
capabilities: [change-request-dashboard, change-request-review]
depends_on: [summarize-verdict-reasons]
goals:
  - {id: G1, text: "A reviewer reading the diff-only or the unproven-claim review item knows what they are deciding: whether the scenarios written with the change are enough, or whether a claim holds without the proof the policy asks for"}
  - {id: G2, text: "Each of the two items gives what a reviewer needs to decide from the card: for the diff set its version, scenario and Must counts, results and a way to read the scenarios; for a claim the proof it has, the proof the policy wants, what each proof level means, and what the claim points at"}
  - {id: G3, text: "An unanswered review item reads as waiting for a person, not as a failure"}
  - {id: G4, text: "The two items use the same words for the same things: the decision a person makes, the two answers, and the waiting state"}
non_goals:
  - {id: N1, text: "Changing the answers an item allows or sends (approve and request_change), who may answer it, or how answers resolve the verdict, except that a new diff set version clears diff_only_set answers (D14)"}
  - {id: N2, text: "Rewording the titles or answer buttons of other item kinds"}
  - {id: N3, text: "Showing what changed since an earlier diff set version on the diff-only item, such as 'replaced v1; scenario 9 changed'"}
  - {id: N4, text: "Changing the goodflows CLI; it keeps printing whatever message the verdict reason carries"}
  - {id: N6, text: "Rewording the Evidence panel's claims summary"}
  - {id: N7, text: "Changing when verdict_changed fires; a recompute after deploy whose only difference is a reworded message may emit one, as any reason change does today"}
  - {id: N5, text: "Linking a claim's location to the file's source, or serving file content; the server knows no repository URL and serves only the claims document's hunks"}
anti_goals:
  - {id: A1, text: "An API client or the CLI breaking because an item kind, rule, subject, item id, answer value or existing data field changed"}
  - {id: A2, text: "A reviewer believing an answer approves the whole change request, marks the diff set Accepted, or says a claim is false"}
decisions:
  - id: D1
    question: What are the two groups' titles on the dashboard?
    answer: "diff_only_set: 'Confirm scenarios written with the change'. unproven_claim: 'Check a claim yourself'."
    by: agent
    why: "Both name the decision instead of an internal term. tbrewer's starting points were 'Accept scenarios written with the change' and 'Check a claim yourself'; 'Accept' clashes with the diff set's own Accepted / Not accepted badge on the same page, which only diff_set_weakened answers set and which this item does not change (A2). 'Unproven claim' is dropped because it reads as the claim maybe being false."
    rejected: ["Accept scenarios written with the change", "keep Diff-only scenario set and Unproven claim"]
  - id: D2
    question: What do the two items' answer buttons say, and what do they send?
    answer: "diff_only_set: 'Confirm these scenarios' sends approve, 'Ask for more scenarios' sends request_change. unproven_claim: 'Confirm the claim' (a plural form when the item holds more than one claim) sends approve, 'Ask for stronger proof' sends request_change; one answer covers every claim on the item, as it does today. The answer dialog and the buttons' accessible names use the same words. Every other kind keeps 'Approve' and 'Request change'."
    by: agent
    why: "'Approve' reads as approving the change request (A2). One verb, Confirm, for the approving answer on both cards and 'Ask for ...' for the other keeps them consistent (G4). tbrewer's 'I checked it, accept' was shortened to the shared verb and avoids 'accept' for the reason in D1. Only labels change, so the API, CLI and stored answers stay as they are (N1, A1)."
    rejected: ["Accept these scenarios / I checked it, accept", "reword the buttons of every kind"]
  - id: D3
    question: What does the state badge of an unanswered item say, and for which kinds?
    answer: "'Needs an answer', for every item kind."
    by: agent
    why: "The badge is one state shared by all kinds, so changing it for two kinds would leave the page inconsistent. tbrewer's starting point was 'Waiting on you', but the badge is shown to every member, including those the approver rule does not let answer, for whom 'you' is false."
    rejected: ["Waiting on you", "change only the two reworded kinds", "keep No answer"]
  - id: D4
    question: What does the diff_only_set item explain, and where does the count come from?
    answer: "The item says that no scenarios were approved before the change was built, how many scenarios grade it (the count in the graded diff set version, with the right singular or plural), that they were written with the change, and that a person decides whether they are enough. The dashboard composes this from the item's data and shows it in place of the reason message, on the item and in its answer dialog."
    by: agent
    why: "The count changes with each diff set version, so the page writes its own sentence from data it already has; tbrewer's sentence is the example to follow."
    rejected: ["put the count into the verdict reason message"]
  - id: D12
    question: What does the diff_only_set item say when the diff set does not name the head, so no run counts and every result is empty?
    answer: "diff_only_set item data also gains graded, the verdict's scenarios.diff.graded. When it is false, the item says the set does not name the head and shows no passed, failed or not-run counts, and does not claim the scenarios grade the change."
    by: agent
    why: "diff_only_set fires whether or not the set is graded, and an ungraded set would otherwise read as 'N not run' under a sentence saying the scenarios grade the change. Adding graded beside version is additive for the same reason as D6."
    rejected: ["show every scenario as not run", "read graded from the verdict on the page only"]
  - id: D5
    question: What does the diff_only_set item's subject row show?
    answer: "The diff set version and short digest, the number of scenarios and of Must scenarios, the number passed, failed and not run (a scenario with no result counts as not run), and a link to that diff set's scenarios on the same page."
    by: agent
    why: "Today it shows the digest only, so the set cannot be judged from the card (G2). The page already lists the diff set's scenarios in its diff set section, so the link goes there rather than to the API."
    rejected: ["link to the scenario set API version URL", "list every scenario on the card"]
  - id: D6
    question: How does the item learn the diff set's version, which its data lacks today?
    answer: "diff_only_set item data gains a version field: the graded diff set version, the number the verdict's scenarios.diff.version holds. digest, revision and scenarios stay as they are."
    by: agent
    why: "The dashboard reads version from item data, which diff_only_set never carried, so the version never showed. Adding a field is additive for API clients (A1); scenario_set_approval and diff_set_weakened data already carry version."
    rejected: ["read the version from the verdict on the page only, leaving the API without it"]
  - id: D7
    question: What does the unproven_claim item explain?
    answer: "The item says how many claims about why the change is safe have less proof than the policy asks for (with the right singular or plural), what proof the policy asks for in plain words, and that a person decides whether the claims hold, one answer covering all of them. It shows in place of the reason message, on the item and in its answer dialog. It does not say the claim may be false."
    by: agent
    why: "tbrewer's sentence ('has no test or run behind it') is only true when the minimum is ran; the minimum may be pointed or walked, so the sentence follows the policy's level. The reason message is computed per verdict and also reaches the CLI, so the page writes its own."
    rejected: ["tbrewer's sentence fixed to ran"]
  - id: D8
    question: What does each claim on the unproven_claim item show?
    answer: "The claim's fact; the proof it has and the proof the policy wants, each as the level's plain meaning; its location, marked as what the claim points at, as text a reviewer can copy; and its evidence references when it has any. Under the claims, one line explains all four levels in order: stated (only said), pointed (cites a line to read), walked (steps through why the failure cannot happen), ran (a command or test showed it)."
    by: agent
    why: "'Proof pointed, needs ran' names levels without meaning (G2). tbrewer's legend left out walked, which the claims format and the policy allow. The location cannot be a link (N5), so it is marked as the evidence offered instead."
    rejected: ["link the location to a source host", "a legend per claim", "a legend of three levels"]
  - id: D9
    question: Does the unproven_claim item show the files changed at the head?
    answer: "Yes: a list of the changed files from the Git facts of the head the packet shows, closed by default, on every unproven_claim item; a renamed or copied file shows its old path beside its path. Until opened the page carries no path from the list, so a 10,000-file head adds nothing to every refresh; once opened it stays open across refreshes. unproven_claim item data stays unchanged."
    by: agent
    why: "In the case that prompted this, the diff settled the claim, not the cited line. Telling which claims are about changed files would mean reading the claim's text, so the list is offered on every claim item and stays closed. Paths are already shown for sensitive paths, so this serves no diff content (N5)."
    rejected: ["show it only for claims about changed files", "leave it out", "add the paths to unproven_claim item data"]
  - id: D10
    question: Do the diff_only_set and proof_below_minimum verdict reason messages change, given the goodflows CLI prints them for cr verdict?
    answer: "Yes, both. diff_only_set says that no approved scenarios came before the change and a person must confirm the scenarios written with it are enough. proof_below_minimum says how many claims about why the change is safe have less proof than the policy's level, with the right singular or plural. Rule, outcome, subject and item ids stay the same, so answers already given still apply. Verdicts already stored keep the message they were computed with."
    by: agent
    why: "CLI readers have the same jargon problem, and the proof message has a plural mistake ('1 safe-because claims'). No test, spec or program in this repository matches either message, and the CLI prints them rather than parsing them (N4). Item ids come from rule and subject, not the message."
    rejected: ["keep both messages", "rewrite stored verdicts' messages"]
  - id: D11
    question: Where do these requirements live, given goodflows/specs has no change-request-review spec yet and packet data per kind is specified in openspec/specs/change-request-review?
    answer: "They are ADDED to goodflows/specs/change-request-dashboard and goodflows/specs/change-request-review."
    by: agent
    why: "goodflows change validate needs targets in goodflows/specs or a depends_on change for MODIFIED, so new behavior is ADDED; summarize-verdict-reasons made the same call (its D6)."
    rejected: ["copy the whole openspec change-request-review spec into goodflows/specs within this change", "MODIFY summarize-verdict-reasons' 'Review items are grouped by kind and show their subject' as well (the added requirements only add to what it lists, and the added requirements already say what each card shows)"]
  - id: D14
    question: Does a diff_only_set answer carry over to a new diff set version, and may add-review-answer-reapply re-apply it?
    answer: "No to both. Uploading a new diff set version supersedes every diff_only_set answer, the way it already supersedes diff_set_weakened answers, so the item needs an answer again. add-review-answer-reapply excludes diff_only_set from re-apply, as it excludes scenario_set_approval and diff_set_weakened. unproven_claim answers keep today's behavior."
    by: user
    why: "Accepted recommendation: the item id is the same for every diff set version, so a confirmation given on v1 would show on v2 as if the reviewer had read v2, and showing the version on the card makes that look specific."
    rejected: ["keep answers across versions", "record and show the version an answer was given on", "also supersede unproven_claim answers when a claim's proof changes"]
  - id: D13
    question: What do re-apply actions and earlier-answer lines say for these two kinds, given add-review-answer-reapply adds 'Re-approve' and 'Approved by' to every kind?
    answer: "For diff_only_set and unproven_claim they use D2's verbs (re-confirming, confirmed by); only unproven_claim can be re-applied (D14)."
    by: agent
    why: "'Re-approve' on these cards would bring back the reading D2 removes (A2, G4); the same landing rule worked between summarize-verdict-reasons and add-review-answer-reapply."
    rejected: ["leave Re-approve for every kind"]
left_to_builder:
  - "Exact wording of both items' explanatory sentences, subject rows, proof lines and level legend, as long as each carries what D4, D5, D7 and D8 list, and none uses 'diff-only', 'safe-because' or a bare level name without its meaning."
  - "Exact wording of the two reason messages, as long as they carry what D10 lists and drop 'diff scenario set grades' and 'safe-because'."
  - "Wording of the answered state badges, the answer dialog titles, the open tasks a request_change answer creates, and the verdict summary counts for the two kinds, as long as neither uses 'diff-only' or 'unproven' and an answered item reads as being about the scenarios or the claim, not the change request (A2)."
  - "How the changed-file list is collapsed and labelled, as long as it is closed by default and lists every changed path at the head."
  - "Keeping openspec/specs/change-request-review ('Diff-only set item' data) and openspec/specs/change-request-dashboard ('Members answer review items in the dashboard', 'The detail page shows the review packet') consistent with these requirements, as summarize-verdict-reasons did for its own."
  - "How each requirement is tested, with the bar that breaking the behavior of any Must scenario fails an automated test."
---

## Why

Two review items on a change request page ask a person for a decision without saying what it is. On the diff-only scenario set item, tbrewer found the title "Diff-only scenario set" is an internal term, "Only a diff scenario set grades this" is passive jargon that does not say why a person is needed or what Approve means, the row "Diff set 25a56ec" gives no version, count, results or link, and "Approve" reads like approving the whole change request. On the unproven claim item, "Unproven claim" sounds like the claim may be false when what is missing is a run behind it, "1 safe-because claims are proven below ran" has three internal terms and a plural mistake, "Proof pointed, needs ran" names levels without saying what they mean, and the file reference is not marked as the evidence offered. On both, "No answer" reads like a failure. tbrewer wants both reworded together so they share a vocabulary.

## Context

`GoodFlowsWeb.ChangeRequestLive.Show` labels groups and items from `@kinds` ("Diff-only scenario set", "Unproven claim"), labels buttons from `@answer_labels` shared by every kind, shows "No answer" from `state_label/1` for every unanswered item (already in the neutral style; only the text is the problem), and counts the kinds in the verdict summary as "diff-only set(s)" and "unproven claim(s)". Each group header shows the reason message from `GoodFlows.ChangeRequests.Rules`: "Only a diff scenario set grades this" and "N safe-because claims are proven below <level>"; the goodflows CLI prints the same messages for `cr verdict`.

The diff-only item's subject row reads `data.version`, but `GoodFlows.Review.Packet` gives `diff_only_set` data only `digest`, `revision` and `scenarios` (`id`, `priority`, `result`, `run_id`), so only the digest shows. The page lists the diff set's scenarios in its diff set section, with an Accepted / Not accepted badge that only `diff_set_weakened` answers set.

The unproven-claim item's data is `min_proof_level` and `claims` (`fact`, `location`, `proof`, `evidence`, `covers`); the line "Proof pointed, needs ran · <location>" was added by the `summarize-verdict-reasons` build (3f9f241). Proof levels are `stated` < `pointed` < `walked` < `ran`. The server checks neither `location` nor `evidence`, knows no repository URL, and serves no diff content beyond the claims document's hunks. Any member may answer either item; the approver rule applies only to set approvals and weakened diff sets.

This change depends on `summarize-verdict-reasons`, built but not archived, which adds the grouped review items and their subjects this change rewords. The openspec change `add-review-answer-reapply`, not built, re-applies answers by item id, which this change keeps unchanged, and labels its actions after the answer (see D13 and D14).

## Approaches

1. Reword both items on the dashboard, add the diff set version to the item data, and reword both reason messages. Picked: fixes every problem tbrewer listed on both cards, keeps every wire value an API client or the CLI reads, and the CLI's text improves without a CLI release.
2. Reword on the dashboard only. Rejected: CLI readers keep the jargon and the plural mistake, and the version still has no source in the item data.
3. Rename the item kinds or the answers (such as `unproven_claim` to `claim_check`, or an `accept` answer). Rejected: breaks API clients and the CLI for a wording problem.
