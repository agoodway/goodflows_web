# Dashboard and account switching

A logged-in user opens the dashboard for one of their accounts, sees the account's name and a sidebar with Dashboard, API Keys and Settings, and switches to another account they belong to from the header's account switcher. The app remembers the last account and opens it on the next `/dashboard` visit.

## Sub-features

- `dashboard-open` sends `/dashboard` to the last-used account, or the first one.
- `dashboard-sidebar` links to Dashboard, API Keys, and Settings for the current account.
- `dashboard-switch` switches accounts from the header dropdown and remembers the choice.
- `dashboard-forbidden` refuses an account the user does not belong to.

## How to get to it (user POV)

- **Dashboard** in the public header, or **Go to dashboard** (`#home-dashboard-link`) on the home page, while logged in.
- `/dashboard/accounts/<account-id>` directly.
- The account switcher button in the dashboard header, which shows the account name and "Switch account".

## Driving it with Playwright

Preconditions:

- A launched run whose doctor passes. The seeded user belongs to `Acme Corp` (owner) and `Globex Industries` (member), so the switcher shows a dropdown.
- No script yet. Write one with `openRun(runId, "dashboard-accounts")` and `logIn(page)`, following SKILL.md "Drive". These steps have not been run.

- **Open.** `logIn(page)` ends on `/dashboard/accounts/<id>`. `#dashboard h1` reads `Acme Corp` for a fresh session, and the page shows "Welcome to your dashboard."
- **Sidebar.** The sidebar links **Dashboard**, **API Keys**, and **Settings** go to `/dashboard/accounts/<id>`, `/dashboard/accounts/<id>/api-keys`, and `/users/settings`.
- **Switch.** Click the button inside `#account-switcher` (it contains the text "Switch account"). In the dropdown under "Your Accounts", click the link named `Globex Industries`. The page does a full load to `/dashboard/accounts/<globex-id>` and `#dashboard h1` reads `Globex Industries`.
- **Remembered.** Open `/dashboard`. It redirects to the Globex dashboard, not Acme.
- **Forbidden.** Open `/dashboard/accounts/<random uuid>`. The user does not reach a dashboard. Record the redirect target and flash you observe, and add them to this file.
- **Proof.** Screenshots of both dashboards with the switcher visible, and the URL `/dashboard` resolved to after switching.

## Gotchas

- Switcher links use `href` (a full page load), not LiveView navigation, so the server records the last account. Wait for the load event, not a patch.
- The dropdown opens on focus (DaisyUI `dropdown`). Click the button, then the link. Hovering is not enough.
- Look up account ids with `psql(run.branchDb, "select id, name from accounts")`, because they are random per run.
- A user with one account sees the name without a dropdown.
