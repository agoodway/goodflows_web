# Proposal

## Why

After phases 1 and 2 (`add-change-request-core`, `add-change-request-grading`), a change request whose verdict is `needs_review` has no way forward: there is nothing to show a person and nowhere to record their decision. Agents also have no way to learn that a verdict changed except by asking again. This phase adds the review packet, which shows only what the policy flagged, answers bound to the head, tasks the author agent fetches, and a per-project event feed with long-poll.

Depends on `add-change-request-core` and `add-change-request-grading`.

## What Changes

- Serve a review packet for a change request's head: one item per reason in the verdict that needs a person, plus a one-line summary of what passed. Item kinds: `scenario_set_approval`, `diff_only_set`, `failed_scenario`, `not_run`, `spec_gap`, `one_way_door`, `unproven_claim`, `open_item`, `question`, `sensitive_path`, `size`, `unmapped_area`, `undriven_feature`. Manual checks from a scenario set's "Not covered" section are not items in v1, because `qa-scenarios/2` front matter has no key for them. Each item carries the data a reviewer needs (claims, decision hunks from the claims document, Expect versus observed, presigned artifact URLs) and the answers it allows.
- The packet is data. Clients render it; the CLI renders Markdown with images. No web UI in v1.
- Record answers per item: `approve`, `reject`, `request_change`, or `choose(option)` with an optional note, the membership, key, channel and head. Answers bind to the head: any new head clears them and the next packet is reviewed in full, and they count again if that head becomes current again. Scenario set approval and rejection keep their phase 2 rule and bind to the set digest.
- A `needs_review` verdict becomes `mergeable` when every item has `approve` or `choose` at the head. `reject` and `request_change` keep it at `needs_review` and create tasks the author agent lists and marks done. `blocked` cannot be overridden by any answer.
- Add an append-only per-project event feed with a keyset cursor and an optional `wait` up to 30 seconds (long-poll). Events: `cr_state_changed`, `verdict_changed`, `scenario_set_uploaded`, `scenario_set_approved`, `scenario_set_rejected`, `answer_recorded`, `task_created`, and `policy_version_created`. Phase 4 adds lease events. `pk_` keys get the same events with restricted fields hidden.

## Capabilities

### New Capabilities

- `change-request-review`: the review packet, answers, and tasks.
- `project-events`: the per-project event feed and long-poll.

### Modified Capabilities

- `change-requests`: `needs_review` resolves to `mergeable` through answers at the head.

## Impact

- New tables for answers, tasks and events. Long-poll subscribes to a per-project Phoenix PubSub topic, so a waiting request holds no database connection.
- Companion CLI change: `cr review`, `cr answer`, `cr tasks`, `cr wait --until <states>`, `events`.
- Webhooks, email and a web review page are out of scope; they can be built on the event feed and packet data later.
