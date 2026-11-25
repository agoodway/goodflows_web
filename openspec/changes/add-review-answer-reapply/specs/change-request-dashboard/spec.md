## MODIFIED Requirements

### Requirement: The detail page shows the review packet
For a change request in state `draft` or `open`, the detail page SHALL show the review packet at the current head: each item's kind as a readable name, its message, and its current answer at the head with who gave it, when, and the option and note. An item with no answer at the head MUST say so. An answer given at another head MUST NOT be shown as the item's answer or counted. A merged or closed change request SHALL show no review items.

#### Scenario: Answered and unanswered items
- **WHEN** change request 46 has a `one_way_door` item approved by member T at the current head and a `sensitive_path` item with no answer at the head
- **THEN** the page shows `1 of 2 cleared`, the one-way door item as approved by T with the time, and the sensitive path item as having no answer at this head

#### Scenario: Answer at an earlier head
- **WHEN** an item was approved at head `a1b2c3d…` and head `d4e5f6a…` is now current
- **THEN** the item shows no answer at this head and the cleared count does not include it

## ADDED Requirements

### Requirement: The detail page shows earlier answers
When an item has an `earlier_answer`, the page SHALL show it apart from the current answer, with who gave it, the short head, the answer, the option and the note. It SHALL show `Unchanged since` or `Changed since` with the commit count when `item_paths_changed` is set, the commit count alone when it is null, and `History rewritten since` when `changed_since` is null. A re-applied current answer SHALL show whose answer it re-applied and from which head.

#### Scenario: Earlier approval on an untouched item
- **WHEN** an item was approved by T at head `a1b2c3d…`, head `d4e5f6a…` is now current, and the one commit since did not touch the item's paths
- **THEN** the item shows `Approved by T at a1b2c3d` with T's note and `Unchanged since · 1 commit`

#### Scenario: After a rebase
- **WHEN** an item's `changed_since` is null
- **THEN** the item shows its earlier answer with `History rewritten since`

### Requirement: Members re-apply earlier answers in the dashboard
On the detail page of a change request in state `draft` or `open`, each item whose `earlier_answer.reapplicable` is true SHALL offer a re-apply action named after the answer (`Re-approve`, or `Re-choose <option>`). The review panel SHALL offer `Re-apply unchanged (<n>)` when at least one item is re-applicable with `item_paths_changed` false. It MUST NOT include items whose `item_paths_changed` is true or null. The dashboard rules on who may answer SHALL apply.

#### Scenario: Changed item is left out
- **WHEN** two `open_item`s were approved at the previous head and one of them has `item_paths_changed` true
- **THEN** the panel offers `Re-apply unchanged (1)`, and the changed item offers its own `Re-approve` and the normal answers

### Requirement: Dashboard re-apply has the API's effects
Each re-apply action SHALL open a confirm dialog listing the items it covers with their earlier answers. Confirming SHALL store the answers as the reapply route does, by the signed-in member's membership with channel `dashboard` and a null key, for the head the page showed. When the head moved, nothing SHALL be stored and the page SHALL show the flash `A new head was reported. Review the items at the new head.`

#### Scenario: Re-apply unchanged items
- **WHEN** neither of two approved `open_item`s changed and member M confirms `Re-apply unchanged (2)`
- **THEN** both items show as approved by M, re-applied from T's answer at the previous head, and the page shows `2 of 2 cleared`

#### Scenario: Head moved before confirm
- **WHEN** M opens the re-apply dialog at head `H2`, head `H3` is then reported, and M confirms
- **THEN** nothing is stored and the page shows the new-head flash
