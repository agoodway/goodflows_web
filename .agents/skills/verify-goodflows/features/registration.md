# Registration

A visitor creates a user with just an email address, receives a confirmation link by email, and is confirmed and signed in when they open it.

## Sub-features

- `register-submit` creates an unconfirmed user and flashes `An email was sent to <email>, please access it to confirm your account.`
- `register-validate` shows inline errors for an invalid or already-registered email.
- `register-confirm` confirms and signs in the new user from the mailed `/users/log-in/<token>` link.

## How to get to it (user POV)

- Choose `Register` in the header of `/` while signed out.
- Open `/users/register`.
- Follow the `Sign up` link on `/users/log-in`.

## Driving it with control-goodflows

Preconditions:

- Baseline state. The browser session is signed out (`$C browser close` first if an earlier recipe signed in).
- No user exists with the email used, such as `verify-<RUN_ID-lowercased>@example.com`.

- **Open the form.** Run `$C browser open "$GF_URL/users/register"`, `$C browser set viewport 1280 800 2`, and `$C browser wait '#registration_form'`. The form has one `Email` textbox and a `Create an account` button.
- **Duplicate email.** Run `$C browser fill '#registration_form input[type=email]' "user@example.com"` and `$C browser click '#registration_form button'`. The URL stays `/users/register` and the form shows `has already been taken`.
- **Register.** Fill the new email and submit. Run `$C browser wait --url '**/users/log-in'`. `$C browser get text '[role=alert]'` reads `An email was sent to <email>, please access it to confirm your account.`
- **Stored user.** Run `$C db "select email, confirmed_at is null from users where email = '<email>'" registration/db-user-before.txt`. One row ends in `|t` (unconfirmed).
- **Confirm.** Open `$GF_URL/dev/mailbox` and choose `GoodFlows Confirmation instructions`. Read its link with `$C browser get attr 'a[href*="/users/log-in/"]' href` and open it with `localhost` replaced by `127.0.0.1`. The heading reads `Welcome <email>`. Choose `Confirm and log in only this time`. The browser lands on `/` with the alert `User confirmed successfully.` and a `/users/log-out` link. The same `db` query now ends in `|f`.
- **No accounts yet.** Open `$GF_URL/dashboard`. The browser lands on `/` with `You don't have access to any accounts. Please contact support.`
- **Proof.** Keep screenshots of the duplicate error, the post-submit flash, the mailbox message, the confirmed state, and the no-accounts flash, plus both `db` files.

## Gotchas

- Registration does not ask for a password. Do not look for a password field.
- The confirmation page's buttons say `Confirm and stay logged in` and `Confirm and log in only this time`, not the `Log me in` labels of an existing user's magic link.
- The mailbox lists every message the server sent this run, including sign-in mail. Choose the `Confirmation instructions` message by name before reading the link.
- Mailed links use `localhost`. Replace it with `127.0.0.1`, or the confirmation signs in a separate cookie jar.
- A new user belongs to no account, so `/dashboard` redirecting to `/` with the no-accounts flash is correct behavior, not a registration failure.
- The mailbox is in memory and resets when the server restarts.
