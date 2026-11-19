# User settings

A logged-in user changes their email address, confirmed through a link sent to the new address, or sets a new password, which logs them in again. Settings require a login within the last 20 minutes. Otherwise the user must re-authenticate first.

## Sub-features

- `settings-open` reaches settings within the 20-minute window.
- `settings-reauth` sends a user outside the window back to log in.
- `settings-email` sends a confirmation link to a new email and applies it when the link is opened.
- `settings-password` sets a new password and logs the user in again with it.

## How to get to it (user POV)

- **Settings** in the public header or the dashboard sidebar, while logged in.
- `/users/settings` directly.

## Driving it with Playwright

Preconditions:

- A launched run whose doctor passes, and a user who logged in within the last 20 minutes (`logIn(page)` just before).
- No script yet. Write one with `openRun(runId, "user-settings")`, following SKILL.md "Drive". These steps have not been run, except opening the page, which `journeys/login.mjs` covers.
- Changing the seeded user's password breaks later journeys on this run that use `SEED_PASSWORD`. Register a new user first, or run this last.

- **Open.** Go to `/users/settings`. `#email_form` **Email** shows the current address, and `#password_form` has **New password** and **Confirm new password**.
- **Email.** Fill `#email_form` **Email** with a new unique address and click **Change Email**. `#flash-info` reads "A link to confirm your email change has been sent to the new address." `mailbox(baseUrl)[0]` is addressed to the new address. Open its `/users/settings/confirm-email/<token>` link. `#flash-info` reads "Email changed successfully." and **Email** shows the new address.
- **Password.** Fill **New password** and **Confirm new password** with the same value of at least 12 characters, and click **Save Password**. The form posts to `/users/update-password`, the URL returns to `/users/settings`, and `#flash-info` reads "Password updated successfully!"
- **Second view.** Log out, then log in with the new password. It lands on `/`. The old password shows "Invalid email or password".
- **Re-auth.** Set `authenticated_at` older than 20 minutes. `psql` is read-only by convention, so do this through `mix run` with `BRANCH_DB` set and record it as setup, not a user action. Then open `/users/settings`. The URL becomes `/users/log-in`, `#flash-error` reads "You must re-authenticate to access this page.", and the login form shows "You need to reauthenticate to perform sensitive actions on your account."
- **Proof.** Screenshots of each flash, and the logout-and-login with the new password.

## Gotchas

- A password change disconnects the user's other LiveView sessions, so other browser contexts for that user reconnect logged out.
- The email change does not apply until the link is opened. The old address still logs in until then.
- An invalid or reused email-change link shows "Email change link is invalid or it has expired."
