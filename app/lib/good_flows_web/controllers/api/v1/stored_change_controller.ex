defmodule GoodFlowsWeb.Api.V1.StoredChangeController do
  @moduledoc """
  Stored goodflows changes under `/api/v1/projects/:project/changes`.

  Any `sk_` key of the account pushes, reads and deletes (project write
  pipeline for push and delete). `pk_` keys list changes and versions,
  with the pusher null; a `pk_` read of a change or a version is `403`
  whether or not the id exists. `ck_` keys are `403`. The push body is
  strict JSON read after the project is resolved, up to 16 MiB.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.StoredChanges
  alias GoodFlows.StoredChanges.Push
  alias GoodFlowsWeb.ApiParams
  alias GoodFlowsWeb.Plugs.{JsonBody, LoadChangeRequest}

  alias GoodFlowsWeb.Schemas.{
    ErrorResponse,
    StoredChangeArchivedResponse,
    StoredChangeLinkedResponse,
    StoredChangeListResponse,
    StoredChangePushRequest,
    StoredChangePushResponse,
    StoredChangeResponse,
    StoredChangeVersionListResponse,
    StoredChangeVersionResponse,
    ValidationErrorResponse
  }

  plug JsonBody,
       [
         limit: :stored_change_max_body_bytes,
         default: 16_777_216,
         errors: {Push, :json_errors}
       ]
       when action in [:create]

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Stored changes"])

  @unauthorized {"Missing, expired or revoked API key", "application/json", ErrorResponse}
  @not_acceptable {"`Accept` does not allow JSON", "application/json", ErrorResponse}
  @slug {"Invalid project slug", "application/json", ValidationErrorResponse}
  @content_forbidden {"Public keys (for any id) and cache keys", "application/json",
                      ErrorResponse}
  @change_id [
    change_id: [in: :path, type: :string, description: "The change id", required: true]
  ]

  operation(:create,
    summary: "Push a stored change",
    description: """
    Stores the files of a goodflows change as its next version (`201`), taking the id from
    `change.md`'s front matter. A push whose paths and every file's bytes equal the latest
    version stores nothing and answers `200` with `duplicate` true and that version, whose
    `source` is the push that created it. `replaced_version` is the version that was latest
    before the push: null for a new change, the latest version for a duplicate.

    Only what the server relies on is checked (`422`, storing nothing): the body has exactly
    `files` and `source`; every path is a file of a goodflows change; at most 100 files and
    2,097,152 bytes of text; no U+0000; `change.md` has `format` `goodflows-change/1`, an
    `id` of 1 to 64 bytes matching `[a-z0-9][a-z0-9-]*` and a `status` of `proposed`,
    `approved` or `archived`; and `qa-scenarios.md`, when present, passes the scenario-set
    front matter check with `source` `intent` and `change` equal to the id. A change whose
    latest version is `archived` takes no other push (`409`). Refusals are answered in the
    order `413`, `422`, `409`. Any private key may push.
    """,
    parameters: ApiParams.project(),
    request_body:
      {"Files and source", "application/json", StoredChangePushRequest, required: true},
    responses: [
      created: {"New version", "application/json", StoredChangePushResponse},
      ok: {"Identical to the latest version", "application/json", StoredChangePushResponse},
      bad_request: {"Malformed JSON or unreadable body", "application/json", ErrorResponse},
      unauthorized: @unauthorized,
      forbidden: {"Public or cache keys", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      request_timeout: {"Body was not received in time", "application/json", ErrorResponse},
      conflict:
        {"The change's latest version is archived", "application/json",
         StoredChangeArchivedResponse},
      request_entity_too_large: {"Body exceeds 16 MiB", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not `application/json`, or a `Content-Encoding` other than `identity`",
         "application/json", ErrorResponse},
      unprocessable_entity:
        {"Invalid body, path, limit, change.md or qa-scenarios.md, or project slug",
         "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Pushes a stored change."
  def create(conn, _params) do
    %{project: project, current_api_key: api_key} = conn.assigns

    with {:ok, status, version, replaced} <-
           StoredChanges.push(project, api_key, conn.private.json_body) do
      conn
      |> put_status(if(status == :created, do: :created, else: :ok))
      |> render(:push, version: version, duplicate: status == :duplicate, replaced: replaced)
    end
  end

  operation(:index,
    summary: "List stored changes",
    description:
      "By latest version, newest latest push first, ties by id. Each row lists the project's " <>
        "change requests whose `change_id` is the row's id, by number. Public keys may list.",
    parameters:
      ApiParams.project() ++
        ApiParams.version_page() ++
        [
          status: [
            in: :query,
            schema: %OpenApiSpex.Schema{type: :string, enum: Push.statuses()},
            description: "Matched against the latest version",
            required: false
          ]
        ],
    responses: [
      ok: {"One page of changes", "application/json", StoredChangeListResponse},
      unauthorized: @unauthorized,
      forbidden: {"Cache keys", "application/json", ErrorResponse},
      not_found: {"No such project in this account", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid limit, cursor, status or project slug", "application/json",
         ValidationErrorResponse}
    ]
  )

  @doc "Lists stored changes."
  def index(conn, params) do
    with {:ok, page} <-
           StoredChanges.list(conn.assigns.project, Map.take(params, ~w(limit cursor status))) do
      render(conn, :index,
        changes: page.changes,
        change_requests: page.change_requests,
        next_cursor: page.next_cursor
      )
    end
  end

  operation(:show,
    summary: "Show a stored change",
    description:
      "The latest version with every file and the project's change requests whose " <>
        "`change_id` is the id. Private keys only.",
    parameters: ApiParams.project() ++ @change_id,
    responses: [
      ok: {"The latest version", "application/json", StoredChangeResponse},
      unauthorized: @unauthorized,
      forbidden: @content_forbidden,
      not_found: {"No such project or change", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity: @slug
    ]
  )

  @doc "Shows a stored change."
  def show(conn, %{"change_id" => change_id}) do
    with :ok <- require_private(conn),
         {:ok, found} <- conn.assigns.project |> StoredChanges.get(change_id) |> named(change_id) do
      render(conn, :show, version: found.version, change_requests: found.change_requests)
    end
  end

  operation(:versions,
    summary: "List a stored change's versions",
    description:
      "Newest first, without files. Public keys may list, and see only `version`, `status`, " <>
        "`pushed_at`, `source`, `latest` and `pushed_by` null.",
    parameters: ApiParams.project() ++ @change_id ++ ApiParams.version_page(),
    responses: [
      ok: {"One page of versions", "application/json", StoredChangeVersionListResponse},
      unauthorized: @unauthorized,
      forbidden: {"Cache keys", "application/json", ErrorResponse},
      not_found: {"No such project or change", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity:
        {"Invalid limit, cursor or project slug", "application/json", ValidationErrorResponse}
    ]
  )

  @doc "Lists versions."
  def versions(conn, %{"change_id" => change_id} = params) do
    with {:ok, page} <-
           conn.assigns.project
           |> StoredChanges.list_versions(change_id, Map.take(params, ~w(limit cursor)))
           |> named(change_id) do
      render(conn, :versions,
        versions: page.versions,
        next_cursor: page.next_cursor,
        redact?: not ApiKey.can_write?(conn.assigns.current_api_key)
      )
    end
  end

  operation(:show_version,
    summary: "Show a stored change version",
    description:
      "Version `n` with its files and the change's `latest_status`. Private keys only.",
    parameters:
      ApiParams.project() ++
        @change_id ++
        [n: [in: :path, type: :integer, description: "Version number", required: true]],
    responses: [
      ok: {"The version", "application/json", StoredChangeVersionResponse},
      unauthorized: @unauthorized,
      forbidden: @content_forbidden,
      not_found: {"No such project, change or version", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      unprocessable_entity: @slug
    ]
  )

  @doc "Shows one version."
  def show_version(conn, %{"change_id" => change_id, "n" => n}) do
    with :ok <- require_private(conn),
         {:ok, version} <- find_version(conn.assigns.project, change_id, n) do
      render(conn, :show_version, version: version)
    end
  end

  operation(:delete,
    summary: "Delete a stored change",
    description:
      "Deletes the change and every version (`204`). Refused with `409`, listing them, " <>
        "while any change request of the project, in any state, has the id as `change_id`.",
    parameters: ApiParams.project() ++ @change_id,
    responses: [
      no_content: "Deleted",
      unauthorized: @unauthorized,
      forbidden: {"Public or cache keys", "application/json", ErrorResponse},
      not_found: {"No such project or change", "application/json", ErrorResponse},
      not_acceptable: @not_acceptable,
      conflict:
        {"Change requests link the change", "application/json", StoredChangeLinkedResponse},
      unprocessable_entity: @slug
    ]
  )

  @doc "Deletes a stored change."
  def delete(conn, %{"change_id" => change_id}) do
    %{project: project, current_api_key: api_key} = conn.assigns

    with :ok <- project |> StoredChanges.delete(api_key, change_id) |> named(change_id) do
      send_resp(conn, :no_content, "")
    end
  end

  defp require_private(conn) do
    if ApiKey.can_write?(conn.assigns.current_api_key) do
      :ok
    else
      {:error,
       {:forbidden,
        "Public (pk_) keys cannot read a stored change or one of its versions; " <>
          "use a private (sk_) key, or list the changes and their versions"}}
    end
  end

  defp find_version(project, change_id, n) do
    result =
      case LoadChangeRequest.parse(n) do
        {:ok, number} ->
          StoredChanges.get_version(project, change_id, number)

        :invalid ->
          with {:ok, _found} <- StoredChanges.get(project, change_id),
               do: {:error, :version_not_found}
      end

    case named(result, change_id) do
      {:error, :version_not_found} -> no_version(change_id, n)
      other -> other
    end
  end

  defp no_version(change_id, n) do
    {:error,
     {:not_found,
      "#{change_id} has no version #{n}; list its versions to find the version numbers"}}
  end

  defp named({:error, :not_found}, change_id) do
    {:error,
     {:not_found,
      "No stored change #{change_id} in this project; list the project's changes to find its id"}}
  end

  defp named(result, _change_id), do: result
end
