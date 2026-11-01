defmodule GoodFlows.Spry.ShutdownDrain do
  @moduledoc """
  Finalizes this node's in-flight Spry runs when the application shuts down.

  It is started after `GoodFlows.Repo` and `GoodFlows.Spry.Executions` but
  before PgFlow, so on shutdown it terminates after PgFlow's workers (and
  before the repo). It traps exits, so its `terminate/2` always runs during
  an orderly shutdown: it stops every execution still registered by this
  boot (and its action tasks and command processes), then finalizes every
  run still `running` under an owner id of this node and boot as `failed`
  with "interrupted by server shutdown". Finalization is the same
  owner-conditional transition the worker and reaper use, so a run that
  finished first is left alone.

  Runs of a node that dies without an orderly shutdown are recovered by
  `GoodFlows.Spry.Reaper`.
  """
  use GenServer

  require Logger

  import Ecto.Query

  alias GoodFlows.Repo
  alias GoodFlows.Spry.{Executions, Run, Runner}

  @error "interrupted by server shutdown"
  @stop_timeout_ms 5_000

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 30_000
    }
  end

  @doc "Starts the drain. Options: `:name` (default this module)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Stops this boot's live executions and fails its `running` runs. Returns
  the number of runs finalized.
  """
  @spec drain() :: non_neg_integer()
  def drain do
    prefix = Executions.owner_prefix()

    runs =
      Run
      |> where([r], r.status == "running" and like(r.owner_id, ^"#{escape_like(prefix)}%"))
      |> select([r], struct(r, [:id, :owner_id]))
      |> Repo.all()

    Enum.count(runs, fn run ->
      _ = Executions.stop(run.owner_id, @stop_timeout_ms)
      Runner.finalize(run.id, run.owner_id, "failed", @error, @error) == :ok
    end)
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
      count -> Logger.warning("Spry: failed #{count} running run(s) interrupted by shutdown")
    end
  rescue
    error ->
      Logger.error("Spry shutdown drain failed: #{Exception.message(error)}")
      :ok
  end

  defp escape_like(string), do: String.replace(string, ~r/([\\%_])/, "\\\\\\1")
end
