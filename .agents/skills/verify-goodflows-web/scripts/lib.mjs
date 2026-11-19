// Playwright helpers for driving a GoodFlows Web verification run.
//
//   import { openRun, liveReady, logIn, mailbox, psql } from "./lib.mjs";
//   const run = await openRun(process.argv[2], "my-journey");
//   ... drive run.page, call run.shot("name") and run.check("label", ok) ...
//   await run.finish();
//
// openRun reads .verify/goodflows-web/<run-id>/.instance/ (written by
// launch.sh) and puts evidence in .verify/goodflows-web/<run-id>/<journey>/.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
export const repo = execFileSync("git", ["-C", here, "rev-parse", "--show-toplevel"]).toString().trim();

export const SEED_EMAIL = "user@example.com";
export const SEED_PASSWORD = "password1234password1234";

function loadPlaywright() {
  const dirs = [process.env.PLAYWRIGHT_NODE_MODULES];
  try {
    dirs.push(path.join(execFileSync("mise", ["where", "playwright"]).toString().trim(), "node_modules"));
  } catch {}
  for (const dir of dirs.filter(Boolean)) {
    try {
      return createRequire(dir + "/")("playwright");
    } catch {}
  }
  try {
    return createRequire(import.meta.url)("playwright");
  } catch {}
  throw new Error("playwright not found: run `mise use -g playwright` or set PLAYWRIGHT_NODE_MODULES");
}

function chromiumPath() {
  if (process.env.VERIFY_CHROMIUM) return process.env.VERIFY_CHROMIUM;
  for (const p of ["/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/google-chrome"]) {
    if (fs.existsSync(p)) return p;
  }
  return undefined; // fall back to Playwright's own download
}

export function instance(runId) {
  const runDir = path.join(repo, ".verify", "goodflows-web", runId);
  const inst = path.join(runDir, ".instance");
  if (!fs.existsSync(path.join(inst, "base_url"))) {
    throw new Error(`no live instance for run ${runId}; run launch.sh first`);
  }
  const read = (f) => fs.readFileSync(path.join(inst, f), "utf8").trim();
  const build = Object.fromEntries(
    read("build").split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]),
  );
  return { runDir, baseUrl: read("base_url"), branchDb: read("branch_db"), build };
}

export async function openRun(runId, journey) {
  if (!runId) throw new Error("usage: node <journey>.mjs <run-id>");
  const inst = instance(runId);
  const outDir = path.join(inst.runDir, journey);
  fs.mkdirSync(outDir, { recursive: true });

  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ executablePath: chromiumPath() });
  const context = await browser.newContext({ baseURL: inst.baseUrl, viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();

  const logPath = path.join(outDir, "steps.log");
  const log = (line) => {
    fs.appendFileSync(logPath, line + "\n");
    console.log(line);
  };
  page.on("console", (m) => m.type() === "error" && log(`console.error ${m.text()}`));
  page.on("pageerror", (e) => log(`pageerror ${e.message}`));

  let n = 0;
  let failed = 0;
  return {
    ...inst,
    page,
    context,
    outDir,
    log,
    // Screenshot, ARIA snapshot and URL of the current page, numbered in order.
    async shot(name) {
      n += 1;
      const base = path.join(outDir, `${String(n).padStart(2, "0")}-${name}`);
      await page.screenshot({ path: base + ".png", fullPage: true });
      fs.writeFileSync(base + ".aria.txt", await page.locator("body").ariaSnapshot());
      fs.writeFileSync(base + ".url.txt", page.url() + "\n");
      log(`evidence ${path.relative(repo, base)}.{png,aria.txt,url.txt}`);
      return base;
    },
    check(name, ok, detail = "") {
      if (!ok) failed += 1;
      log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? " :: " + detail : ""}`);
      return ok;
    },
    async finish() {
      await browser.close();
      log(`${failed ? "FAILED" : "PASSED"} ${journey} (${failed} failed checks); evidence in ${path.relative(repo, outDir)}`);
      process.exitCode = failed ? 1 : 0;
    },
  };
}

// Wait until the page's LiveView socket has joined. Interacting earlier
// sends events to a page that has no server process yet.
export async function liveReady(page) {
  await page.locator("[data-phx-main].phx-connected").waitFor({ timeout: 15000 });
}

// Log in through the password form, as a user would. Login lands on the
// home page (/); with toDashboard the user then follows "Go to dashboard",
// which redirects to the last-used (or first) account's dashboard.
export async function logIn(page, { email = SEED_EMAIL, password = SEED_PASSWORD, toDashboard = true } = {}) {
  await page.goto("/users/log-in");
  await liveReady(page);
  const form = page.locator("#login_form_password");
  await form.getByLabel("Email").fill(email);
  await form.getByLabel("Password").fill(password);
  await form.getByRole("button", { name: "Log in only this time" }).click();
  await page.waitForURL((u) => u.pathname === "/");
  if (toDashboard) {
    await page.locator("#home-dashboard-link").click();
    await page.waitForURL(/\/dashboard\/accounts\/[^/]+$/);
  }
}

// Emails this server has sent (Swoosh local adapter), NEWEST FIRST.
export async function mailbox(baseUrl) {
  const res = await fetch(`${baseUrl}/dev/mailbox/json`);
  if (!res.ok) throw new Error(`mailbox returned ${res.status}`);
  return (await res.json()).data;
}

// Read-only SQL against this run's database; returns trimmed stdout.
export function psql(branchDb, sql) {
  return execFileSync(
    "psql",
    ["-h", "localhost", "-U", "postgres", "-d", `good_flows_${branchDb}_dev`, "-tAc", sql],
    { env: { ...process.env, PGPASSWORD: "postgres" } },
  )
    .toString()
    .trim();
}

export function flashText(page, kind) {
  return page.locator(`#flash-${kind}`).innerText({ timeout: 5000 }).catch(() => "");
}
