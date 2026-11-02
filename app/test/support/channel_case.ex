defmodule GoodFlowsWeb.ChannelCase do
  @moduledoc """
  Test case for channel tests, with `Phoenix.ChannelTest` and the SQL
  sandbox in shared mode (session coordinators and exec servers run in
  their own processes).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import GoodFlowsWeb.ChannelCase

      require Ecto.Query

      @endpoint GoodFlowsWeb.Endpoint
    end
  end

  setup tags do
    GoodFlows.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Serves `GoodFlowsWeb.Endpoint` over real HTTP on a free loopback port for
  the rest of the test and returns the port.
  """
  def serve_endpoint! do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: GoodFlowsWeb.Endpoint,
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc """
  Opens a WebSocket to the pool socket with `subprotocols` and returns
  `{:upgraded, conn, stream}` or `{:refused, status}`.
  """
  def ws_connect(port, path, subprotocols) do
    {:ok, conn} = :gun.open(~c"127.0.0.1", port, %{protocols: [:http], retry: 0})
    {:ok, :http} = :gun.await_up(conn, 5_000)
    protocols = Enum.map(subprotocols, &{&1, :gun_ws_h})
    stream = :gun.ws_upgrade(conn, path, [], %{protocols: protocols})

    receive do
      {:gun_upgrade, ^conn, ^stream, ["websocket"], headers} ->
        {:upgraded, conn, stream, headers}

      {:gun_response, ^conn, ^stream, _fin, status, _headers} ->
        {:refused, status, :gun.close(conn)}

      {:gun_error, ^conn, ^stream, reason} ->
        {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Sends a Phoenix v2 frame and waits for the reply to `ref`."
  def ws_call(conn, stream, topic, event, payload, ref) do
    frame = Jason.encode!([ref, ref, topic, event, payload])
    :ok = :gun.ws_send(conn, stream, {:text, frame})
    ws_await(conn, stream, fn [_join, ^ref, ^topic, "phx_reply", reply] -> reply end)
  end

  @doc "Waits for a text frame accepted by `fun` (a match-or-raise function)."
  def ws_await(conn, stream, fun) do
    receive do
      {:gun_ws, ^conn, ^stream, {:text, text}} ->
        try do
          fun.(Jason.decode!(text))
        rescue
          FunctionClauseError -> ws_await(conn, stream, fun)
        end
    after
      5_000 -> raise "no matching WebSocket frame"
    end
  end
end
