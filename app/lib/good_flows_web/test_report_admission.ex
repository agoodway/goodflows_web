defmodule GoodFlowsWeb.TestReportAdmission do
  @moduledoc """
  Per-node caps on concurrent test report uploads.

  A slot covers a whole upload after authentication: the body read, the
  depth scan and decode, validation and persistence. `acquire/1` grants a
  slot to the calling process or returns `:full` when either cap is reached:

    * the node cap, `config :good_flows, :test_report_max_concurrent_uploads`
      (default 2). Each admitted upload uses at most one `GoodFlows.Repo`
      connection at a time, so this cap must stay well below the Repo
      `pool_size` (default 10) to leave connections for other traffic.
    * the per-account cap,
      `config :good_flows, :test_report_max_concurrent_uploads_per_account`
      (default 1), so one account cannot take every node slot.

  Both caps are read on every acquire. The caller must `release/1` the slot;
  a slot is also released when its holder process exits, so a request
  process that dies mid-upload cannot keep it. `acquire/1` returns `:full`
  when the server cannot answer within one second (a request that reaches
  the server after that is refused, never granted), and `release/1` is a
  cast, so neither can crash a request.
  """
  use GenServer

  @default_limit 2
  @default_account_limit 1
  # An upload that cannot get an answer this quickly is told to retry.
  @acquire_timeout_ms 1_000

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "The configured number of node slots."
  @spec limit() :: pos_integer()
  def limit,
    do: Application.get_env(:good_flows, :test_report_max_concurrent_uploads, @default_limit)

  @doc "The configured number of slots one account may hold at once."
  @spec account_limit() :: pos_integer()
  def account_limit do
    Application.get_env(
      :good_flows,
      :test_report_max_concurrent_uploads_per_account,
      @default_account_limit
    )
  end

  @doc """
  Takes a slot for the calling process on behalf of `account_id`, or
  returns `:full` when the node or account cap is reached or the server is
  unavailable.
  """
  @spec acquire(term()) :: {:ok, reference()} | :full
  def acquire(account_id) do
    deadline = System.monotonic_time(:millisecond) + @acquire_timeout_ms
    request = {:acquire, self(), account_id, limit(), account_limit(), deadline}
    GenServer.call(__MODULE__, request, @acquire_timeout_ms)
  catch
    :exit, _reason -> :full
  end

  @doc "Releases a slot taken by `acquire/1`. Releasing twice is harmless."
  @spec release(reference()) :: :ok
  def release(ref), do: GenServer.cast(__MODULE__, {:release, ref})

  @doc "Number of slots currently held."
  @spec in_use() :: non_neg_integer()
  def in_use, do: GenServer.call(__MODULE__, :in_use)

  @impl GenServer
  def init(:ok), do: {:ok, %{holders: %{}, accounts: %{}}}

  @impl GenServer
  # A request seen after its deadline has already been answered `:full` by
  # the caller's timeout, so it is never granted a slot it would not know of.
  def handle_call({:acquire, pid, account, limit, account_limit, deadline}, _from, state) do
    if System.monotonic_time(:millisecond) >= deadline or map_size(state.holders) >= limit or
         Map.get(state.accounts, account, 0) >= account_limit do
      {:reply, :full, state}
    else
      ref = Process.monitor(pid)

      state = %{
        holders: Map.put(state.holders, ref, account),
        accounts: Map.update(state.accounts, account, 1, &(&1 + 1))
      }

      {:reply, {:ok, ref}, state}
    end
  end

  def handle_call(:in_use, _from, state), do: {:reply, map_size(state.holders), state}

  @impl GenServer
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, drop(state, ref)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: {:noreply, drop(state, ref)}

  defp drop(state, ref) do
    case Map.fetch(state.holders, ref) do
      :error ->
        state

      {:ok, account} ->
        accounts =
          case Map.fetch!(state.accounts, account) do
            1 -> Map.delete(state.accounts, account)
            count -> Map.put(state.accounts, account, count - 1)
          end

        %{holders: Map.delete(state.holders, ref), accounts: accounts}
    end
  end
end
