# Design

## Context

See proposal.md. `GoodFlows.Calibration.report/2` selects change requests by `merged_at` in `[from, to)`, groups their defects by change request (`defects_of/1`), assigns each change request a lane, and computes each defect's files for the glob breakdown (`defect_files/2`). Each defect's list entry is assembled from values the report already has.

## Goals / Non-Goals

**Goals:**
- Every count in the report can be traced to the defects behind it from the same response.
- Unattributed defects show up in the report.
- No new route and no change to existing fields.

**Non-Goals:**
- Paging the report.
- Listing unattributed defects. `GET .../defects` does that.
- Severity weighting in `defect_rate`.

## Decisions

### D1. Entries carry the calibration context

An entry is the `GET .../defects` shape plus `lane`, `policy_version`, `rules` and `globs`:

```json
{"id": "…", "change_request": 43, "commit": "c3d4e5f…", "attribution": "commit",
 "severity": "high", "ticket": "GOO-512", "recorded_at": "2026-11-03T09:00:00Z",
 "lane": "reviewed", "policy_version": 7, "rules": ["path_match"],
 "globs": ["app/priv/repo/migrations/**"]}
```

`rules` is the distinct, sorted `rule` values of the change request's `merge.reasons` (the same values `rule_stats` counts). `rules` is `[]` for a defect whose change request is in `gaps`. `globs` is the sorted globs, out of all the globs the report lists, that match the defect's files. `globs` is `[]` for a defect counted in `unmatched_defect_count`. These are the same matches `glob_stats` counts, so the list and the counts cannot disagree.

Alternative considered: return change request numbers per lane and rule, and let clients join them with `GET .../defects`. Rejected because it makes every client do the join and still needs a request per page of defects.

### D2. Cap at 500, newest first

The report is computed on read and is not paged. A 90-day window rarely holds more than a few dozen defects, but nothing bounds the number. The list is ordered by `recorded_at` descending, then `id` descending (the order of `GET .../defects`), and cut at 500 entries, with `defects_truncated` true when it was cut. Counts are computed before the cut. Paging would need a cursor that is stable across `from`/`to` and would make the report stateful, so it is left out.

### D3. Unattributed defects are counted by `recorded_at`

An unattributed defect has no change request and so no `merged_at`. It is counted when its `recorded_at` is in `[from, to)`. It counts toward no lane, rule, glob, `gaps` or `unmatched_defect_count`, so the existing counts keep their meaning.

### D4. Ticket redaction

`ticket` is the only restricted field in a defect. The controller passes `redact?: not ApiKey.can_write?(key)` and renders each entry with the defect renderer `DefectJSON` already uses, so the report and `GET .../defects` render a defect the same way.

## Risks / Trade-offs

- A large window can return 500 entries (a few hundred KB). This is accepted, and the cap bounds it.
- Unattributed defects use a different time axis (`recorded_at`) than the rest of the report (`merged_at`). The field name and the OpenAPI description say so.
