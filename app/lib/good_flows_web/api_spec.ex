defmodule GoodFlowsWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3 specification for the `/api/v1` JSON API, built from the
  router's `open_api_operation` annotations. Served at `/api/v1/openapi`
  with Swagger UI at `/api/v1/docs`.
  """
  @behaviour OpenApiSpex.OpenApi

  alias GoodFlowsWeb.{Endpoint, Router}
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @impl OpenApi
  def spec do
    OpenApiSpex.resolve_schema_modules(%OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "GoodFlows API",
        version: "1.0.0",
        description: """
        ## Authentication

        Every endpoint requires an API key in the `Authorization` header:

            Authorization: Bearer <api_key>

        Create keys from the dashboard under **Developers → API Keys**.

        - **Public keys** (`pk_…`) are read-only.
        - **Private keys** (`sk_…`) can also write.

        A key is scoped to your membership in one account. To work with
        several accounts, create a key in each.

        ## Spry

        Spry drives the lifecycle of a [Sprite](https://sprites.dev) VM from a
        stored recipe, replacing the `spry` CLI.

        1. **Create a project** with `POST /api/v1/projects` and a `slug`
           (1 to 64 bytes of lowercase letters, digits, `_`, and `-`,
           starting with a letter or digit; unique in the account). Recipes
           live under `/api/v1/projects/{project}`; a slug with no project
           is `404` and is never created implicitly. A project that still
           has recipes, stored test reports, or pools cannot be deleted
           (`409`).
        2. **Set the Sprites credential** with `PUT /api/v1/sprites-credential`
           (a private key of an account owner or admin). The token is stored
           encrypted and is never returned; every VM operation for the account
           uses it, whatever the project.
        3. **Create a recipe** with `POST /api/v1/projects/{project}/recipes`: a
           sprite `name` template plus `setup`, `start`, `stop`, and `teardown`
           lists of shell lines run inside the VM. Placeholders `{{branch}}`,
           `{{branch_slug}}`, `{{commit}}`, and `{{remote}}` are filled from the
           run request; step lines may also use `{{sprite}}`. The name is the
           sprite name template and is unique per project (another project may
           reuse it); it must expand to lowercase letters, digits, and hyphens,
           so prefer `{{branch_slug}}` over `{{branch}}`. The project comes from
           the URL; a `project` body field is rejected.
        4. **Start a run** with `POST /api/v1/projects/{project}/recipes/{id}/runs`
           and a `phase`. Add `dry_run: true` to see the plan without changing
           anything (any boolean form, such as `"true"` or `"1"`, counts as a
           dry run). Dry runs also need a private key, because they use the
           stored credential to look up the VM. Inputs (`branch`, `commit`,
           `remote`) are inserted unquoted into shell lines, so they are
           limited to safe characters and must start with a letter or digit.
           Only one run per resolved sprite name may be active in the account,
           across all its projects (`409` with `active_run_id`).
        5. **Poll the run** with `GET /api/v1/runs/{id}` until its `status` is
           `succeeded` or `failed`. `GET /api/v1/projects/{project}/recipes/{id}/runs`
           lists a recipe's runs a page at a time (`limit`, `cursor`). Each run
           carries `project` (the slug) and `recipe_id`, so its recipe is at
           `/api/v1/projects/{project}/recipes/{recipe_id}`; both are `null`
           once the recipe is deleted.

        Limitations and caveats:

        - **Host steps are not supported.** Recipes run only in-VM commands;
          `{host: …}` items are rejected.
        - **Projects do not isolate VMs.** Sprite names are global to the
          Sprites token, so recipes in different projects that resolve to the
          same sprite name drive the same VM: one project's `teardown` can
          destroy a VM another project set up. The one-active-run guard only
          keeps their runs from overlapping. Other accounts storing the same
          token, or the `spry` CLI using it, share those names too.
        - **Step commands and output are visible only to private keys.**
          Public (`pk_…`) keys see each step's status, exit code, and timing,
          but not its `command` or `output`. Any private key of the account
          can still read them, so avoid printing secrets in step lines.
          Stored output is cleared after a retention period (30 days by
          default).
        - **Timeouts are local.** Each VM action has an elapsed-time deadline
          and each run a total budget (6 hours by default). When a deadline
          passes or a connection drops, the server stops waiting and fails the
          step, but this does not guarantee that a shell command already sent
          to the VM has stopped. Make recipes idempotent.
        - **Abandoned runs.** A run whose worker is lost is marked `failed` once
          the server confirms that worker has stopped. If its owner cannot be
          reached, the run keeps blocking new runs for that sprite while it is
          investigated, so two workers never drive the same VM at once. If a
          run stays blocked that way (for example after a redeploy that changed
          server node names), it is released once the worker's hard time limit
          has certainly passed, or earlier by an operator server-side once the
          old worker is known to be gone. A run interrupted by an orderly
          server shutdown fails with "interrupted by server shutdown".
        - **Contended admission.** `409` always includes the blocking run's
          `active_run_id`. If runs for the same sprite keep starting and
          finishing while a request is admitted, the API responds `503` with
          `Retry-After`; retry the request.

        ## Sprite pools

        A pool is a project's set of pre-built Sprite VMs ("members") that a
        client leases to run jobs, so the Sprites token never leaves the
        server. Members run the pool `setup` once and are restored to that
        golden state after every lease. The full client contract (channel
        events, payloads, error codes, resume) is in `docs/pool-protocol.md`.

        1. **Create a pool** with `POST /api/v1/projects/{project}/pools`
           (`slug`, `setup`, `min_ready`, `max_members`; the account needs a
           Sprites credential). Members are named `gfp-…`; recipe names and
           run sprite names may not use that prefix. A project with pools
           cannot be deleted (`409`).
        2. **Start a session** with
           `POST /api/v1/projects/{project}/pools/{pool}/sessions`. It
           returns a channel `topic`. Only the creating key may use it.
        3. **Connect** to the Phoenix Channels v2 WebSocket at
           `/api/v1/socket/websocket?vsn=2.0.0` with the private key as the
           socket auth token (`Sec-WebSocket-Protocol: phoenix,
           base64url.bearer.phx.<unpadded standard base64 of the key>`; a key
           in the query string is refused) and join `pool_session:<id>`.
           Join errors: `not_found`, `forbidden`, `ended`.
        4. **Upload the workspace** once with
           `PUT /api/v1/pool-sessions/{id}/workspace` (`application/gzip`
           tar, 256 MiB by default). Members are announced `member_granted`,
           then `member_ready` once it is extracted into `/workspace`.
        5. **Run commands** with the channel event `exec` (`member_id`,
           `command` or `argv`, `cwd`, `env`, `timeout_ms`,
           `collect_reports`, `job`, `step`): `output` events (base64 `data`,
           per-exec `seq`), then `exit` with the status, exit code, the
           `GOODFLOWS_OUTPUT` file (at most 65,537 bytes), and the report
           manifest. `cancel` kills an exec. After a reconnect, `resume`
           replays buffered output (a `gap` names lost ranges) and the exit.
           Reports download from
           `GET /api/v1/pool-execs/{exec_id}/reports/{name}` until the
           member runs another exec (`410`).
        6. **Release** with the channel event `release` or
           `DELETE /api/v1/pool-sessions/{id}`. A session with no client
           for 60 seconds expires (`client_disconnected`), as does one with
           no member by its acquisition timeout (`no_member_available`),
           after its lifetime (`lifetime_exceeded`), when its key is
           revoked (`key_revoked`), or when its server is lost
           (`session_owner_lost`). Running execs end before `session_ended`.

        Pool, session, workspace, and report routes answer `503` while pools
        are disabled on the server (except pool deletion, which stays
        available so a rollback can be cleaned up), and the pool socket
        refuses connections (HTTP `403`).

        ## Test reports

        `POST /api/v1/projects/{project}/test-reports` stores one
        `exunit-timings` report produced by a local or CI test run. It needs a
        private (`sk_…`) key, and the project must already exist: the path
        slug selects it (an invalid slug is `422` on `project`, a slug the
        account does not have is `404`). The body has no `project` or
        `account_id`. Authentication and the project are checked before the
        body is read. This is storage only: there is no read, query, grouping
        or retention API, and storing a report never starts a Spry run.

        The body (`Content-Type: application/json`, no `Content-Encoding`
        other than `identity`, otherwise `415`) has exactly these keys:

        - `format` (`exunit-timings`), `workflow_run_id` (lowercase UUID of
          the workflow invocation), `workflow` and `job` (1 to 64 bytes, no
          control characters), `environment` (the same, or `null`) and
          `job_status` (`passed`, `failed`, `timed_out`, `cancelled`,
          `skipped` or `unknown`)
        - `source`: `commit` (40 or 64 hex characters), `branch` (up to 256
          bytes) and `dirty` (boolean), each nullable
        - `report`: `suite_id` and `report_id` (1 to 128 bytes of
          `[A-Za-z0-9._-]`, starting with a letter or digit; `report_id` is
          unique within a job), `partition` (1 to 64 bytes of `[A-Za-z0-9._-]`
          or `null`), `partition_count` (positive or `null`), `truncated`
          (whether collection dropped an invalid final line) and `records`
        - `records`: 1 to 100,000 producer events in original order, starting
          with the only `suite_started`; a `suite_finished`, if present, is
          last. Every event has `event`, `run_id` (= `suite_id`),
          `report_id` and `received_offset_us`. See `TestReportEvent` for the
          fields of `suite_started`, `test_started`, `test_finished`,
          `module_started`, `module_finished`, `suite_finished`,
          `max_failures_reached` and `interrupted`.

        Times are integer microseconds and are stored as sent; measured
        durations are never checked against receipt offsets. A finish event
        must match an earlier start with the same `execution_id` and fields.
        The `suite_finished` counts, file totals and `times_us` must agree
        with the finished events. Unknown or duplicate keys, strings
        containing U+0000, numbers with a fraction or exponent and integers
        beyond 2^53 - 1 are `422`. Logs, failure messages, assertion values
        and parameter values are not accepted. `422` bodies are keyed by JSON
        path (such as `report.records[3].duration_us`) with fixed messages
        that never repeat submitted values.

        Responses: `201` stored, `200` exact retry, `400` malformed JSON,
        `401`/`403` key errors, `404` unknown project, `406` when `Accept`
        excludes JSON, `409` a different report under the same identity,
        `413` a body over 32 MiB (33,554,432 bytes), `415`, `422`, and `503`
        with `Retry-After` when storage is unavailable or too many uploads
        are being read on the server.

        - **Identity and retries.** The project, `workflow_run_id`, `job` and
          `report_id` identify one immutable report. An exact retry (equal
          JSON ignoring object key order) returns `200` with the same `id`
          and `duplicate: true`; anything else is `409` and changes nothing.
          An incomplete report is never completed by a later upload. On
          `503` the report may or may not have been stored: retry the same
          frozen body.
        - **Per-report completeness.** `status` is `complete` only when the
          last record is `suite_finished` with `aborted` false and no
          unfinished tests or modules, no `interrupted` or
          `max_failures_reached` record appears and `truncated` is false;
          otherwise `incomplete`. Failed tests do not make a report
          incomplete, and one partition never says the whole workflow
          invocation completed.
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "API key",
            description: "`pk_…` (read-only) or `sk_…` (read-write)"
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    })
  end
end
