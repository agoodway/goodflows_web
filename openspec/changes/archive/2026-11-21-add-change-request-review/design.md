# Design

## Context

See proposal.md for motivation. The verdict from `add-change-request-core` stores one reason per rule that fired, with a stable `rule` and `subject`. Phase 2 adds scenario, evidence and coverage reasons. This phase turns `needs_review` reasons into packet items and lets answers resolve them.

## Goals / Non-Goals

**Goals:**
- A person reads only what policy flagged, with the evidence next to each item.
- An agent knows its next step from the verdict and its tasks alone.
- Clients learn about changes without tight polling.

**Non-Goals:**
- A web review page, webhooks, email.
- Carrying answers across heads.
- Proving that a person, not an agent, answered. The channel is recorded for later policy.

## Decisions

### D1. Packet = `needs_review` reasons at the head

```
  CR 42 · head a1b2c3d · base main@9f8e7d6 · policy v7
  verdict: needs_review (3 items) · passed: 6 Must, 2 Should, ci workflow
  [1] scenario_set_approval  ...  approve | reject
  [2] one_way_door           ...  approve | request_change
  [3] failed_scenario (Should)...  approve | request_change
```

- Item ID is the reason's `rule` plus a digest of its `subject`, scoped to the head. Phase 1 makes `rule` plus `subject` unique per verdict. Split items use `[<question id>]` and `[<index>, <risk>]`.
- Kinds by rule: `scenario_set_approval`, `diff_only_set`, `spec_gap`, `one_way_door`, `unmapped_area` and `undriven_feature` from the rules of the same name; `failed_scenario` from `should_failed`; `not_run` from `should_not_run`; `unproven_claim` from `proof_below_minimum`; `question` and `open_item` from `open_items`; `sensitive_path` from `path_match`; `size` from each of `max_changed_files` and `max_changed_lines` (one item each).
- `pending` and `blocked` reasons are listed in the packet header for context but are not answerable: they are resolved by uploading inputs or fixing code.
- `failed_scenario` (from `should_failed`) and `not_run` (from `should_not_run`) items exist only for Should scenarios; a Must that failed or did not run is `blocked`. `accept_as_known` does not exist.
- There is no `manual_check` item in v1: `qa-scenarios/2` front matter has no key for a set's "Not covered" checks. Adding one is a later change to the goodstack skills and to `add-change-request-grading`'s front matter validation.
- `scenario_set_approval` is answered with the phase 2 approval call; the packet links to it and shows the weakening-first version comparison. Its phase 2 outcome is `pending`, so it is the one `pending` reason shown as an answerable item, and only when an intent version exists (subject `[<digest>]`); with no intent set there is nothing to approve and it stays in the `pending` list. `approve` and `reject` on it record the same digest-bound decisions as the phase 2 approval and rejection calls. The item also appears before any Git facts exist, because the set is approved before code: the packet then has `head` null, and the answer is posted with `head: null`.
- `unproven_claim` items show each `change-claims/2` `safe_because` entry below `min_proof_level` with its `evidence` and `covers`. `spec_gap` items show the row's `{capability, requirement, scenario}` and any covering `safe_because` entry, which is below the minimum or the gap would not fire.
- The server has no repository, so hunks come only from the claims document's `decisions`. The full diff stays on the host.
- Artifact URLs are presigned on each packet read and expire in 15 minutes. `pk_` keys get no packet.

### D2. Answers bind to the head

An answer stores the head it was given at. Only answers at the current head count; when a re-report makes an earlier head current again, its answers count again. Alternative considered: carry answers forward while an item's key is unchanged. Rejected by the user: every push is reviewed in full.

| Answer | Effect |
|---|---|
| `approve` | clears the item |
| `choose(option)` | clears a `question` item; option must be one of the item's options |
| `request_change` | item stays open; creates a task |
| `reject` | item stays open; creates a task; on `scenario_set_approval` records a phase 2 `reject` decision on that digest, which unapproves it |

A later answer to the same item at the same head replaces the earlier one. Who may answer: any `sk_` key on the account, except `scenario_set_approval`, which follows `scenarios.approver`.

### D3. Tasks

A task holds the item, the answer's note, the head, and a state `open`, `stale` or `done`. The author agent lists open tasks and marks them done. A new head does not close tasks automatically; it makes them `stale`, and the agent decides.

### D4. Event feed

```
  state change in a transaction --> insert event row --> after commit: PubSub broadcast
  GET /events?after=<cursor>&wait=30
    events after cursor exist -> return them
    else subscribe to topic, wait up to `wait` seconds, then query again
```

- Events are inserted in the same transaction as the change they describe, so the feed never shows a change that rolled back. This phase wires emission into the phase 1 and 2 code (state changes including the merge report, verdict recompute, set uploads and decisions, policy writes); phases 1 and 2 need no event tasks.
- Each event has a top-level `number` (or null) and `actor` (`user_id`, `key_id`); `data` holds only the type's own fields. Phase 4 events follow the same shape.
- Cursor is the event's monotonically increasing ID, validated as a non-negative integer through a changeset (errors on `after`). Retention: 90 days; a cursor older than the oldest event returns `410` so the client resyncs from current state.
- `wait` is 0 to 30 seconds. Each node limits concurrent waiting requests per account; over the limit returns immediately.

## Risks / Trade-offs

- [Full re-review on every push slows agents that push often] -> Accepted trade-off; agents should finish work before marking a change request `open`. Phase 4 grades merge results without pushing to the change request branch, so merging does not clear answers.
- [Long-poll holds HTTP connections] -> Bounded `wait` and a per-account limit.

## Migration Plan

New tables and routes. Ship after phase 2 and before the CLI's review commands.
