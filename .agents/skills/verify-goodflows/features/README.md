# GoodFlows Web verification map

This directory is the maintained source for verifying the user-facing behavior of GoodFlows Web. Read this index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch with `eval "$(.agents/skills/verify-goodflows/scripts/control-goodflows launch)"` from the repository root. This exports `RUN_ID`, `GF_URL` (`http://127.0.0.1:44xx`), and `GF_RUN_DIR`.
- `C=.agents/skills/verify-goodflows/scripts/control-goodflows` is set in the shell.
- `$C doctor` prints only `ok` lines.
- The run database is freshly seeded: `user@example.com` / `password1234password1234` is the owner of `Acme Corp` and a member of `Globex Industries`. Neither account has API keys. Acme Corp has no projects; Globex Industries has one, `globex-api` (default branch `main`), so the member views have a row.
- Never drive an instance this run did not launch, including the `web` portal service.

## Driving conventions

- Start each recipe from the baseline unless it says otherwise. Browser recipes start with `$C login`.
- Prefer template element IDs, then ARIA role and name, then form field names. Avoid DOM position.
- Treat every command as literal.
- Run browser actions through `$C browser`, API calls through `$C api`, and database checks through `$C db`.
- A dashboard-created key is the only API credential. Export it as `GF_API_KEY` while the token modal is open.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof includes an ARIA snapshot of the changed region and a screenshot with the GoodFlows header visible.
- API proof includes the saved request, status, and body from `$C api`.
- Mutation proof includes a second view: a reload, an API read, or `$C db`.
- Record each driven sub-feature with `$C record <id> "<entry point>" <pass|fail> <artifacts...>`, each scenario of the run's set with `$C result`, then run `$C finish`. A sub-feature counts toward the feature file that lists it.
- Report an unreachable path with the attempted command and the unmet precondition. Do not report a skipped entry point as verified through another path.

## Feature entry contract

Each feature file starts with YAML front matter holding `paths`, the globs of the code and tests behind the feature, from the repository root. `goodflows features sync` uploads them as the project's feature index, and the server maps each changed file of a change request to the features whose globs match it. A change to a file that matches no feature is an unmapped area, and a matched feature with no passed run is undriven. When a feature gains or moves code, update its `paths`, then run `goodflows features validate` and `goodflows features sync`. The file name is the feature ID.

After the front matter comes an H1 title and one paragraph describing the user-visible behavior. It then has exactly four H2 sections in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with control-goodflows`, and `Gotchas`.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Sign in and sign out](./sign-in.md) covers password login, the magic-link email, wrong passwords, and sign-out.
- [Account dashboard](./account-dashboard.md) covers the `/dashboard` redirect, the sidebar, and switching between Acme Corp and Globex Industries.
- [API keys](./api-keys.md) covers creating public and private keys, the one-time token, revoking, and the API's response to each key.
- [Projects API](./projects-api.md) covers creating, listing, reading, updating, and deleting projects with a dashboard-created key, including the owner-or-admin rule for writes.
- [Projects page](./projects-page.md) covers listing, creating, editing, and deleting projects in the dashboard, and the read-only view for members.
- [Change requests API](./change-requests-api.md) covers opening a change request with the goodflows CLI, Git facts, a diff scenario set, claims, the review packet and answers, the merge lease, and the merge report.
- [Verify runs API](./verify-runs-api.md) covers uploading a run folder, how it counts in the verdict, repeat uploads, an unknown scenario set, and the 503 for evidence without object storage.
- [Registration](./registration.md) covers creating an account and confirming it from the dev mailbox.
