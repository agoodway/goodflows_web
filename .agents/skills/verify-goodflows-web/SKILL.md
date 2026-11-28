---
name: verify-goodflows-web
description: Drive the real GoodFlows Web Phoenix app (LiveView browser UI plus its JSON API) in an isolated dev server with headless Chromium via Playwright, and capture evidence under .verify/goodflows-web/. Use to prove a change works the way a user sees it, run QA scenarios, or reproduce a UI bug, for log in, registration, dashboard, API keys, and user settings.
---

# Verify GoodFlows Web

GoodFlows Web is the Phoenix 1.8 app in `app/`. Users touch a LiveView browser UI (log in, registration, account dashboard, API keys, settings). The goodflows CLI touches the JSON API under `/api/v1` with `Authorization: Bearer <key>`. This skill drives the browser UI with Playwright and calls the API with `fetch`/`curl`, against a dev server it starts itself.

Every path below is relative to the repository root. `S=.agents/skills/verify-goodflows-web/scripts`.

## Isolation

Each run gets its own server and its own database, so it never touches the user's dev server or data:

- Port: a free port the OS picks, recorded in `.verify/goodflows-web/<run-id>/.instance/port`.
- Database: `BRANCH_DB=verify_<10 hex>`, which `app/config/runtime.exs` turns into `good_flows_verify_<hex>_dev`. Launch creates, migrates, and seeds it from empty.
- Mail: the dev Swoosh local adapter keeps sent mail in that server's memory. `GET /dev/mailbox/json` returns it, newest first.

Shared with other dev servers in this checkout: `_build/dev` and `priv/static/assets` (esbuild and tailwind watchers rebuild them). Two runs at once work. A run alongside the user's `just up` works too, but a code edit triggers recompiles in both.

Never drive a server this skill did not start. Its run directory must hold `.instance/pid`.

## Launch

```bash
$S/launch.sh [run-id]
```

The run id defaults to `<UTC timestamp>-<short sha>`, such as `20261119T231800Z-eaf5a9b`. Launch runs `mix ecto.setup` (create, migrate, seeds), builds assets if `app/priv/static/assets/` is missing, starts `mix phx.server` in its own process group, and waits until `/users/log-in` renders `#login_form_password`. Ready takes about 3 seconds with a warm `_build/dev`, and a cold compile takes minutes. On success it prints:

```text
RUN_ID=20261119T231800Z-eaf5a9b
RUN_DIR=/…/.verify/goodflows-web/20261119T231800Z-eaf5a9b
BASE_URL=http://localhost:43513
```

Set app configuration by exporting `GOOD_FLOWS_*` variables before launch. They reach the server and are recorded in `.instance/build`. Example: `GOOD_FLOWS_USER_REGISTRATION_ENABLED=false $S/launch.sh`. Any other variable must be set the same way. A setting read at boot needs a new run to change.

Seeded state (`app/priv/repo/seeds.exs`): user `user@example.com` with password `password1234password1234`, confirmed, owner of `Acme Corp` and member of `Globex Industries`.

Prerequisites: PostgreSQL on `localhost:5432` with user `postgres`/`postgres` (`pg_isready -h localhost`), Elixir deps fetched (`cd app && mix deps.get`), `node`, Playwright (`mise use -g playwright`, found with `mise where playwright`), and a Chromium. The helpers use `/usr/bin/chromium` when it exists, because Playwright's own browser download may be missing. Override with `VERIFY_CHROMIUM=/path/to/chrome`.

## Doctor

```bash
$S/doctor.sh <run-id>
```

Read-only. Exits 1 on any FAIL. It checks that the server process group is alive, that the run's port is held by that group (not someone else's server), that `/users/log-in` renders the login form, and that the run's database holds the seeded user. It WARNs when HEAD moved or the working tree is dirty since launch. The dev code reloader recompiles from disk on each request, so the server always serves the checkout's current files, not only the launch commit. It also prints the `GOOD_FLOWS_*` settings the server got. Run it first, and again whenever a drive behaves strangely.

## Drive

Journeys are Node ES modules that import `$S/lib.mjs`. Ready-made journeys:

```bash
node $S/journeys/login.mjs <run-id>          # features/login.md
node $S/journeys/registration.mjs <run-id>   # features/registration.md (checks the launched open/closed state)
node $S/journeys/api-keys.mjs <run-id>       # features/api-keys.md
```

Each prints `PASS`/`FAIL` per check and exits 1 on any failure. For anything else, write a short script next to them (or in the scratchpad, importing by absolute path):

