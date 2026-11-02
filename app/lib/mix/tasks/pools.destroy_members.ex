defmodule Mix.Tasks.Pools.DestroyMembers do
  @shortdoc "Destroys every member sprite of a pool and removes its member rows"

  @moduledoc """
  Operator escape hatch for abandoned pools, for example after setting
  `POOLS_ENABLED=false` to roll back:

      mix pools.destroy_members POOL_ID

  Destroys each member's sprite with that member's own encrypted
  creation-credential snapshot (never the account's current token), and
  deletes the member rows whose sprite is gone (`not_found` counts). A
  member whose destruction fails keeps its row and is reported, so no
  remote VM is silently orphaned. Leases are not checked: run it only when
  no session needs the pool. The pool row itself is left alone; delete the
  pool through the API afterwards if needed (`DELETE
  /api/v1/projects/:project/pools/:pool` works even while pools are
  disabled, and the reconciler keeps expiring sessions and destroying
  members then, so this task is only needed when that is not enough).

  The task does not boot the application (no PgFlow workers, no endpoint):
  it loads the configuration and starts only the repo, the vault, the
  execution registry, and the Sprites task supervisor. In a release, run it
  inside the live node instead:

      bin/good_flows rpc 'GoodFlows.Pools.Operator.destroy_members("POOL_ID")'

  See `GoodFlows.Pools.Operator.destroy_members/1`.
  """
  use Mix.Task

  alias GoodFlows.Pools.Operator
  alias GoodFlows.Spry.{Executions, Redaction}

  @requirements ["app.config"]

  @impl Mix.Task
  def run([pool_id]) do
    case Ecto.UUID.cast(pool_id) do
      {:ok, pool_id} ->
        :ok = start_services()

        pool_id |> Operator.destroy_members() |> Enum.each(&report/1)

      :error ->
        Mix.raise("POOL_ID must be a UUID")
    end
  end

  def run(_args), do: Mix.raise("usage: mix pools.destroy_members POOL_ID")

  defp report({name, :destroyed}), do: Mix.shell().info("#{name}: destroyed")
  defp report({name, {:failed, message}}), do: Mix.shell().error("#{name}: kept (#{message})")

  @doc "Starts only what destroying members needs. Idempotent."
  @spec start_services() :: :ok
  def start_services do
    Redaction.install_logger_filter()
    {:ok, _apps} = Application.ensure_all_started([:telemetry, :postgrex, :ecto_sql, :req])
    ensure_started(GoodFlows.Repo.start_link())
    ensure_started(GoodFlows.Vault.start_link())
    %{start: {module, fun, args}} = Executions.child_spec([])
    ensure_started(apply(module, fun, args))
    ensure_started(Task.Supervisor.start_link(name: GoodFlows.Spry.TaskSupervisor))
    :ok
  end

  defp ensure_started({:ok, _pid}), do: :ok
  defp ensure_started({:error, {:already_started, _pid}}), do: :ok

  defp ensure_started({:error, reason}),
    do: Mix.raise("could not start pool services: #{inspect(reason)}")
end
