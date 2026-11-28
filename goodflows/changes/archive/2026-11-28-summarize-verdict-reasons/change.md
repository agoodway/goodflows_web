---
format: goodflows-change/1
id: summarize-verdict-reasons
status: archived
size: small
door: two_way
capabilities: [change-request-dashboard]
depends_on: []
goals:
  - {id: G1, text: "The Verdict reasons panel is a short summary of what stands between the change request and merging, not a second list of the review items"}
  - {id: G2, text: "Each review item says what it is about (the file, pattern, risk, scenario or claim), so a reviewer can answer it without scrolling back to the verdict"}
  - {id: G3, text: "A reviewer approves many unmapped or undriven paths in one step instead of one click per file"}
non_goals:
  - {id: N1, text: "Changing which reasons become review items, the answers an item allows, or how answers resolve the verdict"}
  - {id: N2, text: "Bulk answering through the API or the CLI"}
anti_goals:
  - {id: A1, text: "A bulk approval that answers items the reviewer was not shown, or items at a head other than the one the page showed"}
  - {id: A2, text: "A pending or blocked reason that disappears from the page because it has no review item"}
decisions:
  - id: D1
    question: What does the Verdict reasons panel show for an active change request?
    answer: "Blocked and pending reasons are each listed with their message and subject, worst outcome first, because they have no review item to hold the detail. Needs-review reasons collapse into one line of counts by item kind (such as 1 sensitive path, 14 unmapped files) with the cleared count, each count linking to its group in Review items."
    by: user
    why: "Accepted recommendation: the two panels showed the same rows twice; the summary keeps what has no other home and points at the rest."
    rejected: [keep one row per reason, move pending and blocked reasons into Review items]
  - id: D2
    question: How are review items laid out?
    answer: "Grouped by item kind, each group with its kind, its rule or rules, a count and its cleared count; each item shows its subject from the packet data (file path, pattern with matched files and line counts, risk and location, scenario, claim and proof level, door reason)."
    by: user
    why: "Accepted recommendation: the item rows said only 'A changed file matches no feature' without the file."
    rejected: [keep items in reason order without grouping]
  - id: D3
    question: Which items can be approved in bulk, and how?
    answer: "Only unmapped_area and undriven_feature items. A group action approves every unanswered item of that group, after a confirmation that lists them and takes an optional note. It applies in one transaction bound to the head the page showed: if the head moved or any listed item is no longer an item, nothing is stored. Request change stays per item."
    by: user
    why: "Accepted recommendation: these kinds are path-level and low risk and come in large numbers; the other kinds each need their own look, and the approver rule governs set approvals."
    rejected: [bulk approve every kind, approve items one by one in a loop with partial success, bulk request change with one note]
  - id: D4
    question: What does a merged change request show, given it has no review items?
    answer: "The reasons at merge in full, grouped by rule with each group's subjects listed, under the Verdict at merge title."
    by: user
    why: "Accepted recommendation: with no review items on a merged change request, the summary would point at nothing."
    rejected: [show the same summary as an active change request]
  - id: D5
    question: Does bulk approval touch items that already have an answer at the head?
    answer: "No. Answered items keep their answer, including request_change; only unanswered items are approved, and the confirmation lists exactly those."
    by: agent
    why: "Overwriting a request_change by a bulk click would hide a reviewer's objection; the mockup's label was 'every unanswered item'."
    rejected: [re-answer every item in the group]
  - id: D6
    question: Where do these requirements live, given goodflows/specs has no change-request-dashboard spec yet?
    answer: "They are ADDED to goodflows/specs/change-request-dashboard, and the build rewrites the openspec requirements 'The detail page explains the verdict' and 'The detail page shows the review packet', and the scenario 'Reasons change while the state holds', to point at them, so the two spec trees do not disagree."
    by: agent
    why: "goodflows change validate needs a MODIFIED target in goodflows/specs, which this repository does not have for the capability yet."
    rejected: [copy the whole openspec spec into goodflows/specs within this change]
  - id: D7
    question: What happens when a listed item gets an answer between opening the bulk confirmation and confirming?
    answer: "The confirmation keeps the list it opened with, through page refreshes. On confirm, if any listed item now has an answer at the head, nothing is stored and the page says items were answered meanwhile, as for a moved head."
    by: agent
    why: "Overwriting would hide a colleague's objection (D5), and skipping would approve fewer items than the reviewer confirmed, the partial success D3 rejected; refusing the whole action keeps A1."
    rejected: [overwrite the new answer, skip it and approve the rest]
  - id: D8
    question: How does one bulk approval recompute the verdict and record events?
    answer: "One verdict recompute after all answers are stored, and one answer_recorded event per approved item, as a single answer records today."
    by: agent
    why: "A recompute per item inside one lock scales with the number of files (one unmapped_area reason per file); events per item keep the API's effects the same as answering one by one."
    rejected: [one recompute per item, one summary event for the whole action]
  - id: D9
    question: How do several blocked or pending reasons of one rule appear in the summary, such as 14 unmapped files with outcome blocked?
    answer: "Grouped by rule and outcome, each group with its message and every subject, as the verdict at merge shows them."
    by: agent
    why: "A policy may make unmapped areas or path matches blocked, one reason per file; grouping keeps every reason visible (A2) without the long list G1 removes."
    rejected: [one row per reason]
  - id: D10
    question: Where does a scenario_set_approval item, whose reason is pending, appear in the summary, and which total does the summary show?
    answer: "It is listed with the pending reasons, linking to its item, and not in the kind counts. The cleared count is the stored review count, unchanged."
    by: agent
    why: "It is pending until the approver acts and never counts as cleared (N1 keeps the count's meaning), so counting it with the needs-review items would show one that can never clear."
    rejected: [count it with the needs-review items]
