---
name: verify-goodflows
description: Launches an isolated GoodFlows Web (Phoenix app in app/) instance on a fresh seeded database, drives its dashboard in agent-browser and its JSON API with curl, and captures proof under .verify/goodflows/. Use to prove a change to sign-in, registration, the account dashboard, API keys, the projects page, or the /api/v1 endpoints works end to end in the running app, not just in mix test.
---

# Verify GoodFlows Web

GoodFlows Web is the Phoenix app in `app/`. Users reach it through two surfaces:

- **Browser dashboard** (primary): sign in, registration, account dashboard and switcher, project management, API key management, user settings. LiveView pages driven with `agent-browser`.
- **JSON API** at `/api/v1`: projects, recipes, runs, workflow-run history, and caches, authenticated with a dashboard-created key (`Authorization: Bearer sk_…` or `pk_…`). Driven with `curl`. Swagger UI is at `/api/v1/docs`.

The goodflows CLI's upload path has its own end-to-end script, `scripts/e2e-cli-smoke.sh` (see `.agents/README.md`). Use it for CLI proofs; this skill covers the app.

Everything goes through one helper, [`scripts/control-goodflows`](scripts/control-goodflows). Call it by path from the repository root:

```bash
C=.agents/skills/verify-goodflows/scripts/control-goodflows
```

Read the feature map in [`features/README.md`](features/README.md) before driving anything. Each feature file there is the recipe for that feature.

## Launch

Preconditions: the orb setup in `.agents/setup` has run, so `mix` (Elixir 1.19.4) and PostgreSQL on `localhost:5432` exist, and `agent-browser` is installed. Launch runs `.agents/resume` when PostgreSQL is down.

```bash
eval "$($C launch)"                                  # exports RUN_ID, GF_URL, GF_RUN_DIR
eval "$($C launch --scenarios <qa-scenarios.md>)"    # also grade a scenario set
```

A run uploads to a goodflows change request only when it graded a scenario set, such as the diff set `gs-qa-scenarios` writes to `.goodflows/change-requests/<branch>/qa-scenarios.md` or an OpenSpec change's `qa-scenarios.md`. Pass it with `--scenarios`, or set `VERIFY_SCENARIOS`. Launch from a clean, committed tree: goodflows stores a run built from a dirty tree but never counts it.

Launch does this:

1. It picks the first free port in 4400–4499, or uses `VERIFY_PORT`. A taken `VERIFY_PORT` makes it refuse to start.
2. It creates `.verify/goodflows/$RUN_ID/` and `run.md`, and adds `/.verify/` to `.gitignore` when it is missing. With a scenario set, it copies the set byte for byte to `scenarios.md` in the run folder; never edit that copy.
3. It runs `mix ecto.setup` with `BRANCH_DB=verify_<timestamp>`, which creates, migrates, and seeds a new `good_flows_verify_<timestamp>_dev` database. The default `good_flows_dev` database and the portal service on Amp's port are never touched.
4. It starts `mix phx.server` under `setsid`, logging to `$GF_RUN_DIR/server.log`.

It is ready when `server.log` contains `Running GoodFlowsWeb.Endpoint` **and** `GET /users/log-in` returns 200. A cold compile can take a few minutes; launch waits up to 180 s. The seeded login is `user@example.com` / `password1234password1234`, an owner of `Acme Corp` and a member of `Globex Industries`.

Each launch has its own port, database, and browser session (`verify-goodflows-$RUN_ID`), so concurrent runs do not collide. They share `app/_build`, so do not run launches while another agent is recompiling the same checkout.

## Doctor

Run it first, and again whenever anything looks off:

```bash
$C doctor
```

It is read-only and prints `ok` or `FAIL` for each check: the server pid is alive, the port is held by a process in this run's server session, `/users/log-in` returns 200, the run database has the seeded user in both accounts, and `HEAD` still matches the commit launch recorded. Any `FAIL` means this instance is not worth driving. Clean up and launch again; do not fix it in place.

## Drive

Browser commands pass straight to `agent-browser` in this run's session:

```bash
$C login                                   # password login; prints http://127.0.0.1:<port>/
$C browser open "$GF_URL/dashboard"        # redirects to /dashboard/accounts/<account-id>
$C browser wait --url '**/dashboard/accounts/*'
$C browser snapshot -i                     # refs and accessible names
$C browser click '#sidebar a[href$="/api-keys"]'
$C browser click '#empty-new-key-btn'
$C browser screenshot "$GF_RUN_DIR/<feature>/<step>.png"
```

`login` sets a 1280×800 viewport at 2x after the first `open`, since the session must exist before `set viewport` works. It fills `#login_form_password` and chooses `Log in only this time`, then waits until it leaves `/users/log-in` and the page has a `/users/log-out` link. It prints the landing URL: the page that sent the user to log in, or `/`.

