defmodule GoodFlowsWeb.Plugs.JsonBody do
  @moduledoc """
  Reads a strict JSON body for change request and review policy writes,
  after authentication and project (and change request) resolution. The
  endpoint leaves these routes unparsed
  (`GoodFlowsWeb.Plugs.BodyParsers.strict_json_route?/1`).

      plug JsonBody, limit: :change_request_max_body_bytes, default: 65_536

  The rules follow workflow-run uploads: `415` unless `Content-Type` is
  `application/json` (optionally `charset=utf-8`) with no `Content-Encoding`
  other than `identity`; `413` when the declared `Content-Length` or the
  bytes read exceed the limit (`config :good_flows, <limit>`, read on every
  request, falling back to `default`); `408` past the read deadline
  (`:change_request_read_timeout_ms`, default 30,000); `400` for an
  unreadable body or malformed JSON; and `422` on `body` for nesting deeper
  than 8 levels, duplicate keys, U+0000 or integers beyond ±(2^53 - 1).
  Messages are fixed and never echo the body.

  The normalized document is stored at `:json_body` in `conn.private`.
  """
  @behaviour Plug

  import Plug.Conn

  alias GoodFlows.JsonDocument
  alias GoodFlowsWeb.{RawBody, RawBodyHeaders}

  @max_depth 8
  @default_read_timeout_ms 30_000

  @impl Plug
  def init(opts), do: Keyword.validate!(opts, [:limit, :default])

  @impl Plug
  def call(conn, opts) do
    limit = Application.get_env(:good_flows, opts[:limit], opts[:default])

    with :ok <- RawBodyHeaders.check_json_content_type(conn),
         :ok <- RawBodyHeaders.check_content_encoding(conn),
         :ok <- RawBodyHeaders.check_declared_length(conn, limit) do
      read(conn, limit)
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  @doc "The overall body read deadline in milliseconds."
  @spec read_timeout_ms() :: pos_integer()
  def read_timeout_ms,
    do:
      Application.get_env(:good_flows, :change_request_read_timeout_ms, @default_read_timeout_ms)

  defp read(conn, limit) do
    deadline = System.monotonic_time(:millisecond) + read_timeout_ms()

    case RawBody.read(conn, limit, deadline) do
      {:ok, conn, body} -> decode(conn, body)
      {:error, conn, reason} -> reject(conn, reason)
    end
  end

  defp decode(conn, body) do
    with :ok <- JsonDocument.check_depth(body, @max_depth),
         {:ok, decoded} <- JsonDocument.decode(body),
         {:ok, document} <- JsonDocument.normalize(decoded) do
      put_private(conn, :json_body, document)
    else
      {:error, :too_deep} ->
        reject(conn, {:invalid, ["is nested too deeply"]})

      {:error, :malformed_json} ->
        reject(conn, :malformed_json)

      {:error, errors} ->
        reject(conn, {:invalid, errors |> Enum.map(&elem(&1, 1)) |> Enum.uniq()})
    end
  end

  defp reject(conn, {:invalid, messages}),
    do: send_json(conn, 422, %{errors: %{"body" => messages}})

  defp reject(conn, reason) do
    {status, detail} = error(reason)
    send_json(conn, status, %{errors: %{detail: detail}})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end

  defp error(:unsupported_media_type),
    do: {415, "Content-Type must be application/json (charset utf-8)"}

  defp error(:unsupported_encoding), do: {415, "Content-Encoding must be absent or identity"}
  defp error(:too_large), do: {413, "Body exceeds the size limit"}
  defp error(:timeout), do: {408, "Body was not received in time"}
  defp error(:unreadable), do: {400, "Body could not be read"}
  defp error(:malformed_json), do: {400, "Body is not valid JSON"}
end