left_to_builder:
  - "Wording and layout of the summary line, the group headers and the per-kind item detail, as long as every needs-review count links to its group and every item shows its subject."
  - "When a group has many items, how they are collapsed (such as showing the first few with a 'Show all N' control), as long as the bulk confirmation lists every item it will approve."
  - "Wording of errors a person reads, with the bar that each error names the input or state at fault and what to do next (for example, the head moved: reload and review again)."
  - "How each requirement is tested, with the bar that breaking the behavior of any Must scenario fails an automated test."
---

## Why

On change request 1 the Verdict reasons panel listed one row per reason, about fifteen of them "A changed file matches no feature" each with its file, and the Review items panel then listed the same fifteen as items, without saying which file each one was about. A reviewer reads the same list twice and cannot answer an item from the item itself. tbrewer asked for the verdict reasons to be a summary and for the detail to live with the review items.

## Context

`GoodFlowsWeb.ChangeRequestLive.Show` renders each verdict reason with its subject (`subject_lines/2`) and each packet item with only its kind and message, plus extra lines for question, open_item and scenario kinds. `GoodFlows.Review.Packet.build/3` already attaches per-kind `data` (paths, glob and files, risk, claims) to each item. `GoodFlows.Review.Items` turns every `needs_review` reason into items, and `scenario_set_approval` with a digest; other pending and blocked reasons are context only. `GoodFlows.Review.answer/4` stores one answer per item under the change request lock, bound to the head.

The open openspec change `add-review-answer-reapply` modifies the same review packet requirement and adds a panel-wide re-apply action; it is not built. Whichever of the two lands second applies its spec edit on top of the other's text, and this change's bulk approval does not forbid that re-apply action.

## Approaches

1. Summary panel plus grouped, detailed review items, with a bulk approve for path-level kinds. Picked: removes the duplication, keeps pending and blocked reasons visible, and cuts fourteen clicks to one where that is safe.
2. Merge the two panels into one list. Rejected: pending and blocked reasons are not answerable, and mixing them with items blurs what needs a person.
