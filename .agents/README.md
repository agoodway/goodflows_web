# GoodFlows in Amp orbs

`.agents/setup` prepares Debian 13 x86-64 orbs for the Phoenix app in `app/`.
It installs Elixir 1.19.4, Erlang/OTP 28.1.1, the release's PostgreSQL
(17 on Debian 13, 15 on Debian 12), and native build tools. Elixir 1.19 is
required by locked dependencies and the runtime configuration even though
`mix.exs` permits earlier releases.

Setup fetches the locked Mix dependencies, compiles dev and test builds,
installs the pinned Tailwind/esbuild binaries, builds assets,
and migrates both databases. It reuses installed tools and
build caches on repeat runs. No npm install is needed: assets use Mix tools.

The existing dev/test configuration supplies local database credentials and
development-only encryption keys. Setup does not copy the production env
template or require Sprites, mail, or monitoring credentials. Configure real
integration credentials through Amp secrets, never in these scripts.

PostgreSQL's durability is disabled only in the disposable orb cluster.
Setup temporarily starts the database for migrations; `.agents/resume`
restores it under Amp's supervisor after activation or wake, without installs.
The setup's seeded development account is `user@example.com` with password
`password1234password1234` (see `app/priv/repo/seeds.exs`).

From the repository root, run `amp orb services ensure` to start the declared
PostgreSQL and Phoenix services and obtain the current orb's portal URL.
The Phoenix service uses Amp's assigned port and public hostname; generated
portal state is ignored by Git. Toolchains are available to agents and services
through a single login-profile hook, not just the setup process.

Checks:

- `cd app && mix precommit` — the repository's full checks and Elixir suite.
- `goodflows run ci` — the same checks as separate workflow jobs.

## CLI end-to-end smoke

`scripts/e2e-cli-smoke.sh` checks that the goodflows CLI's run-history
upload works against this app (GOO-247). After setup, run it from any
directory; it takes about two minutes on a fresh orb and exits nonzero on
any failed check.

It runs `mix setup`, starts its own dev `mix phx.server` on port 4123
(`SMOKE_PORT`) so it can stop and restart it, and builds the CLI from
agoodway/goodflows `main` (`GOODFLOWS_CLI_REF`) with `cargo install`,
installing rustup if needed. `GOODFLOWS_BIN=/path/to/goodflows` skips the
build. It creates a private API key for the seeded `user@example.com` in
Acme Corp and a new `e2e-smoke-<timestamp>` project, then runs workflows in
a temporary git checkout: a parent that calls a child workflow, a
GitHub Actions-style `pull_request` run on a detached checkout and a `push`
run on a branch, and a run made while the server is down whose spooled
record `goodflows reports upload` replays. It prints `PASS` or `FAIL` for
each server-side check: upload statuses in the server log (no 422), stored
`graph`, `ci` and `source.branch`, an exact retry returning 200, and the
`branch` and `event` filters of `GET /api/v1/projects/:project/workflow-runs`
and `goodflows history list`. The run's workspace and server log stay under
`/tmp/goodflows-e2e.*`.

## Lifecycle

Lifecycle files must reach the project's default branch before future orbs
use them. Amp then snapshots setup's installed packages and build caches;
an exact snapshot skips setup, while a stale snapshot reruns it incrementally.
