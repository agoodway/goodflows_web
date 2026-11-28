// Feature map: features/login.md
//   node scripts/journeys/login.mjs <run-id>
import { openRun, liveReady, mailbox, flashText, SEED_EMAIL, SEED_PASSWORD } from "../lib.mjs";

const run = await openRun(process.argv[2], "login");
const { page, check, shot } = run;

try {
  // login-password-wrong
  await page.goto("/users/log-in");
  await liveReady(page);
  await shot("login-page");
  let form = page.locator("#login_form_password");
  await form.getByLabel("Email").fill(SEED_EMAIL);
  await form.getByLabel("Password").fill("not-the-password");
  await form.getByRole("button", { name: "Log in only this time" }).click();
  await page.waitForURL(/\/users\/log-in$/);
  check("wrong password shows error", (await flashText(page, "error")).includes("Invalid email or password"));
  await shot("wrong-password");

  // login-password
  await liveReady(page);
  form = page.locator("#login_form_password");
  await form.getByLabel("Email").fill(SEED_EMAIL);
  await form.getByLabel("Password").fill(SEED_PASSWORD);
  await form.getByRole("button", { name: "Log in only this time" }).click();
  await page.waitForURL((u) => u.pathname === "/");
  check("password login lands on the home page", true, page.url());
  check("welcome flash", (await flashText(page, "info")).includes("Welcome back!"));
  check("header shows the signed-in email", (await page.locator("header").innerText()).includes(SEED_EMAIL));
  await shot("home-after-password-login");
  await page.locator("#home-dashboard-link").click();
  await page.waitForURL(/\/dashboard\/accounts\/[^/]+$/);
  const heading = await page.locator("#dashboard h1").innerText();
  check("dashboard names a seeded account", ["Acme Corp", "Globex Industries"].includes(heading), heading);
  await shot("dashboard-after-password-login");

  // Second view of the session: a fresh request is still authenticated.
  await page.goto("/users/settings");
  check("session survives a new request", page.url().endsWith("/users/settings"), page.url());

  // login-logout
  await page.goto("/");
  await page.getByRole("link", { name: "Log out" }).click();
  await page.waitForURL((u) => u.pathname === "/");
  check("logout flash", (await flashText(page, "info")).includes("Logged out successfully."));
  await page.goto("/users/settings");
  check("settings requires login after logout", page.url().includes("/users/log-in"), page.url());
  await shot("after-logout");

  // login-magic-link
  const before = (await mailbox(run.baseUrl)).length;
  await page.goto("/users/log-in");
  await liveReady(page);
  await page.locator("#login_form_magic").getByLabel("Email").fill(SEED_EMAIL);
  await page.getByRole("button", { name: "Log in with email" }).click();
  await page.locator("#flash-info").waitFor();
  check("magic link flash", (await flashText(page, "info")).includes("If your email is in our system"));
  await shot("magic-link-requested");
  const mails = await mailbox(run.baseUrl);
  const mail = mails[0];
  check("one new email to the seeded user", mails.length === before + 1 && mail.to.some((t) => t.includes(SEED_EMAIL)));
  const link = mail.text_body.match(/https?:\/\/\S+\/users\/log-in\/\S+/)?.[0];
  check("email contains a log-in link on this server", !!link && link.startsWith(run.baseUrl), link);
  await page.goto(link);
  await liveReady(page);
  await shot("magic-link-page");
  await page.getByRole("button", { name: "Log me in only this time" }).click();
  // The logged-out visit to /users/settings above stored it as the return
  // path, so login sends the user back there instead of to "/".
  await page.waitForURL(/\/users\/settings$/);
  check("magic link logs in and returns to the page that required login", true, page.url());
  check("settings shows the signed-in email", (await page.locator("#email_form").getByLabel("Email").inputValue()) === SEED_EMAIL);
  await shot("settings-after-magic-link");
} catch (e) {
  check("journey ran to completion", false, e.message);
  await shot("error").catch(() => {});
} finally {
  await run.finish();
}
