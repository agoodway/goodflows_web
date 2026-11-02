# Design

## Context

See proposal.md for why the closed tag list has to go. Today `suite_started.filters` is `{include, exclude}`, and each entry is `{tag, value}`. `tag` is the enum `chrome`, `goodaudit_integration`, `athena_preview`, `chromic_teardown`, `qpdf` (`GoodFlows.TestReports.Validator.@filter_tags`). `value` is a boolean. `GoodFlowsWeb.Schemas.TestReportParts` builds the OpenAPI schema from that spec, so the enum is the published contract. `filter_tags/0` has no other caller. This change supersedes the tag enum in `store-test-timings` D1 (`openspec/changes/archive/2026-11-01-store-test-timings/design.md:63`); `value` stays boolean.

Suite and report ids already use `identifier/0`: 1 to 128 bytes, `[A-Za-z0-9][A-Za-z0-9._-]*`. A string that fails the pattern gets `has invalid format`; one past 128 bytes gets `is too long`. Neither message includes the submitted text.

## Goals / Non-Goals

**Goals:**

- Validate a filter tag with the existing identifier rule and keep `value` boolean.
- Leave include and exclude order, repeats, and unknown-field rejection as they are.
- Let the generated OpenAPI schema and the API description follow the validator.

**Non-Goals:**

- Editing `goodci` or `goodcases`. Those companions copy or narrow this contract in their own changes.
- Accepting non-boolean ExUnit filter terms (`line`, a test name, a regex).
- A per-project tag catalog, a database migration, or a change to stored rows.

## Decisions

### Reuse the suite-id identifier for `tag`

Replace `{:enum, @filter_tags}` with `identifier/0` and delete `@filter_tags` and `filter_tags/0`. The five current names match the grammar, so documents that already pass stay valid. `slow` and `goodaudit_integration` pass. `slow test`, `ok?`, and a 129-byte tag do not.

`TestReportParts.pattern/1` already turns that regex into the OpenAPI pattern. No hand-written schema edit. The validator regex is anchored with `\A...\z`, so `slow` followed by a newline is rejected; the published `^...$` pattern is correct for ECMA-262 JSON Schema consumers.

Tag errors change from the enum's `is invalid` to the string-identifier messages from `Shape.string_error/2`, which checks size before format: `has invalid format` for `slow test` or `ok?`, `is too long` past 128 bytes, `can't be blank` for `""`, and `must be a string` for a non-string such as `1`. All are fixed messages and none include the submitted text. Tags are case-sensitive and not normalized (`Chrome` and `chrome` are distinct), matching ExUnit's distinct atoms.

### Cap each filter list at 256 entries

`filters.include` and `filters.exclude` have never had a length cap; the old enum limited distinct values, not entries. With any identifier now accepted, one document could carry thousands of free-form identifier strings (including token-like values) in JSONB. Cap each list at 256 entries, with the fixed message `must not have more than 256 entries`, and publish it as OpenAPI `maxItems`. As with `report.records` (`records_errors/2`), an over-cap list gets only that error and its entries are not checked, so the cap error is never crowded out by the 50-error limit. Real ExUnit filter lists are a handful of entries. The 32 MiB body cap, 16-level depth limit and 50-error cap still apply.

Alternative: a shorter tag length than 128 bytes. Rejected. The suite-id grammar is the one the CLI already checks, and a second length rule is another thing to keep aligned.

Alternative: a new, wider tag grammar that allowed `?` and `!`. Rejected. ExUnit category tags in use are plain identifiers, and a wider grammar is a second string rule to keep aligned with the CLI.

Alternative: any string up to 4,096 bytes. Rejected. That is the freeform field the closed list was preventing.

### Keep boolean values and supplied order

`value` stays `:boolean`. The server stores the arrays it validated, including a repeated tag, and does not drop or reorder entries. A producer that wants a non-identifier boolean tag omitted has to omit it before upload. This server answers 422 for the whole document.

Alternative: coerce a bare atom or drop a bad entry and accept the rest. Rejected. Ingest does not rewrite a valid document, and a partial filter list would hide the slice that actually ran.

### Say the rule in the API description

`GoodFlowsWeb.ApiSpec` describes suite ids with this grammar and says parameter values are not accepted. It does not mention the tag enum. Add the same identifier-and-boolean rule beside the suite-id sentence so the prose matches the schema.

## Risks / Trade-offs

- [An old goodci build rejects any tag outside `FILTER_TAGS` before it freezes a snapshot, so the report never becomes replayable] → Ship this server first. It still accepts the five names. Release a CLI that uses the identifier check, then let the GoodCases formatter emit every boolean identifier filter. Until that CLI is out, a hand-built upload can send `slow` and the current CLI cannot.
- [Rolling the server back makes new tags 422 again] → Rows already stored stay as inserted. Rollback does not rewrite JSONB. Only new uploads with a tag outside the old enum fail. Validation runs before the digest comparison, so an exact retry of an already-stored report with a non-enum tag (e.g. after an unconfirmed `503`) returns 422 after rollback instead of `200` with `duplicate: true`. Roll back only before a goodci release that emits wider tags, or accept that such retries fail.
- [Tags can now hold secret-like identifier strings (e.g. a token that matches the grammar), which are stored in JSONB as sent] → Accepted risk. Each tag is at most 128 bytes and each of `include` and `exclude` at most 256 entries, so a document cannot carry an unbounded free-form payload. Error messages never echo a tag.
- [A producer sends `{tag: "ok?", value: true}` and the whole report is rejected] → The GoodCases formatter, in its own change, records boolean filters whose tag matches this grammar and drops the rest. This server does not repair the document.

## Migration Plan

1. Deploy this server. Existing GoodCases reports remain valid.
2. Update `goodci` `src/reporting/contract.rs`: remove `FILTER_TAGS`, check the identifier grammar, and bump `CONTRACT_VERSION` to this change. Release that CLI before producers emit other tags.
3. In GoodCases `publish-test-timings`, remove `@categories` from `GC.TestTimingFormatter`. Record every boolean include and exclude whose tag matches the grammar, in ExUnit's order. A bare atom is `{tag, true}`. Drop a non-boolean filter and a boolean tag that is not an identifier.

No migration. Rollback is restoring the enum in the validator (and removing the list cap). Uploads that used only the five names keep working; see the retry caveat under Risks.
