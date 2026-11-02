defmodule GoodFlows.Pools.OwnerRPCTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Pools.OwnerRPC
  alias GoodFlows.Spry.Executions

  # A node name this VM has never seen, so no atom exists for it (as on a
  # freshly booted node that has not joined the cluster yet).
  defp unseen_node_owner do
    "gf-unseen-#{System.unique_integer([:positive])}-#{Ecto.UUID.generate()}@nowhere" <>
      "|#{Ecto.UUID.generate()}|#{Ecto.UUID.generate()}"
  end

  describe "an owner on a node this VM has never seen" do
    test "is unreachable, never confirmed lost" do
      owner_id = unseen_node_owner()

      assert OwnerRPC.call(owner_id, :ping) == {:error, :owner_unavailable}
      assert OwnerRPC.status(owner_id) == :unknown
      assert OwnerRPC.probe(owner_id) == :unknown
    end
  end

  describe "confirmed loss" do
    test "a malformed owner id is lost" do
      for owner_id <- [nil, "", "garbage", "a|b"] do
        assert OwnerRPC.call(owner_id, :ping) == {:error, :owner_lost}
        assert OwnerRPC.status(owner_id) == :lost
        assert OwnerRPC.probe(owner_id) == :lost
      end
    end

    test "an owner of this node's earlier boot is lost" do
      owner_id = "#{node()}|#{Ecto.UUID.generate()}|#{Ecto.UUID.generate()}"

      assert OwnerRPC.call(owner_id, :ping) == {:error, :owner_lost}
      assert OwnerRPC.status(owner_id) == :lost
      assert OwnerRPC.probe(owner_id) == :lost
    end

    test "an unregistered owner of this boot is lost" do
      owner_id = Executions.new_owner_id()

      assert OwnerRPC.status(owner_id) == :lost
      assert OwnerRPC.probe(owner_id) == :lost
    end
  end
end
