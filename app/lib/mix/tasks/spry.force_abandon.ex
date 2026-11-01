defmodule Mix.Tasks.Spry.ForceAbandon do
  @shortdoc "Fails a stuck running Spry run whose owner cannot be investigated"

  @moduledoc """
  Operator escape hatch for `running` Spry runs that the reaper keeps
  retaining because their owner cannot be investigated, typically because
  the owner id names a node from before a redeploy that changed node names.

      mix spry.force_abandon RUN_ID [RUN_ID ...]

  Only run this after establishing that the recorded owner's node is gone
  (or its execution has stopped): it releases the run's active guard so a
  new run for the same sprite can start.

  This intentionally overrides the reaper's rule that an owner must be
  confirmed terminated. A reachable live owner is still stopped first, but
  if its termination cannot be confirmed the run is finalized anyway and a
  warning is logged: that worker may still be running its current VM
  action, although it is fenced from further run writes and VM actions.

  The task does not boot the application (so it never starts PgFlow workers
  or the web endpoint): it loads the configuration and starts only the
  repo and the execution registry. It is not a distributed node, so it can
  only reach owners on its own VM; for any other owner it acts on the
  operator's word. In a release, where Mix is not available, run it inside
  the live node instead, which can also reach and stop owners on connected
  nodes:

      bin/good_flows rpc 'GoodFlows.Spry.force_abandon("RUN_ID")'

  See `GoodFlows.Spry.Reaper.force_abandon/1`.
  """
  use Mix.Task

  alias GoodFlows.Spry.{Executions, Redaction}

  @requirements ["app.config"]

  @impl Mix.Task
  def run([]), do: Mix.raise("usage: mix spry.force_abandon RUN_ID [RUN_ID ...]")

  def run(run_ids) do
    :ok = start_services()

    Enum.each(run_ids, fn run_id ->
      case GoodFlows.Spry.force_abandon(run_id) do
        {:ok, run} -> Mix.shell().info("#{run.id}: failed (#{run.error})")
        {:error, :not_found} -> Mix.shell().error("#{run_id}: no such run")
        {:error, :not_running} -> Mix.shell().error("#{run_id}: not running; left unchanged")
      end
    end)
  end

  @doc """
  Starts only what `force_abandon/1` needs (the repo and the execution
  registry, plus token redaction for log output). Idempotent: services
  that are already running, as in a booted application, are reused.
  """
  @spec start_services() :: :ok
  def start_services do
    Redaction.install_logger_filter()
    {:ok, _apps} = Application.ensure_all_started([:telemetry, :postgrex, :ecto_sql])
    ensure_started(GoodFlows.Repo.start_link())
    %{start: {module, fun, args}} = Executions.child_spec([])
    ensure_started(apply(module, fun, args))
    :ok
  end

  defp ensure_started({:ok, _pid}), do: :ok
  defp ensure_started({:error, {:already_started, _pid}}), do: :ok

  defp ensure_started({:error, reason}),
    do: Mix.raise("could not start Spry services: #{inspect(reason)}")
end
