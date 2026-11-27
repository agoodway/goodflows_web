---
name: run-ci-goodflows
description: "Use when running GoodFlows checks or reading a goodflows failure in the GoodFlows web app (the Phoenix app in app/)."
---

# Run CI for GoodFlows Web

## What GoodFlows runs

Config: `goodflows.toml` at the repository root. It has no default workflow, only the named workflow `ci`, which mirrors `mix precommit` (see `app/mix.exs`).

- `[settings]`: `workdir = "app"`, `fail_fast = false`, and `MIX_ENV = "test"`, `CI = "true"` for every job. `parallelism` is unset, so a run uses every logical CPU.
- `[environments.orb]`: `parallelism = 4`.
- `[reporting]`: project `goodflows-web` with `history = true`, so every run uploads its record to the GoodFlows server when `GOODFLOWS_URL` and `GOODFLOWS_API_KEY` are set. The change request flow (`gf-change-build`) relies on that upload for the policy's required `ci` workflow.

Jobs in workflow `ci`, in `depends_on` order:

| Job | Command in the config | Depends on |
|---|---|---|
| `compile` | `mix compile --warnings-as-errors` | none |
| `test` | `mix test --include slow` | `compile` |
| `deps` | `mix deps.unlock --check-unused` | `compile` |
| `format` | `mix format --check-formatted` | `compile` |
| `credo` | `mix credo --strict` | `compile` |
| `doctor` | `mix doctor` | `compile` |
| `sobelow` | `mix sobelow --config` | `compile` |
| `dialyzer` | `mix dialyzer` | `compile` |

## Scenarios

The map comes from the config and the commands its header comments name; nobody assigned other scenarios.

The binary is `goodflows` on `PATH`. `.agents/setup` installs the pinned release (0.10.0) into `/usr/local/bin`; outside an orb, install it as the [goodflows README](https://github.com/agoodway/goodflows#install) says.

| For | Run |
|---|---|
| **Default:** every check, before finishing a change or shipping a change request | `goodflows run ci` |
| Every check in an Amp orb, with the orb's parallelism | `goodflows run ci --env orb` |
| Only the tests (and `compile`) while iterating | `goodflows run ci --jobs test` |
| Selected jobs, such as format and credo | `goodflows run ci --jobs format,credo` |
| Check the config parses, running nothing | `goodflows validate` |

A run's upload records the commit and whether the tree was dirty. A change request only counts a `ci` run from a clean tree at its head, so commit before the run that should satisfy it.

## Run it locally

From the repository root:

```bash
goodflows run ci
```

| Job | Command in the config | Invocation that runs it |
|---|---|---|
| `compile` | `mix compile --warnings-as-errors` | `goodflows run ci` |
| `test` | `mix test --include slow` | `goodflows run ci` |
| `deps` | `mix deps.unlock --check-unused` | `goodflows run ci` |
| `format` | `mix format --check-formatted` | `goodflows run ci` |
| `credo` | `mix credo --strict` | `goodflows run ci` |
| `doctor` | `mix doctor` | `goodflows run ci` |
| `sobelow` | `mix sobelow --config` | `goodflows run ci` |
| `dialyzer` | `mix dialyzer` | `goodflows run ci` |

`test` needs the local PostgreSQL on port 5432 that `.agents/setup` and `.agents/resume` start in an orb.

## Read a failure

- `goodflows last` prints the last run's report again.
- `goodflows run --failed` reruns the jobs that failed and the jobs skipped because a dependency did not pass.

For exit codes, error codes, the `Failures` section, `last`, `run --failed`, detached runs, and the JSON fields, run `goodflows agents`, which prints the guide for the installed goodflows.

## Green

`goodflows run ci` from the repository root passed, using `goodflows` on `PATH`.

## Keeping this skill accurate

When `goodflows.toml` changes, the job table and the scenario map have to match it: job names, commands, `depends_on`, profiles, and the default `goodflows run ci`. When the GoodFlows config changes, run `maintain-ci-skill` to keep this skill accurate. Install it with `goodflows skills install`.
