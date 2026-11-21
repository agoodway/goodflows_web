defmodule GoodFlows.ProjectEvents.Listener do
  @moduledoc """
  Turns the `project_events` Postgres notifications into local PubSub
  broadcasts on each project's topic (`GoodFlows.ProjectEvents.topic/1`).

  `GoodFlows.ProjectEvents.record/5` sends `pg_notify('project_events',
  <project id>)` in the transaction that inserts an event. Postgres
  delivers a notification only when that transaction commits, so waiting
  readers are told only about committed events, and nothing for a
  rollback. Every node runs one listener with one dedicated connection and
  broadcasts only to its own subscribers.
  """
  use GenServer

  alias GoodFlows.ProjectEvents
  alias GoodFlows.Repo

  @channel "project_events"
  @connection_keys ~w(hostname port endpoints username password database socket_dir socket ssl
                      parameters socket_options connect_timeout handshake_timeout
                      target_server_type)a

  @doc "Starts the listener."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The notification channel."
  @spec channel() :: String.t()
  def channel, do: @channel

  @doc """
  The `Postgrex.Notifications` options for a Repo config: the keys that
  decide how to reach the Repo's database, plus `auto_reconnect`.
  """
  @spec connection_options(keyword()) :: keyword()
  def connection_options(repo_config) do
    repo_config
    |> Keyword.take(@connection_keys)
    |> Keyword.put(:auto_reconnect, true)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, pid} = Postgrex.Notifications.start_link(connection_options(Repo.config()))
    {status, _ref} = Postgrex.Notifications.listen(pid, @channel)
    true = status in [:ok, :eventually]
    {:ok, %{notifications: pid}}
  end

  @impl GenServer
  def handle_info({:notification, _pid, _ref, @channel, project_id}, state) do
    Phoenix.PubSub.local_broadcast(
      GoodFlows.PubSub,
      ProjectEvents.topic(project_id),
      {:project_event, project_id}
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
