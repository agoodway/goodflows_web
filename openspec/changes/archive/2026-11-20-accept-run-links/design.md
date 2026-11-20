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
| `links.tickets` | optional, 1 to 32 entries, each `{:string, min: 1, max: 64, format: ~r/\A[!-+\--~]+\z/}` (printable ASCII other than `,`), unique ignoring ASCII case |

A null for `links`, `threads`, or `tickets` is `is invalid`, like every omit-only key. Lists use the existing bounded-list messages (`must not be empty`, `must not have more than 32 entries`). The cross-field pass adds:

- `must not be empty` on `links` when it's an object with neither key. So an object with only unknown keys, such as `{"prs": [1]}`, gets both `has an unknown field` and `must not be empty` on `links`.
- `must be unique` on each repeat after the first, on its own path, such as `links.tickets[2]`. This is the same message `graph.jobs[i].name` uses. Tickets compare after `String.downcase(t, :ascii)`. Thread URLs compare as exact strings, which is enough because D2 accepts only normalized URLs. The pass runs only on a list that is within bounds and whose entries are all valid strings, so a structural error isn't reported twice.

The deepest new path is document › `links` › `threads` › entry, at depth 3, so the depth limit of 8 is unchanged. In the worst case, links add 64 entries of at most 2,048 bytes each, which fits well inside the 4 MiB body cap. The order of `links` among the keys (after `ci`, before `results`) doesn't matter here, because documents are compared as JSON values.

### D2. Thread URLs must already be normalized

The rule is goodflows `add-run-links` at `af43276`, design "Record shape": the CLI stores thread URLs in the form `reqwest::Url` (WHATWG) serializes, and its `run_contract` rejects, rather than rewrites, a URL that isn't already in that form or whose path breaks the RFC 3986 character rule. This server never rewrites a submitted value either. A private-key show must equal the upload, and an exact retry is decided by digest. So the validator checks the same form instead of producing it. A thread URL (`{:fun, &thread_url_errors/2, :thread_url}`) is valid when:

1. It's a string of at most 2,048 bytes. Otherwise it's `is too long`.
2. The raw string starts with `https://`, `URI.new/1` succeeds, the host is nonempty, the port is at most 65,535, and `userinfo`, `query`, and `fragment` are all nil. Otherwise it's `is invalid`. `?` with an empty query, or `#` with an empty fragment, still counts as present.
3. The path matches `\A(?:[A-Za-z0-9\-._~!$&'()*+,;=:@/]|%[0-9A-Fa-f]{2})*\z`: every byte is an RFC 3986 `pchar` (unreserved, sub-delims, `:`, `@`) or `/`, and every `%` starts a `%` plus two hex digits. Otherwise it's `is invalid`. `URI.new/1` already rejects `[`, `]`, `|`, `^`, `` ` `` and `\` in a path, but on Elixir 1.19.4 it accepts `%zz` and a trailing `%`, so this check is needed.
4. It's in normal form. Otherwise it's `must be normalized`:
   - `URI.to_string/1` of the parsed URI equals the input. This rejects a port that is empty, zero-padded, or 443 (`:`, `:080`, `:0443`, `:443`).
   - The path is nonempty (`https://h` is not normal; `https://h/` is).
   - No path segment is a dot segment. A segment counts as one when, ignoring ASCII case, it is `.`, `%2e`, `..`, `.%2e`, `%2e.` or `%2e%2e`. WHATWG resolves all of these, so `https://h/%2e%2e/y` serializes as `https://h/y`.
   - The host has no ASCII uppercase letter and no `%`. WHATWG lowercases and percent-decodes a host, so `ex%41mple.com` serializes as `example.com`.
   - An IP host is in WHATWG's serialized form. When the host's last label, ignoring one trailing dot, is a number (ASCII digits, or `0x` followed by hex digits), the host must be four decimal octets from 0 to 255, without leading zeros or a trailing dot (`0x7f.1` serializes as `127.0.0.1`). A bracketed IPv6 host must equal WHATWG's IPv6 serialization: lowercase hex groups without leading zeros, the first longest run of two or more zero groups written as `::`, and no dotted-quad tail (`[0:0:0:0:0:0:0:1]` serializes as `[::1]`).
   - Percent triplets are compared exactly as written. They are never decoded and their hex case never changes, so `%7E` stays `%7E` and `%2f` stays `%2f`. This deliberately skips RFC 3986 section 6.2.2 percent normalization. WHATWG doesn't apply it either, and applying it would reject valid CLI records with `422`.

