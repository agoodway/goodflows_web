defmodule GoodFlowsWeb.RawBodyHeaders do
  @moduledoc """
  Header checks shared by the routes whose bodies the endpoint leaves
  unparsed (`GoodFlowsWeb.Plugs.BodyParsers.raw_body_route?/1`): the test
  report upload and the pool workspace upload. Both run before any of the
  body is read.
  """

  import Plug.Conn, only: [get_req_header: 2]

  @doc """
  `:ok` when `Content-Encoding` is absent or a single `identity` value
  (case- and whitespace-insensitive), else `{:error, :unsupported_encoding}`.
  """
  @spec check_content_encoding(Plug.Conn.t()) :: :ok | {:error, :unsupported_encoding}
  def check_content_encoding(conn) do
    case get_req_header(conn, "content-encoding") do
      [] ->
        :ok

      [encoding] ->
        if encoding |> String.trim() |> String.downcase() == "identity",
          do: :ok,
          else: {:error, :unsupported_encoding}

      _several ->
        {:error, :unsupported_encoding}
    end
  end

  @doc """
  `{:error, :too_large}` when a single, well-formed `Content-Length`
  declares more than `limit` bytes, else `:ok` (the read itself enforces the
  limit when the header is absent or unusable).
  """
  @spec check_declared_length(Plug.Conn.t(), non_neg_integer()) :: :ok | {:error, :too_large}
  def check_declared_length(conn, limit) do
    with [value] <- get_req_header(conn, "content-length"),
         {length, ""} when length > limit <- Integer.parse(String.trim(value)) do
      {:error, :too_large}
    else
      _other -> :ok
    end
  end
end
