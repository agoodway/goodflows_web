// Feature map: features/registration.md
//   node scripts/journeys/registration.mjs <run-id>
// Checks the open or closed state the server was launched with
// (GOOD_FLOWS_USER_REGISTRATION_ENABLED; dev default is open).
import { openRun, liveReady, logIn, mailbox, psql, flashText } from "../lib.mjs";

const run = await openRun(process.argv[2], "registration");
const { page, check, shot } = run;
const setting = run.build.GOOD_FLOWS_USER_REGISTRATION_ENABLED;
const open = setting === undefined ? true : ["true", "1", "yes"].includes(setting.toLowerCase());
run.log(`registration expected ${open ? "open" : "closed"} (GOOD_FLOWS_USER_REGISTRATION_ENABLED=${setting ?? "unset"})`);

const userCount = () => Number(psql(run.branchDb, "select count(*) from users"));

try {
  // registration-links
  await page.goto("/");
  const homeLink = await page.locator("#home-register-link").count();
  const headerLink = await page.getByRole("link", { name: "Register", exact: true }).count();
  await shot("home");
  await page.goto("/users/log-in");
  await liveReady(page);
  const signUp = await page.getByRole("link", { name: "Sign up" }).count();
  await shot("login-page");
  check(`home "Create an account" ${open ? "shown" : "hidden"}`, (homeLink > 0) === open);
  check(`header "Register" ${open ? "shown" : "hidden"}`, (headerLink > 0) === open);
  check(`login "Sign up" ${open ? "shown" : "hidden"}`, (signUp > 0) === open);

  const usersBefore = userCount();
  if (open) {
    // registration-create
    await page.getByRole("link", { name: "Sign up" }).click();
    await page.waitForURL(/\/users\/register$/);
    await liveReady(page);
    const email = `verify-${Date.now()}@example.com`;
    await page.locator("#registration_form").getByLabel("Email").fill(email);
    await shot("register-filled");
    await page.getByRole("button", { name: "Create an account" }).click();
    await page.waitForURL(/\/users\/log-in$/);
    check("confirmation flash", (await flashText(page, "info")).includes(`An email was sent to ${email}`));
    await shot("after-register");
    check("one user row added", userCount() === usersBefore + 1);
    check("user stored unconfirmed", psql(run.branchDb, `select confirmed_at is null from users where email = '${email}'`) === "t");
    const mail = (await mailbox(run.baseUrl))[0];
    check("login instructions emailed", !!mail && mail.to.some((t) => t.includes(email)), mail?.subject);

    // registration-confirm
    const link = mail?.text_body.match(/https?:\/\/\S+\/users\/log-in\/\S+/)?.[0];
    check("email has a confirm link on this server", !!link && link.startsWith(run.baseUrl), link);
    await page.goto(link);
    await liveReady(page);
    check("confirm page greets the new user", (await page.locator("main").innerText()).includes(`Welcome ${email}`));
    await shot("confirm-page");
    await page.getByRole("button", { name: "Confirm and log in only this time" }).click();
    await page.waitForURL((u) => u.pathname === "/");
    check("confirmed flash", (await flashText(page, "info")).includes("User confirmed successfully."));
    check("header shows the new user", (await page.locator("header").innerText()).includes(email));
    check("confirmed_at set", psql(run.branchDb, `select confirmed_at is not null from users where email = '${email}'`) === "t");
    await shot("confirmed-home");
    await run.context.clearCookies();
  } else {
    // registration-closed
    await page.goto("/users/register");
    await page.waitForURL(/\/users\/log-in$/);
    check("register redirects to log in", true, page.url());
    check("closed flash", (await flashText(page, "error")).includes("New account registration is temporarily unavailable."));
    await shot("register-redirected");
    check("no user row added", userCount() === usersBefore);
  }

  // registration-logged-in: same result in both states.
  await logIn(page, { toDashboard: false });
  await page.goto("/users/register");
  await page.waitForURL((u) => u.pathname === "/");
  check("logged-in visit to /users/register lands on /", true, page.url());
  check("no error flash for a logged-in user", (await flashText(page, "error")) === "");
  await shot("logged-in-register-redirect");
  await page.goto("/users/log-in");
  await liveReady(page);
  check("re-auth login page asks to reauthenticate", (await page.locator("main").innerText()).includes("You need to reauthenticate"));
  check("re-auth login page has no Sign up link", (await page.getByRole("link", { name: "Sign up" }).count()) === 0);
  check("header has no Register link while logged in", (await page.getByRole("link", { name: "Register", exact: true }).count()) === 0);
  await shot("logged-in-login-page");
} catch (e) {
  check("journey ran to completion", false, e.message);
  await shot("error").catch(() => {});
} finally {
  await run.finish();
}
