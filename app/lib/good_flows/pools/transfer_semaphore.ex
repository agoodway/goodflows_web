defmodule GoodFlows.Pools.TransferSemaphore do
  @moduledoc """
  Node-wide cap on active helper transfers (workspace hydrations and report
  fetches), `transfer_concurrency` (default 2), separate from the member
  job concurrency. Memory then scales with chunk size times concurrency,
  not archive size.

  `acquire/2` waits up to `timeout` for a permit; a permit is released by
  `release/1` or when its holder exits. Waiters with `priority: :high`
  (report fetches, which a client is waiting on synchronously) are served
  before normal ones (workspace hydrations), so long workspace copies
  cannot starve report downloads.
  """
  use GenServer

  alias GoodFlows.Pools.Config

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Takes a permit for the caller, waiting up to `timeout` ms. Options: `:priority`."
  @spec acquire(timeout(), keyword()) :: {:ok, reference()} | {:error, :busy}
  def acquire(timeout \\ 0, opts \\ []) do
    priority = if Keyword.get(opts, :priority) == :high, do: :high, else: :normal

    GenServer.call(
      __MODULE__,
      {:acquire, self(), Config.transfer_concurrency(), priority},
      timeout + 1_000
    )
    |> case do
      {:ok, ref} -> {:ok, ref}
      :queued -> await_grant(timeout)
    end
  catch
    :exit, _reason -> {:error, :busy}
  end

  defp await_grant(timeout) do
    receive do
      {__MODULE__, :granted, ref} -> {:ok, ref}
    after
      timeout ->
        GenServer.cast(__MODULE__, {:cancel, self()})

        # A grant may have raced the cancel.
        receive do
          {__MODULE__, :granted, ref} ->
            release(ref)
            {:error, :busy}
        after
          0 -> {:error, :busy}
        end
    end
  end

  @doc "Releases a permit. Releasing twice is harmless."
  @spec release(reference()) :: :ok
  def release(ref), do: GenServer.cast(__MODULE__, {:release, ref})

  @doc "Runs `fun` holding a permit, or returns `{:error, :busy}`. Options as `acquire/2`."
  @spec with_permit(timeout(), (-> result), keyword()) :: result | {:error, :busy}
        when result: term()
  def with_permit(timeout, fun, opts \\ []) do
    case acquire(timeout, opts) do
      {:ok, ref} ->
        try do
          fun.()
        after
          release(ref)
        end

      {:error, :busy} ->
        {:error, :busy}
    end
  end

  @impl GenServer
  def init(:ok), do: {:ok, %{held: %{}, waiting: %{high: :queue.new(), normal: :queue.new()}}}

  @impl GenServer
  def handle_call({:acquire, pid, limit, priority}, _from, state) do
    if map_size(state.held) < limit do
      ref = Process.monitor(pid)
      {:reply, {:ok, ref}, %{state | held: Map.put(state.held, ref, pid)}}
    else
      waiting = Map.update!(state.waiting, priority, &:queue.in(pid, &1))
      {:reply, :queued, %{state | waiting: waiting}}
    end
  end

  @impl GenServer
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> drop(ref) |> grant_next()}
  end

  def handle_cast({:cancel, pid}, state) do
    {:noreply,
     %{state | waiting: Map.new(state.waiting, fn {k, q} -> {k, :queue.delete(pid, q)} end)}}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, state |> drop(ref) |> grant_next()}

  defp drop(state, ref), do: %{state | held: Map.delete(state.held, ref)}

  defp grant_next(state) do
    if map_size(state.held) < Config.transfer_concurrency() do
      case next_waiter(state.waiting) do
        {pid, waiting} -> grant_next(grant(%{state | waiting: waiting}, pid))
        nil -> state
      end
    else
      state
    end
  end

  defp next_waiter(%{high: high, normal: normal} = waiting) do
    case :queue.out(high) do
      {{:value, pid}, high} ->
        {pid, %{waiting | high: high}}

      {:empty, _high} ->
        case :queue.out(normal) do
          {{:value, pid}, normal} -> {pid, %{waiting | normal: normal}}
          {:empty, _normal} -> nil
        end
    end
  end

  # A waiter that died while queued is dropped without a permit.
  defp grant(state, pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, {__MODULE__, :granted, ref})
      %{state | held: Map.put(state.held, ref, pid)}
    else
      state
    end
  end
end