```js
import { openRun, liveReady, logIn, mailbox, psql, flashText } from "/abs/path/.agents/skills/verify-goodflows-web/scripts/lib.mjs";
const run = await openRun(process.argv[2], "my-journey");   // evidence -> <run-dir>/my-journey/
const { page, check, shot } = run;                          // page has baseURL set; page.goto("/users/log-in")
try {
  await logIn(page);                                        // seeded user, ends on the account dashboard
  await page.getByRole("link", { name: "API Keys" }).first().click();
  await liveReady(page);                                    // wait for the LiveView socket before interacting
  check("something visible", await page.getByText("API keys").isVisible());
  await shot("api-keys");                                   // NN-api-keys.png + .aria.txt + .url.txt
} catch (e) { check("journey ran to completion", false, e.message); await shot("error").catch(() => {}); }
finally { await run.finish(); }                             // closes the browser, sets the exit code
```

`lib.mjs` exports:

- `openRun(runId, journey)` returns `{ page, context, baseUrl, runDir, outDir, branchDb, build, shot, check, log, finish }`.
- `logIn(page, { email, password, toDashboard = true })` logs in through the password form, as a user would.
- `liveReady(page)` waits for `[data-phx-main].phx-connected`.
- `flashText(page, "info" | "error")` reads `#flash-info` or `#flash-error`.
- `mailbox(baseUrl)` returns sent emails, newest first.
- `psql(branchDb, sql)` runs read-only SQL against the run's database.
- `SEED_EMAIL`, `SEED_PASSWORD`.

Handles to prefer, in order: element ids the templates set (`#login_form_password`, `#registration_form`, `#create-key-form`, `#token-value`, `#flash-error`), then ARIA role and accessible name (`getByRole("button", { name: "Create key" })`), then labels (`getByLabel("Email")` scoped to its form, because the login page has two Email fields). Take labels and messages from `app/lib/good_flows_web/**` as written. The feature files list the ones in use.

API calls: `curl -H "Authorization: Bearer $TOKEN" $BASE_URL/api/v1/me`. Create the token through the API Keys page (`features/api-keys.md`), not with `mix run`, so the user path is what gets proved.

## Evidence

Evidence lives in `.verify/goodflows-web/<run-id>/`, which `/.verify/` in the root `.gitignore` keeps out of Git. Never stage or commit it.

```text
.verify/goodflows-web/<run-id>/
  run.md                 # you write this (shape below)
  setup.log, server.log  # launch output and the server's log for the whole run
  <journey>/steps.log    # every check, evidence path, console error, page error
  <journey>/NN-<name>.png / .aria.txt / .url.txt
```

Proof standards:

- Drive the real user path: the forms, buttons, and links a person uses. Do not call LiveView events, context functions, or `mix run` to stand in for a user action. Use `mix run` or `psql` only to read state or to set up a precondition no screen offers.
- Capture the action and the result: a shot before the submit when the input matters, and a shot of the resulting page.
- Prove side effects from a second view. A users row in `psql`, an email in `/dev/mailbox/json`, a key that authenticates against `/api/v1/me`. A flash alone is not proof.
- Treat console errors and page errors in `steps.log` as failures to report, even when every check passed.
- Mail is the dev local adapter, which is the production boundary. Nothing leaves the machine.

`run.md` shape:

```markdown
# Verify run <run-id>

- Commit: <full sha> (<branch>), tree <clean|dirty>, from .instance/build (copy it before cleanup)
- Started: <UTC time>   Settings: <GOOD_FLOWS_* values or "defaults">
- Source: <who asked: a change, a QA scenarios file, a pull request>
- Outcome: <N passed, N failed, N not run>

| Feature / scenario | Entry point | Result | Evidence |
|---|---|---|---|
| login-password | /users/log-in password form | Passed | login/03-home-after-password-login.png |
```

Write `run.md` before cleanup, because cleanup deletes `.instance/build`.

## Cleanup

```bash
$S/cleanup.sh <run-id>
```

It sends TERM (then KILL after 15 seconds) to the run's process group only, which stops the server and its esbuild and tailwind watchers, and drops the run's `good_flows_verify_*_dev` database. It refuses any other name. Then it removes `.instance/`. Everything else in the run directory stays. Run it after every run, failed ones included. To find runs that were never cleaned up: `ls -d .verify/goodflows-web/*/.instance`. Never `pkill beam`, `pkill mix`, or kill by port, because the user's own dev server is a beam process too.

## Feature map

`features/README.md` indexes the user-facing features and how to drive each one. Read it before a drive, and keep it current with `/maintain-verification-skill` when a route, label, or flow changes.
