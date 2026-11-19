# GoodFlows Web verification map

This directory is the maintained source for verifying what a GoodFlows Web user can see and do. Read this index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- A run started with `$S/launch.sh` (`S=.agents/skills/verify-goodflows-web/scripts`), with `$S/doctor.sh <run-id>` reporting no FAIL.
- The run's own database, seeded with `user@example.com` / `password1234password1234`, who owns `Acme Corp` and is a member of `Globex Industries`.
- App settings come from `GOOD_FLOWS_*` variables exported before launch. Defaults are dev defaults. Registration is open, for example.
- Never drive a server this run did not start.

## Driving conventions

- Start every recipe from a fresh browser context, which every `openRun` call gives you. A context is logged out until `logIn`.
- Call `liveReady(page)` after every navigation to a LiveView page and before filling or clicking.
- Prefer template ids, then ARIA role and name, then form-scoped labels. Never use coordinates or DOM position.
- Treat quoted labels and messages as literal. They are copied from `app/lib/good_flows_web/`.
- Data a recipe creates (users, keys) stays in the run's database, which cleanup drops. Use unique names (`verify-<Date.now()>`) so reruns on one instance don't collide.

## Proof and skip reporting

- Capture the user action and the resulting state with `shot()`, not only the final screen.
- UI proof is the screenshot, ARIA snapshot, and URL that `shot()` writes.
- Mutation proof needs a second view: `psql(run.branchDb, …)`, `mailbox(run.baseUrl)`, or an API call with the user's token.
- Record the feature ID and entry point with each result in `run.md`.
- Report an unreachable path with the attempted step and the unmet precondition. Never report a skipped entry point as verified through another one.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then has exactly four H2 sections in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with Playwright`, and `Gotchas`. Keep implementation details out, except the handles a drive needs.

## Features

- [Log in and out](./login.md) covers the password form, magic link email, logout, and returning to the page that required login. Script: `journeys/login.mjs`.
- [Registration](./registration.md) covers signing up with an email, and the closed state set by `GOOD_FLOWS_USER_REGISTRATION_ENABLED=false`. Script: `journeys/registration.mjs`.
- [API keys](./api-keys.md) covers creating, using, and revoking an account API key from the dashboard. Script: `journeys/api-keys.mjs`.
- [Dashboard and account switching](./dashboard-accounts.md) covers the account dashboard, the sidebar, and switching between accounts. No script yet.
- [User settings](./user-settings.md) covers changing email and password, which requires a recent login. No script yet.
