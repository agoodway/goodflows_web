# Tasks

## 1. Prerequisites

- [x] 1.1 Archive `accept-upload-envelope`, which is already implemented, before archiving this change. This change's MODIFIED requirements start from its text (design "Risks / Trade-offs").

## 2. Validator

- [x] 2.1 Add `links` as `{:omit, links_spec}` to `GoodFlows.WorkflowRuns.Validator.document_spec/0` (design D1). It has `threads`, a list of 1 to 32 thread URLs, and `tickets`, a list of 1 to 32 strings of 1 to 64 bytes matching `\A[!-+\--~]+\z` (printable ASCII other than `,`). Both are omit-only. Update the moduledoc's key list and caps.
- [x] 2.2 Add `thread_url_errors/2` (`{:fun, _, :thread_url}`) with the length, `https`, host, port, userinfo, query, fragment, path-character and normal-form rules from design D2, including dot segments spelled with `%2e`, a percent-encoded host, canonical IPv4 and IPv6 hosts, and no percent normalization. The normal-form error is `must be normalized`. Expose `valid_ticket?/1` and `valid_thread_url?/1` for the list filters.
- [x] 2.3 Add the links cross-field pass to `cross_field_errors/1`: `must not be empty` on an empty `links`, and `must be unique` on each repeated thread (exact) and ticket (ASCII case-insensitive). It runs only on lists that are within bounds and made of valid strings.
- [x] 2.4 Return `link_tickets` (ASCII-lowercased) and `link_threads` (as sent) in `columns/1`, as empty lists when they are absent.
- [x] 2.5 Validator tests: `links` with only threads, with only tickets, and with both; `{}`, null `links`, null lists, `[]`, and an unknown key; 32 and 33 entries in each list; a ticket of 64 and 65 bytes, empty, with a space, with a tab, with a comma, and non-ASCII; a duplicate ticket differing only in case, at index 2; a duplicate thread; every thread URL case in the spec delta, plus `[`, `]`, `|`, `^`, `%zz`, `%z`, and a trailing `%` in the path, a bare `?` or `#`, `%7E`, `%7e` and `%2f` accepted as written, `%2e`, `.%2e` and `%2E%2e` segments, ports `:`, `:080`, `:0443` and 65,536, an empty host, a percent-encoded host, `127.1`, `0x7f.0.0.1` and `127.0.0.1.` (rejected) and `127.0.0.1` (accepted), `[0:0:0:0:0:0:0:1]` and `[::FFFF:1.2.3.4]` (rejected) and `[::1]` (accepted), and 2,048 and 2,049 bytes; and no submitted value (including a query-string token) in any error.

## 3. Storage and reads

- [x] 3.1 Add the migration with `link_tickets` and `link_threads` (`text[] NOT NULL DEFAULT '{}'`) and their GIN indexes, `workflow_runs_link_tickets_index` and `workflow_runs_link_threads_index` (design D3). Add both fields to `Run` and copy them in `ingest/4`'s row. Check `mix ecto.migrate && mix ecto.rollback && mix ecto.migrate`, and check that a row inserted before the migration reads back with empty arrays.
- [x] 3.2 Add `ticket` and `thread_url` to the `Map.take` allowlist in `WorkflowRunController.index/2`, which drops every other parameter before `list_runs/3`. Update `list_runs/3`: validate `ticket` and `thread_url`, lowercase the ticket, normalize the thread URL as in design D3, and match with `@>`. Neither column is added to `@summary_fields`. Check with `EXPLAIN` that a ticket filter uses `workflow_runs_link_tickets_index`.
- [x] 3.3 Update `WorkflowRunJSON` so a `pk_` show sets `links.threads` to null only when it is present (design D4). Update the moduledoc.
- [x] 3.4 Context tests in `workflow_runs_reads_test.exs`: a ticket match ignoring case; a PR-shaped run and a `main`-shaped run returned by one ticket search, newest first; a thread match through an uppercase host, an explicit `:443` and `:0443`; no match for a `%7e` or `~` spelling of a stored `%7E`; link filters combined with `branch`; and a run without links never matching. In `workflow_runs_test.exs`, cover an exact retry with reordered `links` keys (`200`), a retry with a different ticket spelling (`409`), and a document without `links` storing as before.

## 4. API and documentation

- [x] 4.1 Update OpenAPI: add a `:thread_url` clause to `WorkflowRunParts.to_schema/1`, make `links.threads` nullable in the show `document` schema, add `ticket` and `thread_url` to `WorkflowRunController`'s `@list_parameters`, and add links, the link filters and `pk_` thread redaction to the workflow-run section of `ApiSpec`'s description.
- [x] 4.2 Controller tests: upload with `links` (`201`) and each `422` path from the spec delta; list by `ticket` and `thread_url` with `sk_` and `pk_` keys, with no links field in the summaries; invalid link filters returning `422` without echoing the value; and in `workflow_run_redaction_test.exs`, a `pk_` show with threads and tickets, a `pk_` show with tickets only (no `threads` key added), and an `sk_` show afterwards returning `links` as stored.
- [x] 4.3 Contract test: add `links` to the vendored `full.json` in memory. Check that it uploads with `201`, retries with `200`, round-trips on `sk_` show, and is found by `ticket` and by `thread_url`. Leave the vendored fixtures and their README unchanged. Vendoring goodflows `links.json` is a follow-up change (design D6).
- [x] 4.4 `openspec validate accept-run-links --strict` and `mix precommit` pass.

## 5. Rollout

- [ ] 5.1 Make sure a rollback is possible without dropping the columns: a rollback build reverts validation, the filters and OpenAPI, and keeps the `links.threads` redaction for `pk_` keys (design D5). Deploy, then confirm in production that a document with `links` gets a `201` and that one without `links` behaves as before. Tell goodflows that `add-run-links` can ship.
  - **Status: PENDING.** The code side is done. The `pk_` `links.threads` redaction in `WorkflowRunJSON` is self-contained, so a rollback build can revert validation, the filters and OpenAPI and keep it. The migration only adds columns and indexes. What remains happens after the PR merges: deploy, confirm in production that a document with `links` gets `201` and one without behaves as before, then tell goodflows that `add-run-links` can ship.
