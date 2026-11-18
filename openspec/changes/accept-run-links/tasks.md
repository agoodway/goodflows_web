# Tasks

## 1. Prerequisites

- [ ] 1.1 Archive `accept-upload-envelope`, which is already implemented, before archiving this change. This change's MODIFIED requirements start from its text (design "Risks / Trade-offs").

## 2. Validator

- [ ] 2.1 Add `links` as `{:omit, links_spec}` to `GoodFlows.WorkflowRuns.Validator.document_spec/0` (design D1). It has `threads`, a list of 1 to 32 thread URLs, and `tickets`, a list of 1 to 32 strings of 1 to 64 bytes matching `\A[!-~]+\z`. Both are omit-only. Update the moduledoc's key list and caps.
- [ ] 2.2 Add `thread_url_errors/2` (`{:fun, _, :thread_url}`) with the length, `https`, host, userinfo, query, fragment and normal-form rules from design D2. The normal-form error is `must be normalized`. Expose `valid_ticket?/1` and `valid_thread_url?/1` for the list filters.
- [ ] 2.3 Add the links cross-field pass to `cross_field_errors/1`: `must not be empty` on an empty `links`, and `must be unique` on each repeated thread (exact) and ticket (ASCII case-insensitive). It runs only on lists that are within bounds and made of valid strings.
- [ ] 2.4 Return `link_tickets` (ASCII-lowercased) and `link_threads` (as sent) in `columns/1`, as empty lists when they are absent.
- [ ] 2.5 Validator tests: `links` with only threads, with only tickets, and with both; `{}`, null `links`, null lists, `[]`, and an unknown key; 32 and 33 entries in each list; a ticket of 64 and 65 bytes, empty, with a space, with a tab, and non-ASCII; a duplicate ticket differing only in case, at index 2; a duplicate thread; every thread URL case in the spec delta, plus `|` in the path, an empty `?` or `#`, an empty host, and 2,048 and 2,049 bytes; and no submitted value (including a query-string token) in any error.

## 3. Storage and reads

- [ ] 3.1 Add the migration with `link_tickets` and `link_threads` (`text[] NOT NULL DEFAULT '{}'`) and their GIN indexes, `workflow_runs_link_tickets_index` and `workflow_runs_link_threads_index` (design D3). Add both fields to `Run` and copy them in `ingest/4`'s row. Check `mix ecto.migrate && mix ecto.rollback && mix ecto.migrate`, and check that a row inserted before the migration reads back with empty arrays.
- [ ] 3.2 Update `list_runs/3`: validate `ticket` and `thread_url`, lowercase the ticket, normalize the thread URL as in design D3, and match with `@>`. Neither column is added to `@summary_fields`. Check with `EXPLAIN` that a ticket filter uses `workflow_runs_link_tickets_index`.
- [ ] 3.3 Update `WorkflowRunJSON` so a `pk_` show sets `links.threads` to null only when it is present (design D4). Update the moduledoc.
- [ ] 3.4 Context tests in `workflow_runs_reads_test.exs`: a ticket match ignoring case; a PR-shaped run and a `main`-shaped run returned by one ticket search, newest first; a thread match through an uppercase host and an explicit `:443`; link filters combined with `branch`; and a run without links never matching. In `workflow_runs_test.exs`, cover an exact retry with reordered `links` keys (`200`), a retry with a different ticket spelling (`409`), and a document without `links` storing as before.

## 4. API and documentation

- [ ] 4.1 Update OpenAPI: add a `:thread_url` clause to `WorkflowRunParts.to_schema/1`, make `links.threads` nullable in the show `document` schema, add `ticket` and `thread_url` to `WorkflowRunController`'s `@list_parameters`, and add links, the link filters and `pk_` thread redaction to the workflow-run section of `ApiSpec`'s description.
- [ ] 4.2 Controller tests: upload with `links` (`201`) and each `422` path from the spec delta; list by `ticket` and `thread_url` with `sk_` and `pk_` keys, with no links field in the summaries; invalid link filters returning `422` without echoing the value; and in `workflow_run_redaction_test.exs`, a `pk_` show with threads and tickets, a `pk_` show with tickets only (no `threads` key added), and an `sk_` show afterwards returning `links` as stored.
- [ ] 4.3 Contract test: add `links` to the vendored `full.json` in memory. Check that it uploads with `201`, retries with `200`, round-trips on `sk_` show, and is found by `ticket` and by `thread_url`. When goodflows `add-run-links` is implemented and committed, vendor its `tests/fixtures/workflow-runs/links.json` and update the fixtures README's commit and digests (design D6).
- [ ] 4.4 `openspec validate accept-run-links --strict` and `mix precommit` pass.

## 5. Rollout

- [ ] 5.1 Deploy, then confirm in production that a document with `links` gets a `201` and that one without `links` behaves as before. Tell goodflows that `add-run-links` can ship.
