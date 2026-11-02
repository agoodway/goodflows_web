defmodule GoodFlows.Spry.ReaperScheduler do
  @moduledoc """
  Enqueues `GoodFlows.Spry.ReapRunsJob` every 5 minutes (cron
  `*/5 * * * *` equivalent) from exactly one node in the cluster.

  Scheduling lives in the app because pg_cron (which PgFlow cron jobs need)
  is not available in every database this app runs against. Every node
  starts a scheduler, but only the cluster-wide leader enqueues: on each
  tick a scheduler claims the `:global` leader name if nobody holds it, and
  enqueues only while it holds that name. When the leader's node goes away
  `:global` drops its registration and the next tick on another node takes
  over. If a netsplit heals with two leaders, `:global` keeps the name for
  one of them (at random) and unregisters the other, which then finds the
  name taken on its next tick. Sweeps are idempotent, so the rare
  overlap during such a handover is harmless.
  """
  use GenServer

  require Logger

  alias GoodFlows.Leadership

  @interval_ms 5 * 60_000
  @leader_name __MODULE__.Leader

  @doc """
  Starts a scheduler.

  Options: `:interval_ms`, `:name` (local name, default this module),
  `:leader_name` (the `:global` name, default `#{inspect(@leader_name)}`),
  and `:enqueue` (a zero-arity function, default enqueueing `ReapRunsJob`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether the scheduler `server` currently holds the leader name."
  @spec leader?(GenServer.server()) :: boolean()
  def leader?(server \\ __MODULE__), do: GenServer.call(server, :leader?)

  @impl GenServer
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      leader_name: Keyword.get(opts, :leader_name, @leader_name),
      enqueue: Keyword.get(opts, :enqueue, &enqueue_sweep/0)
    }

    schedule(state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:leader?, _from, state) do
    {:reply, :global.whereis_name(state.leader_name) == self(), state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    if Leadership.claim(state.leader_name), do: state.enqueue.()
    schedule(state.interval_ms)
    {:noreply, state}
  end

  # Sent by :global.random_notify_name/3 when a healed netsplit finds two
  # leaders: one keeps the name and the other is unregistered and gets this;
  # its next tick finds the name taken.
  def handle_info({:global_name_conflict, _name}, state), do: {:noreply, state}

  defp enqueue_sweep do
    case PgFlow.enqueue(GoodFlows.Spry.ReapRunsJob, %{}) do
      {:ok, _run_id} -> :ok
      {:error, reason} -> Logger.warning("Could not enqueue Spry reaper: #{inspect(reason)}")
    end
  end

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
