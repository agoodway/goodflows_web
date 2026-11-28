# API keys

An account member creates an API key from the dashboard, sees the raw token exactly once, and uses it as `Authorization: Bearer <token>` against the JSON API, which the goodflows CLI does. Revoking the key marks it Revoked in the list, and the API rejects it from then on.

## Sub-features

- `api-keys-open` reaches the API Keys page for the current account.
- `api-keys-create` creates a public (read-only) or private (read-write) key with an optional expiry, and shows the token once.
- `api-keys-use` authenticates `GET /api/v1/me` with the new token.
- `api-keys-revoke` revokes a key after confirmation, and the API then returns 401.

## How to get to it (user POV)

- Dashboard sidebar: **API Keys** under "Developers", at `/dashboard/accounts/<account-id>/api-keys`.
- On the page: **New key** (`#new-key-btn`) when keys exist, or the empty state's button (`#empty-new-key-btn`).

## Driving it with Playwright

Preconditions:

- A launched run whose doctor passes. `logIn(page)` puts the seeded user on an account dashboard (`Acme Corp`, owner).

- **Run the script.** `node $S/journeys/api-keys.mjs <run-id>` drives every bullet below.
- **Open.** Click the sidebar link named **API Keys** (`.first()`, since the mobile sidebar has a second copy). The URL ends in `/api-keys`.
- **Create.** Click `#new-key-btn` or `#empty-new-key-btn`. In `#create-key-form`, fill **Name**, select **Type** `Private (read-write)` or `Public (read-only)`, and click **Create key**. The `#token-display-modal` reads "Your new API key" and `#token-value` holds the token.
- **Dismiss.** Click `#dismiss-token-btn` (**Done**). The row in `#api-keys` with that name shows a `Private` or `Public` badge, a prefix, and `Active`.
- **Use.** `curl -s -H "Authorization: Bearer $TOKEN" $BASE_URL/api/v1/me` returns 200 with `data.api_key.name` equal to the name, plus `data.account.name` and `data.user.email`.
- **Revoke.** In the key's row, click **Revoke**, then `#confirm-revoke-btn`. `#flash-info` reads "API key revoked.", and the row shows `Revoked` and no Revoke button.
- **Second view.** The same `curl` now returns 401 with a `www-authenticate: Bearer` header.
- **Proof.** `api-keys/03-token-modal.png`, `api-keys/04-key-listed.png`, and `api-keys/05-key-revoked.png`, plus the API status checks in `steps.log`.

## Gotchas

- The raw token appears only in `#token-value` before **Done**. Read it before dismissing, because it cannot be shown again.
- The sidebar renders twice (desktop and mobile overlay), so `getByRole("link", { name: "API Keys" })` matches two links. Use `.first()`.
- The key list is a LiveView stream. Locate rows by name (`#api-keys tr` with `hasText`), not by index.
- Public keys are read-only. A write endpoint (for example `POST /api/v1/projects`) rejects them, so use a private key to prove writes.
