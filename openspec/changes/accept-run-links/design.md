# Design

## Context

The contract source is the goodflows change `add-run-links`: its `design.md` sections "Record shape" and "Server contract", and its `specs/run-history/spec.md`. That change isn't committed yet, so the design cites it by name. Its rules table is the client allowlist that goodflows `run_contract` will enforce, and this server mirrors it, as `accept-upload-envelope` mirrored the envelope tables.

What exists here today:

- `GoodFlows.WorkflowRuns.Validator` checks the document with `Shape` field tables. Optional keys are `{:omit, spec}`, so they're absent or non-null, and any other key is `has an unknown field` on its enclosing object. Cross-field checks run after the structural pass and merge into the 50-error cap in document order. The validator never rewrites a submitted value.
- `ingest/4` stores the validated document as `payload`, copies filter columns out of it, and compares retries by `payload_digest`. An exact retry is `200`, and any other difference is `409`.
- `list_runs/3` filters only on copied columns and never reads `payload`. Each filter value is validated with its field's rule, and a bad value is `422` on that parameter.
- Show returns `data.document`. For a `pk_` key, `WorkflowRunJSON` replaces command text with null, but only where the stored document has it.
- `accept-upload-envelope` is implemented but not archived. This change's MODIFIED requirements start from that change's text.

## Goals / Non-Goals

**Goals:**
- Every `links` value the CLI accepts is accepted here, and every value it rejects is rejected here.
- A ticket search returns both the PR runs, which carry threads, and the `main` runs, which carry only the ticket. A thread search returns the runs that thread produced.
- Stored runs and older clients keep working unchanged.

**Non-Goals:**
- Links in list summaries, or a cross-project search.
- Following ticket relations, or backfilling threads for squash-merged `main` runs.
- Validating that a thread URL points at Amp, or that a ticket exists in a tracker.

## Decisions

### D1. `links` field table

`links` is `{:omit, links_spec}` in `document_spec/0`:

| Key | Rule |
|---|---|
| `links` | optional object with only `threads` and `tickets`; `{}` is `must not be empty` on `links` |
| `links.threads` | optional, 1 to 32 entries, each a thread URL (D2), unique by exact string |
| `links.tickets` | optional, 1 to 32 entries, each `{:string, min: 1, max: 64, format: ~r/\A[!-~]+\z/}`, unique ignoring ASCII case |

A null for `links`, `threads`, or `tickets` is `is invalid`, like every omit-only key. Lists use the existing bounded-list messages (`must not be empty`, `must not have more than 32 entries`). The cross-field pass adds:

- `must not be empty` on `links` when it's an object with neither key.
- `must be unique` on each repeat after the first, on its own path, such as `links.tickets[2]`. This is the same message `graph.jobs[i].name` uses. Tickets compare after `String.downcase(t, :ascii)`. Thread URLs compare as exact strings, which is enough because D2 accepts only normalized URLs. The pass runs only on a list that is within bounds and whose entries are all valid strings, so a structural error isn't reported twice.

The deepest new path is document › `links` › `threads` › entry, at depth 3, so the depth limit of 8 is unchanged. In the worst case, links add 64 entries of at most 2,048 bytes each, which fits well inside the 4 MiB body cap. The order of `links` among the keys (after `ci`, before `results`) doesn't matter here, because documents are compared as JSON values.

### D2. Thread URLs must already be normalized

The CLI stores thread URLs in `reqwest::Url` (WHATWG) form. The contract says the server stores them "in normalized form". This server never rewrites a submitted value. A private-key show must equal the upload, and an exact retry is decided by digest. So the validator requires normal form instead of producing it. A thread URL (`{:fun, &thread_url_errors/2, :thread_url}`) is valid when:

1. It's a string of at most 2,048 bytes. Otherwise it's `is too long`.
2. `URI.new/1` succeeds, the raw string starts with `https://`, the host is nonempty, and `userinfo`, `query`, and `fragment` are all nil. Otherwise it's `is invalid`. `?` with an empty query, or `#` with an empty fragment, still counts as present.
3. It's normalized: the host has no ASCII uppercase letter, `URI.to_string/1` of the parsed URI equals the input, which rules out an explicit port 443, the path is nonempty, and no path segment is `.` or `..`. Otherwise it's `must be normalized`.

These are the changes the WHATWG serializer makes to an `https` URL that passes rule 2, and its output already satisfies them. So every URL the CLI sends passes. The one gap is in rule 2. `URI.new/1` follows RFC 3986, which rejects some path characters that WHATWG leaves unencoded, such as `|` and `^`. goodflows `add-run-links` closes that gap: its `run_contract` rejects characters outside RFC 3986 in a thread URL and rejects, rather than rewrites, a URL that isn't normalized. Amp thread URLs (`https://ampcode.com/threads/T-<uuid>`) parse the same way under both standards.