Use stable handles in this order: the element IDs the templates define (`#create-key-form`, `#token-display-modal`, `#revoke-confirm-modal-confirm`, `#api-keys`, `#login_form_password`), then ARIA role and name, then form field names (`input[name="api_key[name]"]`).

Two things on every dev page get in the way of clicks. Both were seen in proof runs:

- The Tidewave dev toolbar sits over the bottom of the sidebar, so clicks on the account switcher fail with `covered by <div#tidewave-toolbar>`. Use the keyboard instead: `$C browser focus '#account-switcher [role=button]'`, then `$C browser focus '#account-switcher a'` and `$C browser press Enter`.
- A flash (`#flash-info`, `#flash-error`) covers the top-right of the header for a few seconds, including the `Log out` link on `/`. Click the flash to dismiss it before the next click there.

Read flashes by ID (`#flash-info`, `#flash-error`), not `[role=alert]`: the hidden `#client-error` and `#server-error` notices also carry that role.

API calls use the key a feature created through the dashboard:

```bash
export GF_API_KEY="$($C browser get value '#token-value')"   # only while the token modal is open
$C api me GET /api/v1/me
$C api create-project POST /api/v1/projects '{"slug":"verify-proj"}'
```

`api <name>` saves `api/<name>.request`, `.status`, and `.json` under the run directory, then prints the HTTP status and body.

Database side effects are checked read-only with `db`. Its connection settings are already set, so plain `psql` is not needed:

```bash
$C db "select name, type, status from api_keys" api-keys/db-row.txt
```

## Evidence

Every run writes to `.verify/goodflows/$RUN_ID/`, where `RUN_ID` is `<UTC yyyymmddThhmmssZ>-<short sha>`. `.verify/` is gitignored, so evidence is never committed. `run.md` holds the full commit SHA, the branch, whether the working tree was clean or dirty (with the changed files), the start time, the URL, and the database. Record each feature or sub-feature you drive, each scenario of the set, any feature map drift you found, then the outcome:

```bash
$C record keys-create "API keys page → Create key (empty state)" pass api-keys/03-token-shown.png api/me-active.json
$C result 1 passed api-keys/03-token-shown.png                 # scenario 1 of the set
$C result 2 failed --step 3 --reason "No token modal" api-keys/04-no-modal.png
$C result 3 not_run --reason "Needs a second account owner"
$C drift "api-keys.md: #empty-new-key-btn is now #create-first-key"
$C finish pass "one-line summary"      # or fail / partial
```

`record` takes a feature ID (a file name in `features/`) or a sub-feature ID from a file's `Sub-features` list, and refuses any other ID. `result` takes a scenario ID of the set; evidence paths are relative to the run folder and must exist. Recording a scenario again replaces its earlier result. A feature recorded more than once is failed when any of its drives failed.

`finish` writes the `verify-run-notes/1` YAML front matter at the top of `run.md`, which `goodflows cr runs upload` reads: the set's path and SHA-256, the commit, branch, dirty flag and changed files, the start and finish times, one result per scenario of the set (a scenario with no `result` is `not_run`), one entry per driven feature, and the drift. Running `finish` again rewrites the front matter and the outcome. Check the folder before uploading it:

```bash
goodflows cr validate "$GF_RUN_DIR"
goodflows cr runs upload "$GF_RUN_DIR"
```

Keep screenshots, ARIA snapshots (`$C browser snapshot -s '<selector>' > file.aria.txt`), API responses, and `db` output in per-feature folders. `server.log` and `ecto-setup.log` are already there.

Proof standards:

- Drive the real user path: dashboard clicks and API calls with a key made in the UI. Do not call context functions with `mix run`, insert rows, or mint keys directly. The smoke script's `mix run` key is setup for a CLI proof, not proof of the API keys feature.
- Capture the action and the resulting state: the form before submit, the modal or flash after, and a second view (a reloaded table, an API call, or a `db` row).
- Check side effects next to what is visible: a key that shows `Revoked` must also return 401 from the API.
- The dev server sends mail to the in-memory Swoosh mailbox at `$GF_URL/dev/mailbox`. That is the production mail boundary, so magic-link and registration mail is read there, never faked. Mailed links say `localhost`; open them with `127.0.0.1` so they use the browser session's cookies.
- Never paste full `sk_` tokens into `run.md` or the reply. The run database is dropped at cleanup, so any captured token is dead afterwards.

## Cleanup

```bash
$C cleanup
```

It closes this run's browser session, sends TERM and then KILL to the server's process group (the one launch started under `setsid`, never anything matched by name), and drops the run database. It then appends a `Cleaned up` line to `run.md`. It never removes `.verify/`. Run it after failed attempts too. If the shell lost `RUN_ID`, pick it from `ls .verify/goodflows/` and `export RUN_ID=<id>` before cleaning up.

## Helpers

- `scripts/control-goodflows` runs as shown above. With no arguments it prints its usage.
- `scripts/e2e-cli-smoke.sh` at the repository root is the separate CLI upload smoke. It starts its own server on port 4123.
