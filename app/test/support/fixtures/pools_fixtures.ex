defmodule GoodFlows.PoolsFixtures do
  @moduledoc """
  Test helpers for Sprite pools, members, sessions, and execs.
  """

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Pools
  alias GoodFlows.Pools.{Config, Credentials, Exec, Member, Pool, Session}
  alias GoodFlows.Repo

  @token "sprites_test_token_a1b2"

  @doc "The token `GoodFlows.SpryFixtures.credential_fixture/1` stores by default."
  def token, do: @token

  @doc "Creates a pool through the context (the account needs a credential)."
  def pool_fixture(project, attrs \\ %{}) do
    account = Repo.get!(Account, project.account_id)

    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put_new_lazy("slug", fn -> "pool-#{System.unique_integer([:positive])}" end)
      |> Map.put_new("max_members", 4)
      |> Map.put_new("min_ready", 0)

    {:ok, pool} = Pools.create_pool(account, project, attrs)
    pool
  end

  @doc "Inserts a member row directly (default state `idle`, current setup and helper)."
  def member_fixture(%Pool{} = pool, attrs \\ %{}) do
    token = Map.get(attrs, :token, @token)

    defaults = %{
      account_id: pool.account_id,
      pool_id: pool.id,
      name: Member.generate_name(),
      state: "idle",
      setup_version: pool.setup_version,
      helper_version: Config.helper_version(),
      arch: "x86_64",
      golden_checkpoint_id: "cp-#{System.unique_integer([:positive])}",
      credential_fingerprint: Credentials.fingerprint(token),
      credential_snapshot: token
    }

    Member
    |> struct(Map.merge(defaults, Map.drop(Map.new(attrs), [:token])))
    |> Repo.insert!(log: false)
  end

  @doc "Inserts a session row directly (default `waiting`, owned by this node)."
  def session_fixture(%Pool{} = pool, api_key, attrs \\ %{}) do
    now = DateTime.utc_now()
    token = Map.get(attrs, :token, @token)

    defaults = %{
      account_id: pool.account_id,
      pool_id: pool.id,
      api_key_id: api_key && api_key.id,
      pool_slug: pool.slug,
      project_slug: "project",
      credential_fingerprint: Credentials.fingerprint(token),
      status: "waiting",
      # `wanted` may not exceed `max_members` (a CHECK constraint).
      max_members: max(2, Map.get(attrs, :wanted, 2)),
      wanted: 2,
      wanting_since: now,
      acquire_deadline_at: DateTime.add(now, 60, :second),
      last_seen_at: now
    }

    Session
    |> struct(Map.merge(defaults, Map.drop(Map.new(attrs), [:token])))
    |> Repo.insert!()
  end

  @doc "Inserts an exec row directly."
  def exec_fixture(%Session{} = session, %Member{} = member, attrs \\ %{}) do
    defaults = %{
      account_id: session.account_id,
      session_id: session.id,
      member_id: member.id,
      member_name: member.name,
      lease_generation: member.lease_generation,
      status: "running",
      started_at: DateTime.utc_now()
    }

    Exec
    |> struct(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end
end
