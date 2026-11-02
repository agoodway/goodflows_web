defmodule GoodFlowsWeb.Api.V1.PoolReportController do
  @moduledoc """
  `GET /api/v1/pool-execs/:id/reports/:name`: one test report file listed
  in an exec's manifest, for the session's creating key.

  The report is fetched from the member by the session coordinator into a
  verified disk spool (`GoodFlows.Pools.Transfers.fetch_report/5`, resumable
  against an immutable snapshot); concurrent requests share one transfer.
  On the coordinator's node the spool file is sent directly; on any other
  node the verified bytes are streamed in bounded owner calls. `404` for an
  unlisted, `too_large`, no longer regular, or oversized name; `410` once
  the member has started another exec or been released; `503` with
  `Retry-After` when the report is not ready within the fetch wait, the
  transfer capacity is saturated, or the transfer failed (the report stays
  eligible, so a retry reuses its progress). The route's pipeline does not
  restrict `Accept`, so `application/x-ndjson` is accepted. There is no
  HTTP Range support.

  Every `200` carries `x-content-sha256`, the verified lowercase hex
  SHA-256 of the whole file, so a client can detect a truncated body. When
  a remote stream is invalidated after its headers were sent, the request
  process exits with `{:shutdown, :report_invalidated}`, which drops the
  connection without the terminating chunk: the client sees an incomplete
  response, never a short `200`.
  """
  use GoodFlowsWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias GoodFlows.Pools.{Config, Exec, Execs, OwnerRPC, Sessions}
  alias GoodFlows.Spry.Executions
  alias GoodFlowsWeb.Schemas.ErrorResponse

  action_fallback GoodFlowsWeb.FallbackController

  tags(["Pools"])

  @read_chunk 1_048_576

  operation(:show,
    summary: "Download an exec's test report",
    parameters: [
      id: [in: :path, type: :string, description: "Exec ID", required: true],
      name: [
        in: :path,
        type: :string,
        description: "Report file name from the exit manifest",
        required: true
      ]
    ],
    responses: [
      ok:
        {"The report (NDJSON). The `x-content-sha256` header carries the file's SHA-256 (hex).",
         "application/x-ndjson", %OpenApiSpex.Schema{type: :string}},
      unauthorized: {"Missing or invalid API key", "application/json", ErrorResponse},
      forbidden: {"Another key created the session", "application/json", ErrorResponse},
      not_found:
        {"No such exec, or the name is unlisted, too large, or no longer a regular file",
         "application/json", ErrorResponse},
      gone:
        {"The member started another exec or was released", "application/json", ErrorResponse},
      service_unavailable:
        {"Not ready within the fetch wait, transfer capacity saturated, or transfer failed",
         "application/json", ErrorResponse}
    ]
  )

  @doc "Streams one report file."
  def show(conn, %{"id" => id, "name" => name}) do
    %{current_account: account, current_api_key: key} = conn.assigns

    with {:ok, exec} <- Execs.get(account.id, id),
         {:ok, session} <- Sessions.get_owned(account, key, exec.session_id),
         :ok <- listed(exec, name) do
      case OwnerRPC.call(
             session.owner_id,
             {:fetch_report, exec.id, name},
             Config.report_fetch_timeout_ms()
           ) do
        {:ok, report} -> serve(conn, session.owner_id, exec, name, report)
        {:error, :gone} -> gone(conn)
        {:error, :owner_lost} -> gone(conn)
        {:error, :not_found} -> {:error, :not_found}
        {:error, _busy_or_failed} -> unavailable(conn)
      end
    end
  end

  defp listed(%Exec{} = exec, name) do
    case Enum.find(Exec.report_files(exec), &(&1["name"] == name)) do
      %{"too_large" => false} -> :ok
      _other -> {:error, :not_found}
    end
  end

  # report.path is the coordinator's verified spool file (spool root + session and exec
  # UUIDs + sha256-derived key); the user-supplied report name is never a local path.
  # sobelow_skip ["Traversal.SendFile"]
  defp serve(conn, owner_id, exec, name, report) do
    conn =
      conn
      |> put_resp_content_type("application/x-ndjson", nil)
      |> put_resp_header("x-content-sha256", report.sha256)

    if Executions.local_owner?(owner_id) do
      send_file(conn, 200, report.path)
    else
      conn = send_chunked(conn, 200)
      stream_remote(conn, owner_id, exec.id, name, 0, report.size)
    end
  end

  defp stream_remote(conn, _owner_id, _exec_id, _name, offset, size) when offset >= size, do: conn

  defp stream_remote(conn, owner_id, exec_id, name, offset, size) do
    case OwnerRPC.call(owner_id, {:read_report, exec_id, name, offset, @read_chunk}) do
      {:ok, data} when byte_size(data) > 0 ->
        case chunk(conn, data) do
          {:ok, conn} ->
            stream_remote(conn, owner_id, exec_id, name, offset + byte_size(data), size)

          {:error, _closed} ->
            conn
        end

      _invalidated ->
        # Headers are sent: drop the connection rather than end the chunked
        # body cleanly, so the truncation cannot pass for a complete 200.
        exit({:shutdown, :report_invalidated})
    end
  end

  defp gone(conn) do
    conn
    |> put_status(:gone)
    |> json(%{
      errors: %{
        detail: "The report is no longer available: the member ran another exec or was released"
      }
    })
  end

  defp unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> put_resp_header("retry-after", "1")
    |> json(%{errors: %{detail: "The report is not ready yet; retry the request"}})
  end
end
