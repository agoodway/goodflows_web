// Feature map: features/api-keys.md
//   node scripts/journeys/api-keys.mjs <run-id>
import { openRun, logIn, liveReady, flashText } from "../lib.mjs";

const run = await openRun(process.argv[2], "api-keys");
const { page, check, shot } = run;
const me = (token) => fetch(`${run.baseUrl}/api/v1/me`, { headers: { authorization: `Bearer ${token}` } });

try {
  await logIn(page);
  // api-keys-open
  await page.getByRole("link", { name: "API Keys" }).first().click();
  await page.waitForURL(/\/api-keys$/);
  await liveReady(page);
  await shot("api-keys-page");

  // api-keys-create
  const name = `verify-${Date.now()}`;
  await page.locator("#new-key-btn, #empty-new-key-btn").first().click();
  const form = page.locator("#create-key-form");
  await form.getByLabel("Name").fill(name);
  await form.getByLabel("Type").selectOption({ label: "Private (read-write)" });
  await shot("create-form");
  await form.getByRole("button", { name: "Create key" }).click();
  const token = await page.locator("#token-value").inputValue();
  check("token shown once after create", token.length > 20);
  await shot("token-modal");
  await page.locator("#dismiss-token-btn").click();
  const row = page.locator("#api-keys tr", { hasText: name });
  check("new key listed as Active", (await row.innerText()).includes("Active"));
  await shot("key-listed");

  // Side effect: the token authenticates against the JSON API.
  const res = await me(token);
  const body = res.ok ? await res.json() : null;
  check("GET /api/v1/me with the key returns 200", res.status === 200, `status ${res.status}`);
  check("API reports the same key name", body?.data?.api_key?.name === name, body?.data?.api_key?.name);

  // api-keys-revoke
  await row.getByRole("button", { name: "Revoke" }).click();
  await page.locator("#confirm-revoke-btn").click();
  await page.locator("#flash-info").waitFor();
  check("revoke flash", (await flashText(page, "info")).includes("API key revoked."));
  check("key listed as Revoked", (await row.innerText()).includes("Revoked"));
  await shot("key-revoked");
  const after = await me(token);
  check("revoked key is rejected with 401", after.status === 401, `status ${after.status}`);
} catch (e) {
  check("journey ran to completion", false, e.message);
  await shot("error").catch(() => {});
} finally {
  await run.finish();
}
