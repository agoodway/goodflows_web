defmodule GoodFlowsWeb.Api.V1.PoolWorkspaceController do
  @moduledoc """
  `PUT /api/v1/pool-sessions/:id/workspace`: the session's working tree as
  one gzip-compressed tar body, at most once per session.

  The endpoint leaves this route unparsed
  (`GoodFlowsWeb.Plugs.BodyParsers.raw_body_route?/1`), so the body is read
  here, after authentication and session ownership (`404` for another
  account, `403` for another key). Then, in order, like
  `GoodFlowsWeb.Plugs.TestReportBody`:

    1. `415` unless `Content-Type` is `application/gzip` and
       `Content-Encoding` is absent or `identity`
    2. `413` when the declared `Content-Length` exceeds the limit, before
       any reservation
    3. admission on the session coordinator (`GoodFlows.Pools.SessionCoordinator`,
       on whichever node owns the session): `409` when the session ended,
       already has a workspace, or another upload to it is in progress;
       `503` with `Retry-After` when the node spool budget or the
       per-account concurrent-upload cap is exhausted
    4. the body is streamed in chunks of at most 1 MiB to the coordinator's
       disk spool through bounded owner calls, against one overall read
       deadline: `408` once it passes, `413` as soon as more than the limit
       arrived, `400` when the body cannot be read (a broken connection or
       malformed chunked encoding), `503` with `Retry-After` when the
       session's owner becomes unavailable meanwhile; each releases the
       reservation and leaves the upload retryable
    5. archive preflight (`GoodFlows.Pools.Archive`): `422` for a corrupt or
       non-confined archive, `413` for expansion, entry, or time limits;
       both leave the session without a workspace, so a corrected upload is
       accepted

  `204` once the archive is recorded; members are hydrated in the
  background and announced with `member_ready` on the session channel.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Pools.{Config, OwnerRPC, Sessions}
  alias GoodFlowsWeb.{FallbackController, RawBodyHeaders}
  alias GoodFlowsWeb.Schemas.{ErrorResponse, ValidationErrorResponse}
  alias Plug.Conn.Utils

  action_fallback FallbackController

  tags(["Pools"])

  @chunk_bytes 1_048_576

  operation(:update,
    summary: "Upload a session's workspace",
    description: """
    Body: the working tree as a gzip-compressed tar (`Content-Type:
    application/gzip`), at most 256 MiB by default. Accepted once per
    session; it is extracted into `/workspace` of every member granted to
    the session, including later grants. Archives with absolute paths, `..`
    segments, special files, or links escaping the workspace are `422`.
    """,
    parameters: [id: [in: :path, type: :string, description: "Session ID", required: true]],
    request_body:
      {"gzip-compressed tar", "application/gzip",
       %OpenApiSpex.Schema{type: :string, format: :binary}, required: true},
    responses: [
      no_content: "Uploaded and validated",
      bad_request: {"The body could not be read", "application/json", ErrorResponse},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Another key created the session", "application/json", ErrorResponse},
      not_found: {"No such session in this account", "application/json", ErrorResponse},
      request_timeout: {"The body was not received in time", "application/json", ErrorResponse},
      conflict:
        {"Ended session, workspace already uploaded, or an upload in progress",
         "application/json", ErrorResponse},
      request_entity_too_large:
        {"Body or expanded archive over the limits", "application/json", ErrorResponse},
      unsupported_media_type:
        {"Not application/gzip, or a Content-Encoding other than identity", "application/json",
         ErrorResponse},
      unprocessable_entity:
        {"Corrupt or non-confined archive", "application/json", ValidationErrorResponse},
      service_unavailable:
        {"Spool budget or upload cap exhausted, owner unavailable, or pools disabled",
         "application/json", ErrorResponse}
    ]
  )

  @doc "Receives the workspace archive."
  def update(conn, %{"id" => id}) do
    %{current_account: account, current_api_key: key} = conn.assigns
    limit = Config.workspace_max_bytes()

    with {:ok, session} <- Sessions.get_owned(account, key, id),
         :ok <- check_content_type(conn),
         :ok <- RawBodyHeaders.check_content_encoding(conn),
         :ok <- RawBodyHeaders.check_declared_length(conn, limit),
         :ok <- check_open(session),
         {:ok, ref} <- admit(session) do
      deadline = System.monotonic_time(:millisecond) + Config.workspace_read_timeout_ms()

      case stream_body(conn, session.owner_id, ref, deadline) do
        {:ok, conn} -> finish(conn, session.owner_id, ref)
        {:error, conn, reason} -> abort(conn, session.owner_id, ref, reason)
      end
    else
      {:error, reason} -> respond(conn, reason)
    end
  end

  defp check_content_type(conn) do
    with [header] <- get_req_header(conn, "content-type"),
         {:ok, "application", "gzip", params} when map_size(params) == 0 <-
           Utils.content_type(header) do
      :ok
    else
      _other -> {:error, :unsupported_media_type}
    end
  end

  defp check_open(session) do
    cond do
      session.status not in ["waiting", "active"] -> {:error, :session_ended}
      session.workspace_uploaded_at -> {:error, :already_uploaded}
      true -> :ok
    end
  end

  defp admit(session) do
    case OwnerRPC.call(session.owner_id, {:upload_begin, self()}) do
      {:ok, ref} -> {:ok, ref}
      {:error, :busy} -> {:error, :busy}
      {:error, reason} when reason in [:already_uploaded, :upload_in_progress] -> {:error, reason}
      {:error, :owner_lost} -> {:error, :session_ended}
      _unavailable -> {:error, :owner_unavailable}
    end
  end

  defp stream_body(conn, owner_id, ref, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, conn, :timeout}
    else
      opts = [length: @chunk_bytes, read_length: @chunk_bytes, read_timeout: remaining]

      conn |> read_body(opts) |> forward_chunk(conn, owner_id, ref, deadline)
    end
  rescue
    _error -> {:error, conn, :unreadable}
  end

  defp forward_chunk({tag, data, conn}, _conn, owner_id, ref, deadline)
       when tag in [:ok, :more] do
    case forward(owner_id, ref, data) do
      :ok when tag == :ok -> {:ok, conn}
      :ok -> stream_body(conn, owner_id, ref, deadline)
      {:error, reason} -> {:error, conn, reason}
    end
  end

  defp forward_chunk({:error, :timeout}, conn, _owner_id, _ref, _deadline),
    do: {:error, conn, :timeout}

  defp forward_chunk({:error, _reason}, conn, _owner_id, _ref, _deadline),
    do: {:error, conn, :unreadable}

  defp forward(_owner_id, _ref, ""), do: :ok

  defp forward(owner_id, ref, data) do
    case OwnerRPC.call(owner_id, {:upload_chunk, ref, data}) do
      :ok -> :ok
      {:error, :too_large} -> {:error, :too_large}
      _other -> {:error, :owner_unavailable}
    end
  end

  defp finish(conn, owner_id, ref) do
    timeout = Config.archive_validation_timeout_ms() + Config.owner_rpc_timeout_ms()

    case OwnerRPC.call(owner_id, {:upload_finish, ref}, timeout) do
      :ok ->
        send_resp(conn, :no_content, "")

      {:error, {kind, message}} when kind in [:invalid, :too_large] ->
        respond(conn, {kind, message})

      {:error, :session_ended} ->
        respond(conn, :session_ended)

      _other ->
        abort(conn, owner_id, ref, :owner_unavailable)
    end
  end

  defp abort(conn, owner_id, ref, reason) do
    # too_large aborted the upload on the owner already; abort is idempotent.
    _ = OwnerRPC.call(owner_id, {:upload_abort, ref})
    respond(conn, reason)
  end

  defp respond(conn, {:invalid, message}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{"body" => [message]}})
  end

  defp respond(conn, {:too_large, message}) do
    conn
    |> put_status(:request_entity_too_large)
    |> json(%{errors: %{detail: message}})
  end

  defp respond(conn, reason) when reason in [:not_found, :forbidden],
    do: FallbackController.call(conn, {:error, reason})

  defp respond(conn, reason) do
    {status, detail} = error(reason)

    conn
    |> then(&if status == 503, do: put_resp_header(&1, "retry-after", "1"), else: &1)
    |> put_status(status)
    |> json(%{errors: %{detail: detail}})
  end

  defp error(:unsupported_media_type), do: {415, "Content-Type must be application/gzip"}
  defp error(:unsupported_encoding), do: {415, "Content-Encoding must be absent or identity"}
  defp error(:too_large), do: {413, "The workspace exceeds the size limit"}
  defp error(:session_ended), do: {409, "The session has ended"}
  defp error(:already_uploaded), do: {409, "The session already has a workspace"}

  defp error(:upload_in_progress),
    do: {409, "Another workspace upload to this session is in progress"}

  defp error(:busy), do: {503, "Too many workspace uploads in progress; retry later"}
  defp error(:owner_unavailable), do: {503, "The session's owner is unavailable; retry later"}
  defp error(:timeout), do: {408, "The workspace was not received in time"}
  defp error(:unreadable), do: {400, "The workspace body could not be read"}
end
