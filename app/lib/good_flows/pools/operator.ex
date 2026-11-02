defmodule GoodFlows.Pools.Operator do
  @moduledoc """
  Operator actions for pools, used by `mix pools.destroy_members` and from
  a live node (`bin/good_flows rpc 'GoodFlows.Pools.Operator.destroy_members("POOL_ID")'`,
  `bin/good_flows rpc 'GoodFlows.Pools.Operator.forget_member("MEMBER_ID")'`).
  """
  import Ecto.Query

  require Logger

  alias GoodFlows.Pools.{Member, Members}
  alias GoodFlows.Repo
  alias GoodFlows.Spry.Sprites

  @doc """
  Forgets an `abandoned` member: deletes its row (only while it is still
  `abandoned`) and logs its name, pool, and last error as an audit record.
  Use it once its sprite was removed in Sprites by other means (its
  creation credential was revoked, so GoodFlows cannot). Returns `:ok` or
  `{:error, :not_abandoned}`.
  """
  @spec forget_member(Ecto.UUID.t()) :: :ok | {:error, :not_abandoned}
  def forget_member(member_id) do
    case Repo.get(Member, member_id, log: false) do
      %Member{state: "abandoned"} = member ->
        {count, _} =
          Repo.delete_all(where(Member, [m], m.id == ^member.id and m.state == "abandoned"))

        if count == 1 do
          Logger.warning(
            "Pools: operator forgot abandoned member #{member.name} of pool " <>
              "#{member.pool_id} (last error: #{member.last_error})"
          )

          :ok
        else
          {:error, :not_abandoned}
        end

      _other ->
        {:error, :not_abandoned}
    end
  end

  @doc """
  Destroys every member sprite of a pool with each member's own
  creation-credential snapshot and deletes the member rows whose sprite is
  gone (destroyed, or `not_found` under that credential). Members whose
  destruction fails keep their row. Intended for pools abandoned after
  `POOLS_ENABLED=false` or a rollback; it does not check leases, so only
  run it when no session needs the pool. Returns `[{name, result}]`.
  """
  @spec destroy_members(Ecto.UUID.t()) :: [{String.t(), :destroyed | {:failed, String.t()}}]
  def destroy_members(pool_id) do
    Member
    |> where([m], m.pool_id == ^pool_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all(log: false)
    |> Enum.map(fn member ->
      result =
        case Sprites.destroy(Members.client(member), member.name) do
          :ok ->
            delete(member)

          {:error, %{status: 404}} ->
            delete(member)

          {:error, :timeout} ->
            {:failed, "destroy timed out"}

          {:error, error} ->
            {:failed, Sprites.error_message(error)}
        end

      {member.name, result}
    end)
  end

  defp delete(member) do
    Repo.delete_all(where(Member, id: ^member.id))
    :destroyed
  end
end
