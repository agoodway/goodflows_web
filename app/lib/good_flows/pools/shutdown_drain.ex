defmodule GoodFlows.Pools.ShutdownDrain do
  @moduledoc """
  Ends this node's pool sessions promptly when the application shuts down.

  Started in the main child list after `Phoenix.PubSub` and ahead of the
  session coordinator and exec supervisors (and the endpoint), so on
  shutdown it terminates after the endpoint (channels are gone) and the
  exec and coordinator supervisors. It traps exits, so `terminate/2` runs on
  every orderly shutdown:

    1. stops admission: `accepting?/0` turns false, so new sockets,
       sessions, uploads, and execs are refused on this node (already done
       in `GoodFlows.Application.prep_stop/1`, before any child stopped),
    2. ends every open session whose coordinator lives on this node and boot
       with `session_owner_lost` (running execs end `error`/`owner_lost`
       before `session_ended`), and
    3. deletes this node's spools.

  Clients then fail fast instead of waiting out the disconnect grace.
  Sessions of a node that dies without an orderly shutdown are expired by
  `GoodFlows.Pools.Reconciler` after confirming the owner is gone.
  """
  use GenServer, shutdown: 30_000

  require Logger

  alias GoodFlows.Pools.{Config, Sessions, Spool}

  @draining_key {__MODULE__, :draining}

  @doc false
  def child_spec(opts),
    do: Supervisor.child_spec(super(opts), id: Keyword.get(opts, :name, __MODULE__))

  @doc "Starts the drain. Options: `:name` (default this module)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether this node admits new pool work: pools enabled and not draining."
  @spec accepting?() :: boolean()
  def accepting?, do: Config.enabled?() and not draining?()

  @doc "Whether this node is draining for shutdown."
  @spec draining?() :: boolean()
  def draining?, do: :persistent_term.get(@draining_key, false)

  @doc """
  Stops admission on this node (`accepting?/0` turns false). Called from
  `GoodFlows.Application.prep_stop/1`, before any child stops, and again by
  `drain/0`.
  """
  @spec stop_admission() :: :ok
  def stop_admission, do: :persistent_term.put(@draining_key, true)

  @doc """
  Stops admission, ends this node's open sessions with `session_owner_lost`,
  and deletes its spools. Returns the number of sessions ended.
  """
  @spec drain() :: non_neg_integer()
  def drain do
    stop_admission()
    count = Sessions.end_local_sessions("session_owner_lost")
    Spool.delete_all()
    count
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@draining_key)
    :ok
  end

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    case drain() do
      0 -> :ok
      count -> Logger.warning("Pools: ended #{count} session(s) owned by this node at shutdown")
    end
  rescue
    error ->
      Logger.error("Pools shutdown drain failed: #{Exception.message(error)}")
      :ok
  end
end
