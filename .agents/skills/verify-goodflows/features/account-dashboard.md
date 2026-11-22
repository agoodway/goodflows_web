# Account dashboard

A signed-in user opens the dashboard for one of their accounts, moves between its pages from the sidebar, and switches to another account they belong to. The choice is remembered for their next `/dashboard` visit.

## Sub-features

- `dash-redirect` sends `/dashboard` to `/dashboard/accounts/<account-id>` for the last-used account, or the first account.
- `dash-home` shows the account name as the page heading (`#dashboard h1`), with a `Make your first API call` card (`#get-started`) and an `Account` card (`#account-details`).
- `dash-sidebar` links `Dashboard`, `Projects`, `API keys`, and `Settings`, and marks the current page with `aria-current="page"`.
- `dash-switch` opens the `Switch account` menu at the bottom of the sidebar, which lists the current account as plain text and the other account as a link with its role (`Globex Industries Member`), and loads the chosen account.
- `dash-remember` makes `/dashboard` reopen the last account chosen.
- `dash-forbidden` sends an account ID the user does not belong to back to `/dashboard` with `Unable to access this account.`

## How to get to it (user POV)

- Choose `Go to dashboard` (`#home-dashboard-link`) or `Dashboard` in the header of `/` after signing in, or open `/dashboard`.
- Use the dashboard sidebar to reach `Dashboard`, `Projects`, `API keys`, and `Settings`.
- Choose the `Switch account` button (it shows the account name and role) at the bottom of the dashboard sidebar.

## Driving it with control-goodflows

Preconditions:

- Baseline state, and `$C login` succeeded.
- The seeded user belongs to two accounts, so the switcher renders as a dropdown.

- **Redirect.** Run `$C browser open "$GF_URL/"`, `$C browser click '#home-dashboard-link'`, and `$C browser wait --url '**/dashboard/accounts/*'`. The `h1` in `#dashboard` reads `Acme Corp` or `Globex Industries`, and `#get-started` reads `Make your first API call`. Record the account ID from `$C browser get url`.
- **Sidebar.** Run `$C browser snapshot -s 'nav[aria-label=Main]'`: it lists `Dashboard`, `Projects`, `API keys`, and `Settings`. Run `$C browser click '#sidebar a[href$="/api-keys"]'`. The URL ends in `/api-keys`, `$C browser get text 'nav[aria-label=Breadcrumb]'` reads `Dashboard / API keys`, and the sidebar link has `aria-current` `page`. Return with `$C browser find role link click --name "Dashboard"` (the first match is the sidebar link).
- **Switch.** Run `$C browser focus '#account-switcher [role=button]'` to open the menu, and `$C browser snapshot -s '#account-switcher'` for its proof. Then choose the other account with `$C browser focus '#account-switcher a'` and `$C browser press Enter`. The URL's account ID changes and the `h1` names the chosen account.
- **Remembered.** Run `$C browser open "$GF_URL/dashboard"`. It lands on the account just chosen.
- **Forbidden.** Open `$GF_URL/dashboard/accounts/00000000-0000-0000-0000-000000000000`. The server answers 302 to `/dashboard`, which lands on the remembered account, and `$C browser get text '#flash-error'` reads `Unable to access this account.`
- **Proof.** Keep screenshots of both accounts' dashboards with the switcher visible, and an ARIA snapshot of the open `Switch account` menu.

## Gotchas

- The Tidewave dev toolbar covers the switcher at the bottom of the sidebar, so `find role button click --name "Switch account"` fails with `covered by <div#tidewave-toolbar>`. Drive it with `focus` and `press Enter` as above. The menu opens on focus and lists only the other account as a link.
- The switcher's account links do full page loads on purpose, so the server records the last-used account. After choosing one, wait for the heading, such as `$C browser wait --fn "document.querySelector('#dashboard h1')?.textContent.includes('Globex')"`, before the next click. Clicks sent during the reload are lost.
- The last-used account survives sign-out and sign-in in the same browser session, so `/dashboard` may open Globex Industries first. Read the `h1` instead of assuming Acme Corp.
- With only one account the switcher is a static label with no dropdown. The seed data always gives two; a single account means the database was not seeded by launch.
- `Dashboard` appears in both the breadcrumb and the sidebar, and on the dashboard page `API keys` names the sidebar link, the header button, and `Go to API keys`. Scope to `#sidebar` or use the snapshot ref.
- Settings (`/users/settings`) has no sidebar, so it never shows as the highlighted sidebar item.
- At widths under `lg` the sidebar is hidden behind the menu button. Keep the 1280-pixel viewport from `$C login`.
