defmodule GoodFlows.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias GoodFlows.Pools.Config, as: PoolsConfig
  alias GoodFlows.Spry.Config, as: SpryConfig
  alias GoodFlows.Spry.Redaction, as: SpryRedaction

  @impl true
  def start(_type, _args) do
    # Before any handler is attached, so no handler sees an unredacted
    # Sprites token from SDK process state.
    SpryRedaction.install_logger_filter()
    Logger.add_handlers(:good_flows)
    SpryConfig.validate!()
    PoolsConfig.validate!()

    children =
      [
        GoodFlowsWeb.Telemetry,
        GoodFlows.Repo,
        GoodFlows.Vault,
        GoodFlows.Spry.Executions,
        {Task.Supervisor, name: GoodFlows.Spry.TaskSupervisor},
        {Phoenix.PubSub, name: GoodFlows.PubSub},
        # Pools: the drain starts first so it stops last, after the endpoint
        # (channels), exec servers, and session coordinators.
        GoodFlows.Pools.ShutdownDrain,
        GoodFlows.Pools.Spool,
        GoodFlows.Pools.TransferSemaphore,
        {DynamicSupervisor, name: GoodFlows.Pools.CoordinatorSupervisor, strategy: :one_for_one},
        {DynamicSupervisor, name: GoodFlows.Pools.ExecSupervisor, strategy: :one_for_one}
      ] ++
        pgflow_children() ++
        [
          {DNSCluster, query: Application.get_env(:good_flows, :dns_cluster_query) || :ignore},
          GoodFlowsWeb.TestReportAdmission,
          GoodFlowsWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GoodFlows.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp pgflow_children do
    case Application.get_env(:good_flows, PgFlow) do
      opts when is_list(opts) -> pgflow_children(opts)
      _other -> []
    end
  end

  # ShutdownDrain starts before PgFlow so it terminates after PgFlow's
  # workers and finalizes any run they left running.
  @doc false
  def pgflow_children(opts) do
    [
      GoodFlows.Spry.ShutdownDrain,
      {PgFlow, opts},
      GoodFlows.Spry.ReaperScheduler,
      GoodFlows.Pools.Reconciler
    ]
  end

  # Before any child stops: pool admission ends at once, so no session,
  # upload, or exec starts while the endpoint and coordinators wind down
  # (Pools.ShutdownDrain ends the node's sessions after them).
  @impl true
  def prep_stop(state) do
    GoodFlows.Pools.ShutdownDrain.stop_admission()
    state
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GoodFlowsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
