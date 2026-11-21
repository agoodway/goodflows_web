defmodule GoodFlowsWeb.Plugs.MarkdownBody do
  @moduledoc """
  Reads a claims upload body (`Content-Type: text/markdown`, optionally
  `charset=utf-8`) after authentication and change request resolution.

  `415` for any other `Content-Type` or a `Content-Encoding` other than
  `identity`; `413` over the limit (`config :good_flows,
  :change_request_claims_max_body_bytes`, default 1 MiB); `408` past the
  read deadline; `400` when unreadable; `422` on `body` when the bytes are
  not UTF-8. The raw bytes are stored at `:markdown_body` in
  `conn.private`.
  """
  @behaviour Plug

  import Plug.Conn

  alias GoodFlowsWeb.Plugs.JsonBody
  alias GoodFlowsWeb.{RawBody, RawBodyHeaders}
  alias Plug.Conn.Utils

  @default_max_body_bytes 1_048_576

  @doc "The configured claims body limit in bytes."
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes,
    do:
      Application.get_env(
        :good_flows,
        :change_request_claims_max_body_bytes,
        @default_max_body_bytes
      )

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    limit = max_body_bytes()
    deadline = System.monotonic_time(:millisecond) + JsonBody.read_timeout_ms()

    with :ok <- check_content_type(conn),
         :ok <- RawBodyHeaders.check_content_encoding(conn),
         :ok <- RawBodyHeaders.check_declared_length(conn, limit),
         {:ok, conn, body} <- RawBody.read(conn, limit, deadline) do
      if String.valid?(body),
        do: put_private(conn, :markdown_body, body),
        else: halt_with(conn, 422, %{"body" => ["must be UTF-8"]})
    else
      {:error, reason} -> halt_detail(conn, reason)
      {:error, conn, reason} -> halt_detail(conn, reason)
    end
  end

  defp check_content_type(conn) do
    with [header] <- get_req_header(conn, "content-type"),
         {:ok, "text", "markdown", params} <- Utils.content_type(header),
         true <- params |> Map.delete("charset") |> map_size() == 0,
         true <- String.downcase(Map.get(params, "charset", "utf-8")) == "utf-8" do
      :ok
    else
      _other -> {:error, :unsupported_media_type}
    end
  end

  defp halt_detail(conn, reason) do
    {status, detail} =
      case reason do
        :unsupported_media_type -> {415, "Content-Type must be text/markdown (charset utf-8)"}
        :unsupported_encoding -> {415, "Content-Encoding must be absent or identity"}
        :too_large -> {413, "Claims exceed the size limit"}
        :timeout -> {408, "Claims were not received in time"}
        :unreadable -> {400, "Claims could not be read"}
      end

    halt_with(conn, status, %{detail: detail})
  end

  defp halt_with(conn, status, errors) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{errors: errors}))
    |> halt()
  end
end
