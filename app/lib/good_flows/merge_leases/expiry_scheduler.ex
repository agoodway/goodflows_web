defmodule GoodFlows.MergeLeases.ExpiryScheduler do
  @moduledoc """
  Enqueues `GoodFlows.MergeLeases.ExpiryJob` every 30 seconds from exactly
  one node in the cluster, so a lease is marked `expired` at most 60
  seconds after its `expires_at`.

  It is a `GoodFlows.Spry.ReaperScheduler` with its own local name,
  `GoodFlows.Leadership` (`:global`) leader name and enqueue function, so
  every node starts one and only the holder of the leader name enqueues.
  Expiry is idempotent, so the overlap during a leader handover is
  harmless.
  """
  require Logger

  alias GoodFlows.Spry.ReaperScheduler

  @interval_ms 30_000
  @leader_name __MODULE__.Leader

  @doc """
  Child spec. Options are those of `GoodFlows.Spry.ReaperScheduler`; the
  defaults are this module's name, a #{@interval_ms} ms interval, the
  `:global` name `#{inspect(@leader_name)}`, and enqueueing `ExpiryJob`.
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
    |> Keyword.put_new(:interval_ms, @interval_ms)
    |> Keyword.put_new(:leader_name, @leader_name)
    |> Keyword.put_new(:enqueue, &enqueue_expiry/0)
    |> ReaperScheduler.start_link()
  end

  defp enqueue_expiry do
    case PgFlow.enqueue(GoodFlows.MergeLeases.ExpiryJob, %{}) do
      {:ok, _run_id} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not enqueue merge lease expiry: #{inspect(reason)}")
    end
  end
end