Rejected alternative: normalize on ingest. It would make a private-key show differ from the upload. It would also let two different bodies resolve to the same stored document, which breaks the rule that only an exact retry is a duplicate, and it would need a WHATWG serializer in Elixir.

### D3. Columns and indexes

One migration adds `link_tickets` and `link_threads`, both `text[] NOT NULL DEFAULT '{}'`, and a GIN index on each: `workflow_runs_link_tickets_index` and `workflow_runs_link_threads_index`. `ingest/4` copies them from the validated columns. `link_tickets` holds each ticket lowercased with `String.downcase(t, :ascii)`. `link_threads` holds each URL as sent. `payload` keeps the original spelling.

- `ticket=<id>` is validated with the ticket rule, lowercased the same way, and matched with `link_tickets @> ARRAY[$1]`.
- `thread_url=<url>` is normalized first: the scheme and host are lowercased, an explicit port 443 is removed, and an empty path becomes `/`. The result must then be a valid thread URL (D2), or the response is `422` on `thread_url`. It is matched with `link_threads @> ARRAY[$1]`. So `HTTPS://AmpCode.com/threads/T-…` finds a run stored as `https://ampcode.com/threads/T-…`.
- Both filters combine with the others using AND and keep the keyset order. A run without links has empty arrays and never matches.

A GIN index can't carry `(account_id, project_id, started_at, run_id)`, so the planner uses a bitmap scan on the array, rechecks the project, and sorts. That's fine because one ticket or thread matches a handful of runs. Adding a column with a constant default is a catalog-only change in PostgreSQL 11 and later, so existing rows are not rewritten.

Rejected alternative: a `workflow_run_links` child table with a btree index on `(account_id, project_id, kind, value, started_at DESC, run_id DESC)`. It would give a keyset index per value, but it adds up to 64 rows per upload, a second insert inside the idempotent store path, and a join on every list. Every other filter is a column on the row. If one ticket ever spans thousands of runs, it can be added later without changing the API.

### D4. Public keys don't see thread URLs

In a `pk_` show, `WorkflowRunJSON` sets `links.threads` to null when the stored document has `links.threads`. `links.tickets` and the rest of the document are unchanged. When the document has no `links`, or a `links` without `threads`, nothing is added. This matches how condition `text` is redacted, and the CLI then prints a `thread -` row only when the run has threads. The show response's OpenAPI `document` schema marks `links.threads` as nullable, in the same way it marks `command` and condition `text`.

A `pk_` key can still filter by `thread_url`, as the contract says. That only tells a caller whether a run exists for a URL it already has, and thread IDs are random UUIDs.

### D5. Compatibility and rollout

- **Older CLI clients:** `links` is optional. A document without it validates, stores, and retries exactly as before, and `schema_version` stays 1.
- **Stored runs:** none can contain `links`, because the server rejected that key until now. The new columns default to `'{}'`, so nothing is backfilled. Their show output is unchanged, and they never match `ticket` or `thread_url`.
- **Order:** deploy this before the goodflows release that sends `links`. If the CLI ships first, every record with links gets a `422`. The CLI keeps such records pending, and they replay once this is deployed.
- **Rollback:** drop both indexes and columns. After rollback, uploads with `links` get a `422` again. Rows already stored keep `links` in `payload`.

### D6. Fixtures and OpenAPI

The vendored fixtures stay at goodflows `4fa1da796a36135b9bcf219ba0db66c591884918` until `add-run-links` is committed. Until then, tests build link documents by adding a `links` object to the vendored `full.json`. goodflows `add-run-links` adds `tests/fixtures/workflow-runs/links.json`. Once that change is implemented and committed, `links.json` is vendored the same way, and the README's commit and digests are updated. The OpenAPI request schema is generated from the new tables, with a `:thread_url` clause in `WorkflowRunParts.to_schema/1`. The list operation documents `ticket` and `thread_url`, and the API description explains links and their redaction.

## Risks / Trade-offs

- [The CLI and server disagree on a URL] → D2's normal-form rules are exactly what the WHATWG serializer guarantees. Contract tests cover the cases where the two can differ: case, port 443, an empty path, dot segments, an empty query or fragment, and `|` in a path.
- [MODIFIED requirements overlap `accept-upload-envelope`] → Archive `accept-upload-envelope` first. This change's MODIFIED text already includes it, so archiving in that order leaves both changes in the main spec.
- [`pk_` keys can probe for thread URLs] → Accepted by the contract. A probe needs the full URL.
- [A large project's ticket search sorts its matches] → The matches are bounded by the runs that name the ticket. D3 names the upgrade path.

## Migration Plan

1. Archive `accept-upload-envelope`, which is already implemented.
2. Land and deploy this change. The migration is additive.
3. Tell goodflows that the server accepts `links`, so `add-run-links` can ship.
