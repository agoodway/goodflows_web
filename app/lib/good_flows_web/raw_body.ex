defmodule GoodFlowsWeb.RawBody do
  @moduledoc """
  Reads an unparsed request body in chunks against one deadline and a byte
  limit.

  Callers check headers (`GoodFlowsWeb.RawBodyHeaders`) and take any
  admission slot before calling `read/3`. This function does not admit,
  limit the process heap, or decode. A caller that holds a slot must
  release it when `read/3` raises: an adapter can raise on a socket
  timeout or a client disconnect.

  `deadline` is an absolute `System.monotonic_time(:millisecond)` value.
  Once it has passed, `read/3` returns `{:error, conn, :timeout}` without
  reading. Each read asks for at most 1 MiB. A chunk that would push the
  bytes already accepted past `limit` returns `{:error, conn, :too_large}`
  whether the adapter's tag is `:ok` or `:more`. An adapter error is
  `{:error, conn, :unreadable}`.
  """

  import Plug.Conn, only: [read_body: 2]

  @chunk_bytes 1_048_576

  @type read_error :: :timeout | :too_large | :unreadable

  @doc """
  Reads `conn`'s body up to `limit` bytes, stopping at `deadline`.
  """
  @spec read(Plug.Conn.t(), pos_integer(), integer()) ::
          {:ok, Plug.Conn.t(), binary()} | {:error, Plug.Conn.t(), read_error()}
  def read(%Plug.Conn{} = conn, limit, deadline)
      when is_integer(limit) and limit > 0 and is_integer(deadline) do
    read_all(conn, limit, deadline, [], 0)
  end

  defp read_all(conn, limit, deadline, acc, size) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, conn, :timeout}
    else
      opts = [length: @chunk_bytes, read_length: @chunk_bytes, read_timeout: remaining]
      conn |> read_body(opts) |> next_chunk(conn, limit, deadline, acc, size)
    end
  end

  defp next_chunk({tag, data, conn}, _conn, limit, _deadline, _acc, size)
       when tag in [:ok, :more] and size + byte_size(data) > limit,
       do: {:error, conn, :too_large}

  defp next_chunk({:ok, data, conn}, _conn, _limit, _deadline, acc, _size),
    do: {:ok, conn, IO.iodata_to_binary([acc, data])}

  defp next_chunk({:more, data, conn}, _conn, limit, deadline, acc, size),
    do: read_all(conn, limit, deadline, [acc, data], size + byte_size(data))

  defp next_chunk({:error, :timeout}, conn, _limit, _deadline, _acc, _size),
    do: {:error, conn, :timeout}

  defp next_chunk({:error, _reason}, conn, _limit, _deadline, _acc, _size),
    do: {:error, conn, :unreadable}
end
