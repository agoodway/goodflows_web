# Proposal

## Why

Spry (`goodway/spry`) is a Rust CLI that turns a repo-local `.spry.yaml` recipe into a Sprite VM lifecycle (`init`, `setup`, `app start`, `app stop`, `teardown`). It only works from a laptop with a checkout, a logged-in `sprite` CLI, and a shell. We want the same lifecycle available as a hosted, OpenAPI-described JSON API in GoodFlows so CI jobs, agents, and (later) a web UI can drive Sprite VMs without a local install. This is the first step toward a web version of Spry.

## What Changes

- Add account-scoped **recipes** stored in Postgres and managed over `/api/v1/recipes` (create, list, show, update, delete). `spry init` becomes `POST /recipes`.
- Recipes are web-native JSON: a `name` template plus `setup`, `start`, `stop`, and `teardown` lists of in-VM shell lines. `{host: …}` steps are **not supported** and are rejected with `422`; the recipe has no `org` field.
- Add a per-account **Sprites credential**: an API token stored encrypted at rest, set and removed over the API, never returned. Every VM operation for the account uses this token through the `sprites` Elixir SDK (no `sprite` CLI).
- Add **runs**: `POST /api/v1/recipes/:id/runs` with a `phase` (`setup` | `start` | `stop` | `teardown`) replaces the four CLI commands. A run executes asynchronously in a PgFlow job and is polled with `GET /api/v1/runs/:id`, which reports status and per-step command, exit code, and captured output.
- `dry_run: true` on a run request returns the expanded plan synchronously without creating a run or mutating anything.
- `no_create` (setup) and `no_destroy` (teardown) and a `sprite` name override carry over from CLI flags as request fields. `--config`, `--verbose`, and `--org` are dropped.
- Placeholders (`{{branch}}`, `{{branch_slug}}`, `{{commit}}`, `{{remote}}`, `{{sprite}}`) expand from request inputs instead of local git; `{{org}}` is not supported.
- At most one queued or running run per resolved sprite name per account; a concurrent request gets `409 Conflict`.
- Each in-VM step has a server-side timeout, closing the CLI's "hung `sprite` blocks forever" gap.

Out of scope: host steps or any server-side shell execution, GitHub/deploy-key integration, live log streaming (SSE), a LiveView UI, multiple Sprites credentials per account, run cancellation, and reading recipes from a repository.

## Capabilities

### New Capabilities

- `spry-recipes`: account-scoped recipe storage, the JSON recipe schema and its validation (including rejection of host steps), and the recipe CRUD endpoints.
- `sprites-credential`: the per-account Sprites API token: setting, removing, reporting whether it is configured, and encryption at rest.
- `spry-runs`: starting a phase against a recipe, dry-run planning, async execution with fail-fast steps, per-phase VM semantics (create, require, destroy), the one-active-run guard, and run status/output retrieval.
- `spry-templates`: placeholder expansion in sprite names and step lines from run inputs, branch slug derivation, and errors for missing or unknown placeholders.

### Modified Capabilities

None. The project has no existing specs.

## Impact

- **API**: new `/api/v1` endpoints under `GoodFlowsWeb.Api.V1` with `open_api_spex` operations and schemas. Reads accept any API key; writes (recipes, credential, runs) require `sk_` keys, matching the existing `:api_write` pipeline.
- **Data**: new tables for recipes, the Sprites credential, runs, and run steps, all scoped to `accounts`.
- **Jobs**: first PgFlow job in the app, registered in the `config/runtime.exs` PgFlow `jobs:` list.
- **Dependencies**: adds an at-rest encryption library (e.g. `cloak_ecto`) and a new encryption key environment variable. Uses the existing `sprites` dependency for list/create/exec/destroy.
- **Operations**: the server makes outbound calls to the Sprites API with customer tokens, and runs can last as long as the slowest setup.
