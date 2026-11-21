# Account dashboard

A signed-in user opens the dashboard for one of their accounts, moves between its pages from the sidebar, and switches to another account they belong to. The choice is remembered for their next `/dashboard` visit.

## Sub-features

- `dash-redirect` sends `/dashboard` to `/dashboard/accounts/<account-id>` for the last-used account, or the first account.
- `dash-home` shows the account name as the page heading and a `Getting Started` card.
- `dash-sidebar` links `Dashboard`, `API Keys`, and `Settings`, and highlights the active one.
- `dash-switch` lists `Acme Corp` and `Globex Industries` under `Your Accounts` and loads the chosen account.
- `dash-remember` makes `/dashboard` reopen the last account chosen.
- `dash-forbidden` sends an account ID the user does not belong to back to `/dashboard` with `Unable to access this account.`

## How to get to it (user POV)

- Choose `Dashboard` in the header of `/` after signing in, or open `/dashboard`.
- Use the dashboard sidebar to reach `Dashboard`, `API Keys`, and `Settings`.
- Choose the account button (`Acme Corp`, `Switch account`) in the dashboard header.

## Driving it with control-goodflows

Preconditions:

- Baseline state, and `$C login` succeeded.
- The seeded user belongs to two accounts, so the switcher renders as a dropdown.

- **Redirect.** Run `$C browser open "$GF_URL/dashboard"` and `$C browser wait --url '**/dashboard/accounts/*'`. The `h1` in `#dashboard` reads `Acme Corp` or `Globex Industries`. Record the account ID from `$C browser get url`.
- **Sidebar.** Run `$C browser find role link click --name "API Keys"`. The URL ends in `/api-keys` and the breadcrumb reads `Dashboard / API Keys`. Return with `$C browser find role link click --name "Dashboard"` (the first match is the sidebar link).
- **Switch.** Run `$C browser find role button click --name "Switch account"`, then choose the other account with `$C browser find role link click --name "Globex Industries"` (or `Acme Corp`). The URL's account ID changes and the `h1` names the chosen account.
- **Remembered.** Run `$C browser open "$GF_URL/dashboard"`. It lands on the account just chosen.
- **Forbidden.** Open `$GF_URL/dashboard/accounts/00000000-0000-0000-0000-000000000000`. The server answers 302 to `/dashboard`, which lands on the remembered account with the alert `Unable to access this account.` (`$C browser get text '[role=alert]'`).
- **Proof.** Keep screenshots of both accounts' dashboards with the switcher visible, and an ARIA snapshot of the open `Your Accounts` menu.

## Gotchas

- The switcher's account links do full page loads on purpose, so the server records the last-used account. After choosing one, wait for the heading, such as `$C browser wait --fn "document.querySelector('#dashboard h1')?.textContent.includes('Globex')"`, before the next click. Clicks sent during the reload are lost.
- The last-used account survives sign-out and sign-in in the same browser session, so `/dashboard` may open Globex Industries first. Read the `h1` instead of assuming Acme Corp.
- With only one account the switcher is a static label with no dropdown. The seed data always gives two; a single account means the database was not seeded by launch.
- `Dashboard` appears in both the breadcrumb and the sidebar. Scope to the sidebar or use the snapshot ref.
- At widths under `lg` the sidebar is hidden behind the menu button. Keep the 1280-pixel viewport from `$C login`.
