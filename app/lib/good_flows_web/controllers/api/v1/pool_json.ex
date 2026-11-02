defmodule GoodFlowsWeb.Api.V1.PoolJSON do
  @moduledoc """
  Renders pools and pool members. Never includes checkpoint ids, worker
  owner ids, credential fingerprints or snapshots, or the Sprites token.
  """

  alias GoodFlows.Pools
  alias GoodFlows.Pools.{Member, Pool}

  @doc "Renders a list of pools."
  def index(%{pools: pools}), do: %{data: Enum.map(pools, &data/1)}

  @doc "Renders one pool."
  def show(%{pool: pool}), do: %{data: data(pool)}

  @doc "Renders a pool's members."
  def members(%{pool: pool, members: members}),
    do: %{data: Enum.map(members, &member(&1, pool))}

  defp data(%Pool{} = pool) do
    %{
      id: pool.id,
      slug: pool.slug,
      project: pool.project.slug,
      setup: pool.setup,
      setup_version: pool.setup_version,
      min_ready: pool.min_ready,
      max_members: pool.max_members,
      idle_ttl_ms: pool.idle_ttl_ms,
      status: pool.status,
      members: pool.member_counts,
      provision_failures: pool.provision_failures,
      next_provision_at: pool.next_provision_at,
      last_provision_error: pool.last_provision_error,
      inserted_at: pool.inserted_at,
      updated_at: pool.updated_at
    }
  end

  defp member(%Member{} = member, pool) do
    %{
      id: member.id,
      name: member.name,
      state: member.state,
      setup_version: member.setup_version,
      stale: Pools.stale?(member, pool),
      session_id: member.session_id,
      last_error: member.last_error,
      inserted_at: member.inserted_at,
      updated_at: member.updated_at
    }
  end
end
