defmodule GoodFlows.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Logger.add_handlers(:good_flows)

    children =
      [
        GoodFlowsWeb.Telemetry,
        GoodFlows.Repo,
        {Phoenix.PubSub, name: GoodFlows.PubSub}
      ] ++
        pgflow_children() ++
        [
          {DNSCluster, query: Application.get_env(:good_flows, :dns_cluster_query) || :ignore},
          GoodFlowsWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GoodFlows.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp pgflow_children do
    case Application.get_env(:good_flows, PgFlow) do
      opts when is_list(opts) -> [{PgFlow, opts}]
      _other -> []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GoodFlowsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
