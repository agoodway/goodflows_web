# API keys

A signed-in user creates an API key for the current account on the API Keys page. They see its raw token exactly once, can use it against `/api/v1`, and can revoke it, after which the API refuses it.

## Sub-features

- `keys-empty` shows the `No API keys yet` empty state for an account with no keys.
- `keys-create` creates a named key from the empty state or the header button, and shows the token once.
- `keys-type` distinguishes `Private · read-write` (`sk_`) keys, which can write, from `Public · read-only` (`pk_`) keys, which get 403 on writes.
- `keys-validate` keeps the modal open with an inline error for a blank name or a past expiry.
- `keys-revoke` revokes a key after confirmation. The row shows `Revoked` and the API returns 401.
- `keys-cancel` closes the create or revoke modal with `Cancel`, `Escape`, or a backdrop click, without changing anything.

## How to get to it (user POV)

- Choose `API Keys` under `Developers` in the dashboard sidebar.
- Open `/dashboard/accounts/<account-id>/api-keys` directly.
- In the empty state, choose `Create key` in the dashed card. Once keys exist, choose `Create key` in the page header.

## Driving it with control-goodflows

Preconditions:

- Baseline state, and `$C login` succeeded.
- Acme Corp has no API keys (true for a fresh launch).

- **Open the page.** Run `$C browser open "$GF_URL/dashboard"`, `$C browser wait --url '**/dashboard/accounts/*'`, `$C browser find role link click --name "API Keys"`, and `$C browser wait '#api-keys-empty'`. The heading reads `API Keys` and the card reads `No API keys yet`.
- **Open the create modal.** Run `$C browser click '#empty-new-key-btn'` and `$C browser wait '#create-key-form'`. A dialog titled `Create API key` shows `Name`, `Type`, and `Expires at (UTC, optional)`.
- **Fill and submit.** Run `$C browser fill '#create-key-form input[name="api_key[name]"]' "verify-private"`, `$C browser select '#create-key-form select[name="api_key[type]"]' "Private (read-write)"`, then `$C browser click '#create-key-form button[type=submit]'` and `$C browser wait '#token-display-modal'`. The `Your new API key` dialog shows a token starting with `sk_`, with the warning `Copy it now. You won't be able to see it again.`
- **Use the key.** Run `export GF_API_KEY="$($C browser get value '#token-value')"` and `$C api me-active GET /api/v1/me`. The result is HTTP 200, with `data.api_key.name` set to `verify-private`, `type` set to `private`, and `account.name` set to `Acme Corp`.
- **Dismiss and see the row.** Run `$C browser click '#dismiss-token-btn'`, then `$C browser snapshot -s '#api-keys' > "$GF_RUN_DIR/api-keys/table.aria.txt"`. One row shows `verify-private`, `Private · read-write`, the token prefix followed by `…`, `Active`, and a `Revoke` button. The full token appears nowhere on the page.
- **Public key cannot write.** Create a second key named `verify-public` with type `Public (read-only)` through `#new-key-btn`, export its `pk_` token, and run `$C api public-write POST /api/v1/projects '{"slug":"verify-public"}'`. The result is HTTP 403, and `$C api public-read GET /api/v1/projects` returns 200.
- **Revoke.** Run `$C browser click 'button[id^="revoke-"]'` (the first row), then `$C browser wait '#revoke-confirm-modal'`, `$C browser click '#confirm-revoke-btn'`, and `$C browser wait --text "API key revoked."`. The row's status reads `Revoked` and it no longer has a `Revoke` button.
- **Revoked key is refused.** With `GF_API_KEY` set to the revoked token, run `$C api me-revoked GET /api/v1/me`. The result is HTTP 401 with `Unauthorized - valid API key required`.
- **Proof.** Run `$C db "select name, type, status from api_keys order by inserted_at" api-keys/db-rows.txt`. Rows match the table, and the revoked key reads `revoked`. Keep screenshots of the empty state, the filled form, the token dialog, the table, the revoke confirmation, and the revoked table.

## Gotchas

- `find role button --name "Create key"` matches both the page button and the modal's submit, and the modal's fieldset covers the click point. Submit with `#create-key-form button[type=submit]`.
- The empty state's button is `#empty-new-key-btn`, and once a key exists the header's button is `#new-key-btn`. Use the one for the current state. A combined selector such as `'#empty-new-key-btn, #new-key-btn'` did not open the modal in a proof run.
- The token is only readable while `#token-display-modal` is open. Export it before choosing `Done`; it cannot be recovered afterwards.
- Revoking a row updates the stream in place: the `Last used` cell shows a time when the key was used before it was revoked. Assert the `Status` cell, not the column positions.
- `Revoke` buttons are `revoke-<uuid>`. With several keys, pick the row by its name cell in a snapshot rather than the first match.
- The `Copy API key` button writes to the browser clipboard, which headless Chromium may deny. A red icon there is not a product failure. Read `#token-value` instead.
- `Expires at` is UTC. A past time fails validation with `must be in the future`.
