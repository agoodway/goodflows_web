# API keys

A signed-in user creates an API key for the current account on the API keys page. They see its raw token exactly once, can use it against `/api/v1`, and can revoke it, after which the API refuses it.

## Sub-features

- `keys-empty` shows the `No API keys yet` empty state for an account with no keys.
- `keys-create` creates a named key from the empty state or the header button, and shows the token once.
- `keys-type` distinguishes `Read and write` (`sk_`) keys, which can write, from `Read only` (`pk_`) keys, which get 403 on writes. The `Access` select defaults to `Read only (public key)`.
- `keys-validate` keeps the modal open with an inline error for a blank name or a past expiry.
- `keys-revoke` revokes a key after confirmation. The row shows `Revoked` and the API returns 401.
- `keys-cancel` closes the create or revoke modal with `Cancel`, `Escape`, or a backdrop click, without changing anything.

## How to get to it (user POV)

- Choose `API keys` under `// Developers` in the dashboard sidebar.
- Open `/dashboard/accounts/<account-id>/api-keys` directly.
- In the empty state, choose `Create key` in the dashed card. Once keys exist, choose `Create key` in the page header.

## Driving it with control-goodflows

Preconditions:

- Baseline state, and `$C login` succeeded.
- Acme Corp has no API keys (true for a fresh launch).

- **Open the page.** Run `$C browser open "$GF_URL/dashboard"`, `$C browser wait --url '**/dashboard/accounts/*'`, `$C browser click '#sidebar a[href$="/api-keys"]'`, and `$C browser wait '#api-keys-empty'`. The heading reads `API keys` and the card reads `No API keys yet`.
- **Open the create modal.** Run `$C browser click '#empty-new-key-btn'` and `$C browser wait '#create-key-form'`. A dialog titled `Create API key` shows `Name` (`#api_key_name`), `Access` (`#api_key_type`, options `Read only (public key)` and `Read and write (private key)`), and `Expires at (UTC, optional)` (`#api_key_expires_at`). `$C browser press Escape` closes it with nothing stored.
- **Validation.** Reopen the dialog and submit it with an empty name: `can't be blank` appears and the dialog stays open. Fill a name, set a past expiry (see Gotchas), and submit: `must be in the future` appears and no row is stored.
- **Fill and submit.** Run `$C browser fill '#api_key_name' "verify-private"`, `$C browser select '#api_key_type' private`, then `$C browser click '#create-key-form button[type=submit]'` and `$C browser wait '#token-display-modal'`. The `Your new API key` dialog shows a token starting with `sk_`, with the warning `Copy the key now. It is not shown again.`
- **Use the key.** Run `export GF_API_KEY="$($C browser get value '#token-value')"` and `$C api me-active GET /api/v1/me`. The result is HTTP 200, with `data.api_key.name` set to `verify-private`, `type` set to `private`, and `account.name` set to `Acme Corp`.
- **Dismiss and see the row.** Run `$C browser click '#dismiss-token-btn'`, then `$C browser snapshot -s '#api-keys' > "$GF_RUN_DIR/api-keys/table.aria.txt"`. One row (`api_keys-<uuid>`) shows `verify-private`, `Read and write`, the token prefix followed by `…`, `Active`, and a `Revoke` button. The full token appears nowhere on the page.
- **Public key cannot write.** Create a second key named `verify-public` through `#new-key-btn`, leaving `Access` at `Read only (public key)`, export its `pk_` token, and run `$C api public-write POST /api/v1/projects '{"slug":"verify-public"}'`. The result is HTTP 403, and `$C api public-read GET /api/v1/projects` returns 200.
- **Revoke.** Run `$C browser find role button click --name "Revoke verify-private"`, then `$C browser wait '#revoke-confirm-modal'`. `$C browser press Escape` closes it with the key still `Active`. Open it again, run `$C browser click '#revoke-confirm-modal-confirm'` (`Revoke key`) and `$C browser wait --text "API key revoked."`. The `verify-private` row's status reads `Revoked` and it no longer has a `Revoke` button. `verify-public` stays `Active`.
- **Revoked key is refused.** With `GF_API_KEY` set to the `verify-private` token, run `$C api me-revoked GET /api/v1/me`. The result is HTTP 401 with `Unauthorized - valid API key required`.
- **Proof.** Run `$C db "select name, type, status from api_keys order by inserted_at" api-keys/db-rows.txt`. Rows match the table, and the revoked key reads `revoked`. Keep screenshots of the empty state, the filled form, the token dialog, the table, the revoke confirmation, and the revoked table.

## Gotchas

- `find role button --name "Create key"` matches both the page button and the modal's submit, and the open modal covers the page button. Submit with `#create-key-form button[type=submit]`.
- The empty state's button is `#empty-new-key-btn`, and once a key exists the header's button is `#new-key-btn`. Use the one for the current state. A combined selector such as `'#empty-new-key-btn, #new-key-btn'` did not open the modal in a proof run.
- The token is only readable while `#token-display-modal` is open. Export it before choosing `Done`; it cannot be recovered afterwards.
- Revoking a row updates the stream in place: the `Last used` cell shows a time when the key was used before it was revoked. Assert the `Status` cell, not the column positions.
- `Revoke` buttons are `revoke-<uuid>` with the accessible name `Revoke <key name>`. New keys go to the top of the table, so the first `revoke-` button is the newest key. Pick the button by name. `button[id^="revoke-"]` also matches `#revoke-confirm-modal` while it is open.
- The `Copy API key` button writes to the browser clipboard, which headless Chromium may deny. A red icon there is not a product failure. Read `#token-value` instead.
- `Expires at` is UTC. A past time fails validation with `must be in the future`.
- `$C browser fill` cannot set the `datetime-local` expiry field: the value stays empty and the key is created without an expiry. Set it with `$C browser eval "(() => { const el = document.querySelector('#api_key_expires_at'); el.value = '2020-01-01T00:00'; el.dispatchEvent(new Event('input', {bubbles: true})); return el.value })()"`, and check it with `$C browser get value '#api_key_expires_at'` before submitting.
- Keys are per account. A key made while the dashboard shows Globex Industries is a member's key, which cannot write projects (see [Projects API](./projects-api.md)).
