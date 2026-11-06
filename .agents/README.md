# GoodFlows in Amp orbs

`.agents/setup` prepares Debian 12 x86-64 orbs for the Phoenix app in `app/`.
It installs Elixir 1.19.4, Erlang/OTP 28.1.1, PostgreSQL 15,
and native build tools. Elixir 1.19 is required by locked dependencies and the
runtime configuration even though `mix.exs` permits earlier releases.

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

Lifecycle files must reach the project's default branch before future orbs
use them. Amp then snapshots setup's installed packages and build caches;
an exact snapshot skips setup, while a stale snapshot reruns it incrementally.
