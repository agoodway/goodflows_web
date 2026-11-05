defmodule GoodFlowsWeb.GreedyBodyAdapter do
  @moduledoc """
  A `Plug.Conn.Adapter` for tests that wraps `Plug.Adapters.Test.Conn` but
  ignores the `:length` option of `read_body/2`, returning the whole body
  with `{:ok, body, conn}` the way a real adapter may when its length option
  is only approximate. Options of `wrap/2`:

    * `block: pid` – `read_req_body/2` notifies `pid` and waits forever (to
      test a request process that dies mid-read)
    * `error: reason` – `read_req_body/2` returns `{:error, reason}`
    * `trickle: {bytes, delay_ms}` – each read sleeps `delay_ms`, then
      returns the next `bytes` of the body (`{:more, …}` until the last
      piece), like a slow client
  """
  @behaviour Plug.Conn.Adapter

  alias Plug.Adapters.Test.Conn, as: TestConn

  @doc "Switches `conn` to this adapter."
  def wrap(%Plug.Conn{adapter: {TestConn, state}} = conn, opts \\ []) do
    state = %{inner: state, block: opts[:block], error: opts[:error], trickle: opts[:trickle]}
    %{conn | adapter: {__MODULE__, state}}
  end

  @impl true
  def read_req_body(%{block: pid} = state, _opts) when is_pid(pid) do
    send(pid, {:reading_body, self()})
    Process.sleep(:infinity)
    {:ok, "", state}
  end

  def read_req_body(%{error: reason}, _opts) when not is_nil(reason), do: {:error, reason}

  def read_req_body(%{trickle: {bytes, delay}, inner: inner} = state, _opts) do
    Process.sleep(delay)

    case inner.req_body do
      <<piece::binary-size(^bytes), rest::binary>> when rest != "" ->
        {:more, piece, %{state | inner: %{inner | req_body: rest}}}

      last ->
        {:ok, last, %{state | inner: %{inner | req_body: ""}}}
    end
  end

  def read_req_body(%{inner: inner} = state, _opts) do
    {:ok, inner.req_body, %{state | inner: %{inner | req_body: ""}}}
  end

  @impl true
  def send_resp(state, status, headers, body) do
    {:ok, sent, inner} = TestConn.send_resp(state.inner, status, headers, body)
    {:ok, sent, %{state | inner: inner}}
  end

  @impl true
  def send_file(state, status, headers, path, offset, length) do
    {:ok, sent, inner} = TestConn.send_file(state.inner, status, headers, path, offset, length)
    {:ok, sent, %{state | inner: inner}}
  end

  @impl true
  def send_chunked(state, status, headers) do
    {:ok, sent, inner} = TestConn.send_chunked(state.inner, status, headers)
    {:ok, sent, %{state | inner: inner}}
  end

  @impl true
  def chunk(state, body) do
    {:ok, sent, inner} = TestConn.chunk(state.inner, body)
    {:ok, sent, %{state | inner: inner}}
  end

  @impl true
  def inform(state, status, headers), do: TestConn.inform(state.inner, status, headers)

  @impl true
  def upgrade(state, protocol, opts) do
    case TestConn.upgrade(state.inner, protocol, opts) do
      {:ok, inner} -> {:ok, %{state | inner: inner}}
      error -> error
    end
  end

  @impl true
  def push(state, path, headers), do: TestConn.push(state.inner, path, headers)

  @impl true
  def get_peer_data(state), do: TestConn.get_peer_data(state.inner)

  @impl true
  def get_http_protocol(state), do: TestConn.get_http_protocol(state.inner)

  @impl true
  def get_sock_data(state), do: TestConn.get_sock_data(state.inner)

  @impl true
  def get_ssl_data(state), do: TestConn.get_ssl_data(state.inner)
end
