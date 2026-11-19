# Registration

A visitor creates an account by entering only an email address. The app stores an unconfirmed user and emails confirmation instructions, and the visitor confirms through that email's link. An operator can close registration with `GOOD_FLOWS_USER_REGISTRATION_ENABLED=false`. Closed is the production default. While closed, every signup link is hidden and `/users/register` sends visitors to the login page with an error.

## Sub-features

- `registration-links` shows or hides the three signup links to match the setting.
- `registration-create` creates an unconfirmed user and emails confirmation instructions.
- `registration-validate` rejects a malformed or already-registered email on the form.
- `registration-confirm` confirms the account from the emailed link and logs the user in.
- `registration-closed` redirects `/users/register` to log in with an error while registration is closed.

## How to get to it (user POV)

- Login page: **Sign up** in "Don't have an account? Sign up for an account now."
- Header: **Register** button on public pages while logged out.
- Home page: **Create an account** (`#home-register-link`) while logged out.
- `/users/register` directly.

## Driving it with Playwright

Preconditions:

- Open state: launch with no setting (the dev default) or `GOOD_FLOWS_USER_REGISTRATION_ENABLED=true`.
- Closed state: launch a separate run with `GOOD_FLOWS_USER_REGISTRATION_ENABLED=false $S/launch.sh`. The setting is read at boot, so it cannot change during a run.
- `doctor.sh` prints the `GOOD_FLOWS_USER_REGISTRATION_ENABLED` value the server got.

- **Run the script.** `node $S/journeys/registration.mjs <run-id>` reads the launched setting from `.instance/build` and checks the matching state. It covers Links, Create, Second view, and Closed.
- **Links.** Logged out, open `/` and `/users/log-in`. When open, `#home-register-link`, the header link named **Register** (exact), and the login page's **Sign up** link exist. When closed, none of the three exist.
- **Create.** When open, click **Sign up**. The URL is `/users/register`. Fill `#registration_form` **Email** with a unique address and click **Create an account**. The URL becomes `/users/log-in` and `#flash-info` reads "An email was sent to <email>, please access it to confirm your account."
- **Second view.** `psql(branchDb, "select count(*) from users")` grows by one, the new row's `confirmed_at` is null, and `mailbox(baseUrl)[0]` is addressed to the new email with subject "Confirmation instructions".
- **Validate.** Not in the script, and unproven by a drive. Type `with spaces` into **Email** without submitting. The form shows "must have the @ sign and no spaces". Submitting `user@example.com` shows "has already been taken". Neither adds a row.
- **Confirm.** Not in the script, and unproven by a drive. Open the link from the confirmation email (`/users/log-in/<token>`). The page reads "Welcome <email>". Click **Confirm and log in only this time**. The URL is `/`, `#flash-info` reads "User confirmed successfully.", and the row's `confirmed_at` is set.
- **Closed.** With registration closed, open `/users/register`. The URL becomes `/users/log-in` and `#flash-error` reads "New account registration is temporarily unavailable." The users count does not change.
- **Proof.** For open, `registration/04-after-register.png` plus the psql and mailbox checks in `steps.log`. For closed, `registration/03-register-redirected.png` plus "no user row added".

## Gotchas

- A logged-in user who opens `/users/register` is redirected to `/` whether registration is open or closed. Drive registration in a logged-out context.
- The closed check runs in the LiveView's mount, so a registration form already open in a browser when the server restarts closed can still submit. A real restart reconnects the page, so this is hard to reproduce by hand.
- Use a unique email per attempt (`verify-<Date.now()>@example.com`). The seeded address always fails with "has already been taken".
- The header **Register** link and the page heading "Register for an account" both match a loose `getByText("Register")`. Use `getByRole("link", { name: "Register", exact: true })`.
- Registration emails go to the run's in-memory mailbox, so a server restart empties it.
