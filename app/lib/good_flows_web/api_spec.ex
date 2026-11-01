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
           has recipes cannot be deleted (`409`).
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
