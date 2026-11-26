defmodule GoodFlows.ProjectEvents.Listener do
  @moduledoc """
  Turns the `project_events` Postgres notifications into local PubSub
  broadcasts on each project's topic (`GoodFlows.ProjectEvents.topic/1`),
  and the `workflow_runs` notifications (`<project id>:<run id>`, sent on
  a run's first insert) into `{:workflow_run_stored, project_id, run_id}`
  on `GoodFlows.WorkflowRuns.topic/1`. Both channels share one
  connection.

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
  alias GoodFlows.WorkflowRuns

  @channel "project_events"
  @runs_channel "workflow_runs"
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
  The channel `GoodFlows.WorkflowRuns` notifies on a run's first insert.
  It is separate from `channel/0` so the event feed's waiting readers are
  not woken by every CI run.
  """
  @spec runs_channel() :: String.t()
  def runs_channel, do: @runs_channel

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

    for channel <- [@channel, @runs_channel] do
      {status, _ref} = Postgrex.Notifications.listen(pid, channel)
      true = status in [:ok, :eventually]
    end

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

  def handle_info({:notification, _pid, _ref, @runs_channel, payload}, state) do
    case String.split(payload, ":", parts: 2) do
      [project_id, run_id] ->
        Phoenix.PubSub.local_broadcast(
          GoodFlows.PubSub,
          WorkflowRuns.topic(project_id),
          {:workflow_run_stored, project_id, run_id}
        )

      _other ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
