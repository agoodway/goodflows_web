## Context

See proposal.md for why. Today `GoodFlows.ChangeRequests.Rules` adds `diff_only_set` (`needs_review`, subject `[]`) on every head whenever `require_approved_intent` is true and only a diff set exists, and `Grading.names_head?/2` grades a diff set only when its `revision` is a prefix of the head. Decisions live in `scenario_set_decisions` keyed by change request and digest, and `ScenarioSets.approved?/2` returns false for every diff version. The grading design (`add-change-request-grading` D2) said "Diff sets are never approved: they only add ways to fail." This change revises D2: diff sets still take no approval before code, but a person can accept a weakened one.

## Goals / Non-Goals

**Goals:**
- A project without OpenSpec can gate on diff sets alone, with a person involved only when the set drops or demotes a Must.
- Docs-only pushes do not hold a diff-only change request `pending`.

**Non-Goals:**
- Judging the first diff version. Version 1 is the default baseline; `coverage.undriven_features` set to `blocked` is the only check on it.
- Counting an edited Must section as weakening.
- Renaming `require_approved_intent` or a `review-policy/2` format.
- Letting a change request linked to an OpenSpec change skip its intent set.
- CLI changes. No route is added.
- Revoking a diff acceptance. Once a digest is accepted no item exists for it, and the direct diff routes are `404`, so no API path rejects an accepted digest. The baseline still follows the latest-decision rule so the stored data has one meaning.

## Decisions

### D1. One outcome setting, `scenarios.diff_only`

`needs_review | weakening | ignore`, default `needs_review`. It follows the `should_failures` and `spec_gaps` pattern, so the document, validation and `effective` handling need one new key. The default keeps every written policy's verdicts.

Alternative: a `scenarios.require = none | any_set | approved_intent` enum replacing the boolean. Clearer name, but it changes the policy format and existing documents, and gives no behavior this setting lacks.

`diff_only` applies only when `require_approved_intent` is true. With it false no set is required at all, and adding a diff-only review there would make the off switch partly on.

### D2. Baseline, not the previous version

Weakening is measured from the baseline: the newest accepted diff version, else version 1. Comparing only to the previous version loses a weakening one upload later (v1 Must, v2 Should, v3 Should). The comparison reuses the existing compare logic (section digests and priorities) and keeps only `removed` and `demoted` entries of `must` scenarios as reasons. A renamed Must shows up as a removed Must, so renaming cannot hide a weakening. Scenarios that are `must` in both versions with a different section digest go into the item's `edited_musts` as information; a Should promoted to Must is not listed.

The compare endpoint's default `from` for diff sets stays the previous version, so existing clients see no change; a client can pass the baseline version as `from`.

### D3. Acceptance binds to the digest

The `revision` is in the diff set's bytes, so its digest changes on every push. A head-bound answer would bring the same weakening back on each push. So, as for intent approvals, the answer's effect is a decision on the digest:

```
  answers at head H on diff digest d2
  +-- diff_set_weakened S3: approve  \
  +-- diff_set_weakened S5: approve   > all approve -> approve decision on d2
                                                    -> d2 becomes the baseline
  +-- any reject -> reject decision on d2 + task
```

The decision is recorded only when the last weakened item at the head is approved, so a reviewer accepting one of two weakenings does not accept the other.

Item IDs come from rule and subject only, and `["diff", <id>]` does not change when the agent uploads a new diff version at the same head, which is the usual case after a failed run. Left alone, an `approve` given on `d2` would keep counting for `d3`. So storing a diff version supersedes every unsuperseded `diff_set_weakened` answer of the change request (setting `superseded_at`, and making their open tasks `stale`) in the upload transaction, before the recompute. This reuses the existing supersede mechanism and needs no answer column. A diff file reverted to an older digest needs new answers, which is acceptable because the accept decision, once recorded, is what persists.

Order in the answer transaction: check the approver, supersede the earlier answer to the item and insert the new one, then take the `diff_set_weakened` items of the stored verdict. If every one has a current `approve` answer, record the `approve` decision on the stored verdict's `scenarios.diff.digest` with the completing answer's membership and key, then recompute once. The item set cannot change mid-transaction, because every input write recomputes under the same change request row lock. `ScenarioSets.record_decision` gains a `source` so the stale-digest check compares against the current version of that source; `decide/5` keeps passing `intent`.

Decisions reuse `scenario_set_decisions`; no migration. Diff versions report `accepted`, not `approved`, so every rule and client that reads `approved` as "intent approved before code" keeps its meaning. The direct diff approval routes stay `404`: acceptance always happens next to the evidence in the packet. Decisions emit the existing `scenario_set_approved` and `scenario_set_rejected` events, which gain `source` (as `scenario_set_uploaded` already has), so subscribers can tell a diff acceptance from an intent approval. Intent and diff digests cannot collide, because `source` is part of the hashed bytes, so `approved_digests/1` returning both is safe; `approved?/2` already guards on source. Its doc and the `Decision` moduledoc are updated to say decisions cover both sources.

`diff_set_weakened` requires no linked OpenSpec change. A linked change request without an intent set is already `pending` on `scenario_set_approval`, and accepting a diff digest there would let review answers shape a gate that is meant to wait for the intent set.

Alternative: accept per scenario (store accepted IDs). Rejected: the baseline then becomes a set of exceptions instead of a version, and the item data cannot show one comparison.

### D4. Revision may name an earlier commit followed by ignored paths

`names_head?` keeps its prefix-of-head rule and gains the verify-run counting rule as a fallback: the `revision` is a prefix of exactly one commit in the head's `git-facts.commits`, and `Grading.counts?` holds for that commit's full SHA at the head (every later commit's changed files match `evidence.ignore_paths`). An ambiguous short SHA does not name the head. `Grading.set` therefore takes the facts' `commits` and the policy's ignore globs; without facts only the prefix rule applies. Counted runs are filtered to graded digests, so this fix also lets diff-set runs count after a docs-only push, as intended. This applies to every diff set, not only under `weakening`, because the mismatch with run counting was a bug either way.

## Risks / Trade-offs

- [A weak version 1 passes with no person] → Documented non-goal; recommend `coverage.undriven_features` `blocked` for diff-only projects.
- [An agent hollows out a Must's steps without demoting it] → Shown as `edited_musts` on any weakened item; not a reason by user decision.
- [A reviewer approves one weakened item, then the agent re-uploads at the same head] → Upload supersedes `diff_set_weakened` answers (D3), so the earlier approval never completes a later version.
- [Clients that assume diff versions never have decisions] → Decisions appear only after a `diff_set_weakened` answer, which exists only when a project opts in to `weakening`.

## Migration Plan

No data migration. Deploy with the default `needs_review`; a project opts in by writing `scenarios.diff_only`. Rollback: an older server still reads stored policies with `diff_only`, because `effective/1` merges the stored document over the defaults and keeps unknown keys, but it ignores the setting and refuses any write body containing it with `422`. Projects on `weakening` or `ignore` go back to `diff_only_set` on every head. Stored verdicts may hold `diff_set_weakened` reasons that the old item builder drops, so run `ChangeRequests.recompute_project/1` for affected projects after rollback. Diff decisions stay in `scenario_set_decisions` and the old server ignores them, because `approved?/2` returns false for diff versions.
