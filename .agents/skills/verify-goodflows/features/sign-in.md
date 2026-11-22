---
paths:
  - "app/lib/good_flows_web/live/user_live/login.ex"
  - "app/lib/good_flows_web/live/user_live/confirmation.ex"
  - "app/lib/good_flows_web/controllers/user_session_controller.ex"
  - "app/lib/good_flows_web/user_auth.ex"
  - "app/lib/good_flows/accounts/user_token.ex"
  - "app/test/good_flows_web/live/user_live/login_test.exs"
  - "app/test/good_flows_web/live/user_live/confirmation_test.exs"
  - "app/test/good_flows_web/controllers/user_session_controller_test.exs"
  - "app/test/good_flows_web/user_auth_test.exs"
---

# Sign in and sign out

A registered user signs in with email and password, or with a one-time link mailed to them. They see a signed-in header, and can sign out again.

## Sub-features

- `signin-password` signs in with `Log in only this time`. The user returns to the page that sent them to log in, or to `/`, where the header shows `Dashboard`, `Settings`, and `Log out`.
- `signin-remember` signs in with `Log in and stay logged in`, which sets the `_good_flows_web_user_remember_me` cookie.
- `signin-wrong-password` keeps the user on `/users/log-in` with the alert `Invalid email or password` and no session.
- `signin-magic` sends a login link from `Log in with email`, and opening it signs the user in. A used link is refused.
- `signin-protected-redirect` sends a signed-out visitor from `/dashboard` to `/users/log-in`.
- `signout` ends the session from the `Log out` link on `/` or in the dashboard's `Your account` menu, with the alert `Logged out successfully.`

## How to get to it (user POV)

- Choose `Log in` in the header of `/`, or open `/users/log-in`.
- Open any protected page, such as `/dashboard` or `/users/settings`, while signed out.
- On the dashboard, open the `Your account` menu (it shows the user's email) and choose `Log out`. On `/`, choose `Log out`.

## Driving it with control-goodflows

Preconditions:

- Baseline state. The browser session is signed out (fresh after launch, or after `$C browser close`).

- **Protected redirect.** Run `$C browser open "$GF_URL/dashboard"`, `$C browser set viewport 1280 800 2`, and `$C browser wait --url '**/users/log-in'`. The login page shows two forms: `#login_form_magic` and `#login_form_password`.
- **Wrong password.** Run `$C browser fill '#login_form_password input[type=email]' "user@example.com"`, `$C browser fill '#login_form_password input[type=password]' "wrong-password-123"`, and `$C browser find role button click --name "Log in only this time"`. The URL stays `/users/log-in`, `$C browser get text '#flash-error'` reads `Invalid email or password`, and the page has no `a[href="/users/log-out"]`.
- **Password login.** Run `$C login`. It prints the landing URL: `$GF_URL/` from a fresh session, or `/dashboard/accounts/<id>` when `/dashboard` bounced the user to log in first. On `/`, `$C browser snapshot -i` lists the links `Dashboard`, `Settings`, and `Log out`.
- **Session reaches protected pages.** Run `$C browser open "$GF_URL/users/settings"`. The settings page loads with `#email_form` and `#password_form` instead of redirecting.
- **Sign out from `/`.** Run `$C browser open "$GF_URL/"`, dismiss any flash with `$C browser click '#flash-info'`, and run `$C browser find role link click --name "Log out"`. The header shows `Log in` and `Register`, and `$C browser open "$GF_URL/dashboard"` lands on `/users/log-in` again.
- **Sign out from the dashboard.** Sign in, open `$GF_URL/dashboard`, then run `$C browser find role button click --name "Your account"` and `$C browser find role link click --name "Log out"`. The browser lands on `/`, `#flash-info` reads `Logged out successfully.`, and `$C browser get count 'a[href="/users/log-out"]'` prints `0`.
- **Remember me.** In a fresh session (`$C browser close`), fill the password form and choose `Log in and stay logged in`. `$C browser cookies get` lists `_good_flows_web_user_remember_me`, which `Log in only this time` does not set.
- **Magic link.** On `/users/log-in`, run `$C browser fill '#login_form_magic input[type=email]' "user@example.com"` and `$C browser click '#login_form_magic button'`. `#flash-info` reads `If your email is in our system, you will receive instructions for logging in shortly.` Open `$GF_URL/dev/mailbox`, choose `GoodFlows Log in instructions`, and read the link with `$C browser get attr 'a[href*="/users/log-in/"]' href`. Open it with `localhost` replaced by `127.0.0.1`. The page heading reads `Welcome user@example.com`, with the buttons `Keep me logged in on this device` and `Log me in only this time`. Choose `Log me in only this time`: the browser lands on `/` with `Welcome back!` and a `/users/log-out` link.
- **Used link.** Dismiss the `Welcome back!` flash, sign out from `/`, and check that `a[href="/users/log-out"]` is gone. Then open the same link again. The browser lands on `/users/log-in` and `#flash-error` reads `Magic link is invalid or it has expired.`
- **Proof.** Keep a screenshot and an ARIA snapshot of the error state, the signed-in header, the signed-out header, the mailbox message, and the magic-link sign-in.

## Gotchas

- Login returns to the page that sent the user to log in, and only falls back to `/`. Wait for an `a[href="/users/log-out"]` link, not a fixed URL.
- On `/` and the auth pages, `Log out` is a header link. On the dashboard it is inside the `Your account` menu. Both point to `/users/log-out`.
- A flash covers the header's `Log out` link on `/` for a few seconds, so the click fails with `covered by <div#flash-info>`. Click the flash first. A sign-out that silently failed leaves the session signed in, and a later "used link refused" check then proves nothing: count `a[href="/users/log-out"]` after every sign-out.
- Both login forms have an `Email` field. Always scope selectors to `#login_form_password` or `#login_form_magic`.
- `$C browser set viewport` fails before the first `open` in a new session. `$C login` already orders them correctly.
- Mailed links use `http://localhost:<port>`, but the browser session's cookies belong to `127.0.0.1`. Opening the link unchanged starts a separate, signed-out session. Replace the host before opening it.
- The mailbox at `/dev/mailbox` is in memory and resets when the server restarts. Read it in the same run that sent the mail.
- A link token is single-use. The invalid or expired message on a second use is correct behavior, not a failure.
