defmodule GoodFlows.Caches.SweepScheduler do
  @moduledoc """
  Enqueues `GoodFlows.Caches.SweepJob` every 5 minutes from exactly one
  node in the cluster.

  It is a `GoodFlows.Spry.ReaperScheduler` with its own local name,
  `:global` leader name and enqueue function, so it has the same
  leader-only behaviour: every node starts one, and only the holder of the
  leader name enqueues. Sweeps are idempotent, so the overlap during a
  leader handover is harmless.
  """
  require Logger

  alias GoodFlows.Spry.ReaperScheduler

  @leader_name __MODULE__.Leader

  @doc """
  Child spec. Options are those of `GoodFlows.Spry.ReaperScheduler`; the
  defaults are this module's name, the `:global` name
  `#{inspect(@leader_name)}`, and enqueueing `SweepJob`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the scheduler."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts
    |> Keyword.put_new(:name, __MODULE__)
    |> Keyword.put_new(:leader_name, @leader_name)
    |> Keyword.put_new(:enqueue, &enqueue_sweep/0)
    |> ReaperScheduler.start_link()
  end

  defp enqueue_sweep do
    case PgFlow.enqueue(GoodFlows.Caches.SweepJob, %{}) do
      {:ok, _run_id} -> :ok
      {:error, reason} -> Logger.warning("Could not enqueue cache sweep: #{inspect(reason)}")
    end
  end
end
