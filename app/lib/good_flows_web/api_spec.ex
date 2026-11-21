defmodule GoodFlowsWeb.ApiSpec do
  @moduledoc """
  OpenAPI 3 specification for the `/api/v1` JSON API, built from the
  router's `open_api_operation` annotations. Served at `/api/v1/openapi`
  with Swagger UI at `/api/v1/docs`.
  """
  @behaviour OpenApiSpex.OpenApi

  alias GoodFlows.TestReports.Validator
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
        - **Cache keys** (`ck_…`) are minted by a private key and work only on
          one project's cache routes (see **Caches**).

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
           has recipes, stored test reports, stored workflow runs or change
           requests cannot be deleted (`409`).
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

        ## Test reports

        `POST /api/v1/projects/{project}/test-reports` stores one
        `test-timings/1` report produced by goodflows (v0.6.0 or later) from
        a local or CI test run of any supported runner. It needs a
        private (`sk_…`) key, and the project must already exist: the path
        slug selects it (an invalid slug is `422` on `project`, a slug the
        account does not have is `404`). The body has no `project` or
        `account_id`. Authentication and the project are checked before the
        body is read. This is storage only: there is no read, query, grouping
        or retention API, and storing a report never starts a Spry run.

        The body (`Content-Type: application/json`, no `Content-Encoding`
        other than `identity`, otherwise `415`) has exactly these keys:

        - `format` (`test-timings/1`), `workflow_run_id` (lowercase UUID of
          the workflow invocation), `workflow` and `job` (1 to 64 bytes, no
          control characters), `environment` (the same, or `null`) and
          `job_status` (`passed`, `failed`, `timed_out`, `cancelled`,
          `skipped` or `unknown`)
        - `source`: `commit` (40 or 64 hex characters), `branch` (1 to 256
          bytes, no control characters) and `dirty` (boolean), each nullable
        - `report`: `suite_id` and `report_id` (1 to 128 bytes of
          `[A-Za-z0-9._-]`, starting with a letter or digit; `report_id` is
          unique within a job), `partition` (1 to 64 bytes of `[A-Za-z0-9._-]`
          or `null`), `partition_count` (positive or `null`), `truncated`
          (whether collection dropped an invalid final line) and `records`
        - `records`: 1 to 100,000 producer events in original order, starting
          with the only `suite_started`; a `suite_finished`, if present, is
          last. Every event has `event`, `suite_id` (= `report.suite_id`),
          `report_id` and `received_offset_us`. See `TestReportEvent` for the
          fields of `suite_started`, `group_started`, `group_finished`,
          `test_started`, `test_finished`, `suite_finished`, `interrupted`
          and `max_failures_reached`. Groups are the runner's scheduling
          unit (an ExUnit module, a Jest file); tests are identified by
          `group`, `path` (enclosing describe blocks) and `name`. Outcomes
          are `passed`, `failed`, `skipped` or `errored`.
        - Any record may carry `meta`: a flat object of at most
          #{Validator.max_meta_keys()} keys in the `suite_id` grammar whose
          values are `null`, booleans, integers or strings of at most
          #{Validator.max_meta_string_bytes()} bytes. Runner-specific details
          (versions, `async`, ExUnit time buckets) live there and are stored
          as sent. A bad `meta` is reported on that record's `meta` path
          without naming the key.
        - `suite_started` `filters` is `null` or `{include, exclude}`, whose
          entries are `{tag, value}`: `tag` uses the `suite_id` grammar and
          `value` is a boolean; each list has at most #{Validator.max_filters()} entries;
          non-boolean filters are not accepted.

        The server accepts exactly what goodflows collection accepts, so a
        report goodflows froze is never rejected by a server-only rule. Times
        are integer microseconds and are stored as sent; durations are never
        checked against receipt offsets or outcomes, `counts` are not
        tallied against test events (a retried test is written once per
        attempt and counted once), and `file` is any text. A finish event
        must match an earlier start of its kind (groups and tests are
        separate `execution_id` namespaces) with the same core fields, and
        the `suite_finished` unfinished counts must equal the starts left
        open. Any other envelope `format`, including a retired one, is a
        single `422` on `format`; any other `format` on a first
        `suite_started` record is a single `422` on
        `report.records[0].format`. Unknown or duplicate keys, strings
        containing U+0000, numbers with a fraction or exponent and integers
        beyond 2^53 - 1 (and `-0`, which goodflows reads as a fraction) are
        `422`. Beyond the event fields, only the flat `meta` scalars (strings
        of at most #{Validator.max_meta_string_bytes()} bytes) are stored;
        producers must not put logs, failure messages, assertion values or
        parameter values there. `422` bodies are keyed by JSON
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
          unfinished tests or groups, no `interrupted` or
          `max_failures_reached` record appears and `truncated` is false;
          otherwise `incomplete`. Failed or errored tests do not make a report
          incomplete, and one partition never says the whole workflow
          invocation completed.

        ## Workflow runs

        `POST /api/v1/projects/{project}/workflow-runs` stores one goodflows
        run-history document (`schema_version` 1) for a project that already
        exists. It needs a private (`sk_…`) key. A public key is `403`.
        Authentication and the project are resolved before the body is read:
        a missing, expired or revoked key is `401`, an invalid slug is `422`
        on `project`, and an unknown slug is `404`.

        The body is the document itself (`Content-Type: application/json`,
        no `Content-Encoding` other than `identity`). It has no `project` or
        `account_id`. Optional keys are omitted, not null. Nullable keys,
        such as a result's `command`, `exit_code` and `error`, are always
        present and may be null. The CLI upload envelope adds optional
        `source.branch`, `ci` (GitHub Actions context) and `graph` (the job
        graph that `graph_sha256` hashes, at most 1,024 jobs). Graph job
        names are unique, dependencies are known and acyclic, every result
        `name` is a graph job, and a called workflow is referenced by
        `call.graph_sha256`, never inlined.
        An optional `links` object names the agent threads and tickets
        behind the run: `threads` (1 to 32 unique `https` thread URLs) and
        `tickets` (1 to 32 IDs of 1 to 64 bytes of printable ASCII other
        than `,`, unique ignoring ASCII case), at least one of them. A
        thread URL has no userinfo, query or fragment, only RFC 3986
        `pchar` and `/` in its path, and must already be in the form
        `reqwest::Url` serializes (lowercase host, no explicit or empty 443
        port, a nonempty path, no dot segments, percent triplets as
        written); otherwise it is `422` with `must be normalized`. Links are
        stored as sent.
        Objects and arrays nested more than 8 levels deep, duplicate keys,
        U+0000, non-integer numbers and integers beyond 2^53 - 1 are `422`.
        The body limit is 4 MiB (4,194,304 bytes) and the read deadline is
        30 seconds (`413` and `408`).

        The account, project and run id identify one immutable run. The
        first upload is `201`. An exact retry (equal JSON, object key order
        ignored) is `200` with the same server id and `duplicate: true`.
        Any other document under that identity is `409` and does not reveal
        the stored id or document. Acknowledgements return only `id`,
        `run_id` and `duplicate`. On `503` the run may or may not be stored:
        retry the same body. A lost commit that left a row resolves as `200`
        on that retry.

        `GET /api/v1/projects/{project}/workflow-runs` lists summaries for
        any valid key, newest `started_at` first, breaking ties by run id
        descending. Pages use keyset pagination (`limit` 1 to 200, default
        50, and `cursor`). Filters `workflow`, `environment`, `outcome`,
        `commit`, `branch` (`source.branch`), `event` (`ci.event`) and
        `graph_sha256` are exact and combined with AND.
        `ticket` matches a run's `links.tickets` ignoring ASCII case.
        `thread_url` is normalized (lowercase scheme and host, an empty or
        443 port dropped, `/` for an empty path, percent triplets kept as
        written) and then matches one of a run's `links.threads` exactly.
        Every key type, including public keys, can use both.
        Unknown query parameters are ignored. A filter, `limit` or `cursor`
        that breaks its rule is `422`. Summaries do not include `results`
        or `links`.

        `GET /api/v1/projects/{project}/workflow-runs/{run_id}` returns the
        stored document. The run id must be a lowercase canonical UUID; any
        other spelling, including uppercase, is `404` and is not looked up
        after downcasing. A public (`pk_…`) key sees each result's `command`
        and `error`, and each graph job's and step's `command` and condition
        `text`, as null, and `links.threads` as null when the run has
        threads (`links.tickets` is unchanged, and a `links` without
        threads gains no `threads` key); the stored row is not changed.
        Private keys see them as stored. `test_reports` lists test reports
        in the same account and project whose `workflow_run_id` equals this
        run, ordered by `job`
        then `report_id`, without report contents. There is no foreign key
        either way: reports often arrive before the run, and either side may
        be absent.

        ## Change requests

        `/api/v1/projects/{project}/change-requests` replaces pull requests.
        The server never talks to a Git host: clients report facts, the
        server applies the project's review policy and holds the verdict,
        and clients act on it, including the merge.

        A change request is opened as `draft` with the project's next
        `number` and moves through `draft`, `open`, `closed` and `merged`
        (terminal). For each head a client reports one `git-facts/1`
        document (`POST …/git-facts`) and uploads one `change-claims/2`
        Markdown file with YAML front matter (`POST …/claims`,
        `text/markdown`). The verdict (`GET …/verdict`) is `pending`,
        `blocked`, `needs_review` or `mergeable`, with one reason per rule
        that fired, the `head` and the `policy_version`; act on it only
        while both are current. `POST …/merged` records the merge and the
        verdict at the head, flagging a merge without a `mergeable`
        verdict rather than rejecting it.

        `/api/v1/projects/{project}/review-policy` holds the versioned
        `review-policy/1` document. Version 0 is the default. Any `sk_…` or
        `pk_…` key reads it; only private keys of owners and admins write a
        new version, naming the version they replace.

        Private keys of any role write change requests. Public keys read
        them with user ids, thread links, descriptions, claims documents,
        file lists and reason subjects and messages redacted to null.
        Write bodies are strict JSON (claims: Markdown) read after
        authentication: `413`, `415`, `400` and `422` as for workflow runs.

        ## Caches

        `/api/v1/projects/{project}/caches` is a remote store for goodflows
        job caches. Archive bytes never pass through this API: it hands out
        presigned URLs for an S3-compatible bucket. When the server has no
        bucket configured, every cache route responds `503` (treat it as a
        miss or a skipped save); the cache-key routes keep working.

        **Scopes.** Entries are immutable and keyed per project and *scope*.
        A scope is an opaque label of 1 to 256 bytes with no control
        characters, usually a branch name; it is not validated as a Git ref
        and is compared byte for byte. The project's `default_branch`
        (default `main`, changed with `PATCH /api/v1/projects/{project}`)
        names the fallback scope. A lookup with `scope` reads that scope and
        then the default-branch scope; without `scope` it reads only the
        default-branch scope. No other scope is ever read. `key`, `partial`
        and `sha256` are 64 lowercase hex characters.

        **Saving.** `POST …/caches/entries/{key}` reserves the key in one
        scope (`409` if it is committed or reserved there) and returns an
        `upload_id`, an `upload_url` and `upload_headers`. PUT the archive to
        `upload_url` sending exactly `upload_headers`
        (`content-length`, `content-type: application/gzip`,
        `x-amz-checksum-sha256`); they are signed into the URL, so the bucket
        rejects a body whose size or SHA-256 differs. Then
        `POST …/caches/uploads/{upload_id}/commit`: the server checks the
        stored object and makes the entry visible (`422` on `upload`
        otherwise). Entries are 1 byte to 5,000,000,000 bytes (`413` above).
        A project's committed entries and unexpired reservations share a
        byte quota (50 GiB by default) and an entry cap (10,000): a
        reservation that does not fit evicts the least recently used
        entries, and `507` means unexpired reservations fill the quota.
        Entries not restored for 7 days are deleted.

        **Multipart saves.** A reservation may add `parts`, `{"size": <part
        size>, "md5": [<base64 MD5 of each part>, …]}` (part size 5 MiB to
        5 GiB, one MD5 per part, at most 10,000 parts). The response then
        has `upload_parts`, `[{"number", "url", "headers"}]`, instead of
        `upload_url` and `upload_headers`: PUT each part to its `url` with
        exactly its `headers` (`content-length`, `content-md5`) and no
        `Authorization`, in parallel if you like, before
        `upload_url_expires_at` (the reservation's lifetime). Commit as
        usual; the server lists the parts itself, checks them against the
        declared MD5s and sizes, completes the upload and checks the
        object. Missing or wrong parts are `422` on `upload` and abort the
        upload. Commit can take up to about two minutes for many parts. The
        store cannot verify a multipart entry's `sha256`: it is the value
        sent at reserve, so restoring clients must check it.

        **Restoring.** `GET …/caches/entries/{key}` restores an exact key and
        `GET …/caches/entries?partial=` the newest entry with that partial.
        A hit returns metadata and a `download_url`.

        **Presigned URLs are bearer credentials.** Never send your
        `Authorization` header to `upload_url` or `download_url`: they are on
        another origin and carry their own signature. Do not log them. Verify
        a downloaded archive against `sha256` before unpacking it.

        **Keys.** Private keys can do everything, including listing
        (`GET …/caches`) and purging (`DELETE …/caches/entries/{key}?scope=`
        and `DELETE …/caches/entries?name=&scope=&partial=`). Public keys get
        `403` on every cache route. `POST /api/v1/projects/{project}/cache-keys`
        (private keys only) mints a `ck_…` key with `read` or `read_write`
        access, optionally bound to one `scope`; `GET` lists active ones and
        `DELETE …/cache-keys/{id}` revokes one. A cache key works only on its
        project's lookup, reserve and commit routes and gets `403` everywhere
        else. Unbound, it reads any scope (and a `read_write` key writes any
        scope). Bound to scope `B`, it reads only `B`, the default-branch
        scope, or without `scope`, and a `read_write` key writes only `B`.
        `read_write` keys expire within 24 hours; `read` keys may last up to a
        year or, with `"ttl_seconds": null` and a `name`, never expire. The
        default lifetime is 6 hours.
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "API key",
            description:
              "`pk_…` (read-only), `sk_…` (read-write) or `ck_…` (cache routes of one project)"
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    })
  end
end
