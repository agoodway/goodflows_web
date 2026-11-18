# Proposal

## Why

When a production bug is filed against a ticket, nothing connects that ticket to the goodflows runs that tested the change or to the agent threads that wrote it. The goodflows CLI change `add-run-links` adds an optional `links` object to the run record, with the agent thread URLs and ticket IDs behind the change. The server validates the run record against an allowlist and rejects unknown keys, so today every record that has `links` gets a `422`. This change accepts `links`, makes runs searchable by ticket and by thread, and has to ship before the CLI change.

The contract is the CLI change's `design.md` ("Record shape" and "Server contract") and its `run-history` spec delta. Because that change is not committed yet, this proposal cites it by name, not by commit.

## What Changes

- Accept an optional top-level `links` object on `POST /api/v1/projects/:project/workflow-runs`. It holds only `threads` and `tickets`, and at least one of them. An empty `links`, a null, or an unknown key inside it is `422`.
  - `threads`: 1 to 32 unique `https` URLs, each with a host and no userinfo, query, or fragment, at most 2,048 bytes, and already in normalized form.
  - `tickets`: 1 to 32 IDs, unique ignoring ASCII case, each 1 to 64 bytes of printable ASCII with no whitespace.
- Copy both lists into indexed columns. Tickets are stored lowercased for matching, and thread URLs as sent. The document keeps the uploaded spelling.
- Add `ticket` and `thread_url` filters to `GET /api/v1/projects/:project/workflow-runs`, for every key type. `ticket` matches ignoring ASCII case. `thread_url` is normalized before matching. List summaries gain no fields.
- `GET /api/v1/projects/:project/workflow-runs/:run_id` returns `links` inside `data.document` as stored. For a `pk_` key, `links.threads` is null and `links.tickets` is unchanged.
- Update the OpenAPI document.

`schema_version` stays 1. Documents without `links`, which includes every stored run and every upload from an older CLI, validate, store, list, and show exactly as before.

### Adjustments to the CLI contract

These keep the contract's intent and only fix details the CLI design left open or that conflict with how this server stores runs:

- **The server doesn't rewrite thread URLs. It rejects ones that aren't normalized.** The server never rewrites a submitted value. A private-key show returns the upload unchanged, and exact retries compare JSON values. Both of those would break if the server normalized URLs on the way in. A thread URL must therefore already be in normal form: lowercase scheme and host, no explicit port 443, a nonempty path, and no `.` or `..` path segment. URLs that the CLI serializes with `reqwest::Url` (WHATWG) are always in this form, so the CLI is unaffected. The stored value is still "in normalized form", as the contract says.
- **For a `pk_` key, `links.threads` is null only when the run has threads.** A run whose `links` has only `tickets` shows no `threads` key to any key type. This matches how graph condition text is redacted, and it stops `history show` from printing a `thread -` row for a run that has no threads.
- **The show response nests `links` under `data.document`.** "Returns `links` as stored" means `data.document.links`, because show returns the whole document there.
- **Thread URLs are parsed as RFC 3986 (`URI.new/1`).** This is the same approach as `ci.url`. Amp thread URLs parse the same way under both standards. A WHATWG URL whose path holds a character that RFC 3986 forbids, such as `|` or `^`, would be `422` here. goodflows `add-run-links` now rejects those characters too, so both sides agree.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `workflow-run-storage`: accepts `links`, filters the list by ticket and thread URL, and hides thread URLs from public keys.

## Impact

- `GoodFlows.WorkflowRuns.Validator`: a `links` table, thread URL and ticket rules, and a cross-field pass for an empty `links` and duplicates. It also returns two new column values.
- One migration: `link_tickets` and `link_threads` (`text[] NOT NULL DEFAULT '{}'`) on `workflow_runs`, each with a GIN index. The constant default is a catalog-only change and doesn't rewrite the table. Existing rows get empty lists and need no backfill.
- `WorkflowRuns.list_runs/3` and `ingest/4`, `WorkflowRunJSON` (redaction), `WorkflowRunController` list parameters, the OpenAPI schemas, and the API description.
- The vendored goodflows fixtures stay pinned to their current commit until the CLI change lands. A `links` fixture is vendored then.
- Rollout: deploy this before the CLI change is released. Records the CLI spooled after a `422` replay once the server accepts them.
- Not included: adding links to list summaries, links on test reports, and backfilling threads for squash-merged `main` runs.