For a path that passes rule 3, the WHATWG serializer changes only dot segments, because every character in its path percent-encode set is outside `pchar`. The CLI defines normalized as `Url::parse(s).as_str() == s` and lists the same cases: `%2e` dot segments, a percent-encoded host, non-canonical IPv4 and IPv6 hosts, and the ports `:080` and `:0443`. With rule 4 covering the scheme, host, port and empty-path rewrites, a URL passes here exactly when it passes the CLI's rule. The contract tests pin each case, and the CLI's shared fixture set includes `/a/%2E%2e/b`. Amp thread URLs (`https://ampcode.com/threads/T-<uuid>`) pass both unchanged.

Rejected alternative: normalize on ingest. It would make a private-key show differ from the upload. It would also let two different bodies resolve to the same stored document, which breaks the rule that only an exact retry is a duplicate, and it would need a WHATWG serializer in Elixir.

### D3. Columns and indexes

One migration adds `link_tickets` and `link_threads`, both `text[] NOT NULL DEFAULT '{}'`, and a GIN index on each: `workflow_runs_link_tickets_index` and `workflow_runs_link_threads_index`. `ingest/4` copies them from the validated columns. `link_tickets` holds each ticket lowercased with `String.downcase(t, :ascii)`. `link_threads` holds each URL as sent. `payload` keeps the original spelling.

- `ticket=<id>` is validated with the ticket rule, lowercased the same way, and matched with `link_tickets @> ARRAY[$1]`.
- `thread_url=<url>` is normalized first, by rewriting the string. The scheme and the authority (host and port) are lowercased. A trailing `:<digits>` port whose value is empty or 443, including zero-padded forms (`:`, `:443`, `:0443`), is removed. An empty path becomes `/`. Everything else stays as sent: percent triplets are left exactly as written, as D2 requires, so `%7e` doesn't match a stored `%7E`, and a dot segment, a percent-encoded host, a non-canonical IP address or another port spelling such as `:080` is not changed. The URL isn't rebuilt with `URI.to_string/1`, because that would also rewrite `:080` to `:80`. The result must then be a valid thread URL (D2), or the response is `422` on `thread_url`. It is matched with `link_threads @> ARRAY[$1]`. So `HTTPS://AmpCode.com/threads/T-…` finds a run stored as `https://ampcode.com/threads/T-…`.
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
- **Rollback:** roll back the code, not the migration, and keep the D4 redaction. Runs stored while this change was live keep `links` in `payload`, and the current `WorkflowRunJSON` redacts only results and graph text, so a plain code rollback would show their `links.threads` to `pk_` keys. A rollback build therefore reverts validation, the filters and OpenAPI, and keeps the `links.threads` redaction. After it, uploads with `links` get a `422` again. The columns and indexes stay: older code never writes them, so new rows get `'{}'`, and a later redeploy finds the earlier link runs again without a backfill. The migration's `down` is for development only. Dropping the columns in production would lose those copies, and re-adding them would then need a backfill from `payload`.

### D6. Fixtures and OpenAPI

This change doesn't vendor any fixture. "Uploads match the goodflows client contract" pins the vendored fixtures to goodflows `4fa1da796a36135b9bcf219ba0db66c591884918` and lists exactly five files, and this change leaves that requirement as it is. Tests build link documents by adding a `links` object to the vendored `full.json` in memory. goodflows `add-run-links` adds `tests/fixtures/workflow-runs/links.json`, which doesn't exist on any goodflows commit yet. Once it does, a follow-up change MODIFIES that requirement to name the new commit and `links.json`, vendors the files, and updates the README's commit and digests. Keeping it separate means this change doesn't wait on an outside commit. The OpenAPI request schema is generated from the new tables, with a `:thread_url` clause in `WorkflowRunParts.to_schema/1`. The list operation documents `ticket` and `thread_url`, and the API description explains links and their redaction.

## Risks / Trade-offs

- [The CLI and server disagree on a URL] → Both sides use the one definition in goodflows `add-run-links` "Record shape", and D2 spells it out. Contract tests cover the cases where the two could differ: an uppercase host, `:443` and `:0443`, an empty path, dot segments including `%2e%2e`, a bare `?` or `#`, `[`, `|`, `%zz`, a trailing `%`, `%7E` and `%2f` kept as written, a percent-encoded host, and non-canonical IPv4 and IPv6 hosts. The CLI's `links.json` fixture pins the `%7E` and `%2E%2e` cases once the follow-up change in D6 vendors it.
- [MODIFIED requirements overlap `accept-upload-envelope`] → Archive `accept-upload-envelope` first. This change's MODIFIED text already includes it, so archiving in that order leaves both changes in the main spec.
- [`pk_` keys can probe for thread URLs] → Accepted by the contract. A probe needs the full URL.
- [A large project's ticket search sorts its matches] → The matches are bounded by the runs that name the ticket. D3 names the upgrade path.

## Migration Plan

1. Archive `accept-upload-envelope`, which is already implemented.
2. Land and deploy this change. The migration is additive.
3. Tell goodflows that the server accepts `links`, so `add-run-links` can ship.
