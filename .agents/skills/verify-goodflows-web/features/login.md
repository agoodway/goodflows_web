# Log in and out

A registered user logs in with email and password or with a magic link sent by email, lands on the home page with their email in the header, and logs out again. A logged-out visit to a page that requires login sends the user to the login page, and logging in returns them to that page.

## Sub-features

- `login-password` logs in with email and password and lands on `/`.
- `login-password-wrong` rejects a wrong password with an error and keeps the email filled in.
- `login-magic-link` emails a one-time link that logs the user in.
- `login-return-to` returns the user to the page that required login.
- `login-logout` ends the session.

## How to get to it (user POV)

- Header **Log in** button on any public page, or the home page's **Log in** button (`#home-login-link`).
- `/users/log-in` directly, or by being redirected there from `/users/settings` or `/dashboard` while logged out.
- The link in the "Log in instructions" email.
- Header **Log out** link while logged in, on public pages. On dashboard pages it is in the user menu.

## Driving it with Playwright

Preconditions:

- A launched run whose doctor passes. Seeded user `user@example.com` exists and is confirmed.

- **Run the script.** `node $S/journeys/login.mjs <run-id>` drives every bullet below and exits 0 when all checks pass.
- **Wrong password.** On `/users/log-in`, fill `#login_form_password` **Email** with `user@example.com` and **Password** with any wrong value, then click **Log in only this time**. The page reloads at `/users/log-in` and `#flash-error` reads "Invalid email or password".
- **Password login.** Fill the same form with the seeded password and click **Log in only this time**, or **Log in and stay logged in** to also set the remember-me cookie. The URL becomes `/`, `#flash-info` reads "Welcome back!", and the header lists `user@example.com` with **Dashboard**, **Settings** and **Log out** links.
- **Reach the dashboard.** Click `#home-dashboard-link`. `/dashboard` redirects to `/dashboard/accounts/<id>`, and `#dashboard h1` names the account (`Acme Corp` for a fresh session).
- **Log out.** On `/`, click the header **Log out** link. The URL is `/`, `#flash-info` reads "Logged out successfully.", and `/users/settings` now redirects to `/users/log-in`.
- **Magic link.** On `/users/log-in`, fill `#login_form_magic` **Email** and click **Log in with email**. `#flash-info` reads "If your email is in our system, you will receive instructions for logging in shortly." `mailbox(baseUrl)[0]` is addressed to the user, and its `text_body` holds `<BASE_URL>/users/log-in/<token>`. Open that link and click **Log me in only this time**.
- **Return to.** Right after the logged-out `/users/settings` visit above, the magic-link login lands on `/users/settings`, not `/`, and `#email_form` **Email** shows the user's address.
- **Proof.** `login/steps.log` lists every check. Screenshots `login/03-home-after-password-login.png`, `login/04-dashboard-after-password-login.png`, and `login/08-settings-after-magic-link.png` show each signed-in state.

## Gotchas

- Login lands on `/`, not the dashboard, unless a return path was stored. Waiting for `/dashboard/accounts/…` after submitting times out.
- Any logged-out visit to a protected page stores a return path that the next login uses, in that browser context. Use a fresh context when a recipe needs the plain `/` landing.
- The login page has two **Email** fields. Scope `getByLabel("Email")` to `#login_form_magic` or `#login_form_password`.
- The password form submits through `phx-trigger-action` (a real POST to `/users/log-in`). Wait for the URL, not for a LiveView patch.
- `/dev/mailbox/json` lists the newest email first. `.at(-1)` is the oldest, already-used link.
- Magic links work once. A reused token shows "Magic link is invalid or it has expired."
- The flash toast sits over the header's top-right links. Dismiss it (click it) or navigate before clicking **Log in** or **Log out** in the header.
- Logging in with a magic link does not set the remember-me cookie unless the user clicks **Keep me logged in on this device**.
