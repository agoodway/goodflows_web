defmodule GoodFlows.Migrations.CreateSpritePoolsMigrationTest do
  # Migrates inside the sandbox transaction (see create_projects_migration_test.exs).
  use GoodFlows.DataCase, async: false

  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Migrator

  @version 20_261_102_100_000
  @migration GoodFlows.Repo.Migrations.CreateSpritePools
  @tables ~w(pools pool_sessions pool_members pool_execs)

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Code.require_file("#{@version}_create_sprite_pools.exs", Migrator.migrations_path(Repo))
    end

    :ok
  end

  defp migrate(direction) do
    Migrator.run(Repo, [{@version, @migration}], direction,
      to: @version,
      log: false,
      migration_lock: false
    )
  end

  defp table?(name) do
    %{rows: [[exists?]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [name])
    exists?
  end

  test "down and up round-trip" do
    assert Enum.all?(@tables, &table?/1)
    assert migrate(:down) == [@version]
    refute Enum.any?(@tables, &table?/1)
    assert migrate(:up) == [@version]
    assert Enum.all?(@tables, &table?/1)
    assert table?("pool_execs_one_running_per_member_index")
  end

  test "foreign key rules" do
    account = account_fixture()
    credential_fixture(account)
    project = project_fixture(account)
    pool = pool_fixture(project)
    member = member_fixture(pool)
    session = session_fixture(pool, nil)
    exec = exec_fixture(session, member, %{status: "exited"})

    # pool_members.pool_id is NO ACTION: members go before the pool.
    assert_raise Ecto.ConstraintError, ~r/pool_members_pool_id_fkey/, fn ->
      Repo.transact(fn -> {:ok, Repo.delete!(pool)} end)
    end

    # Removing the member nilifies the exec's member_id; the name stays.
    Repo.delete!(member)
    assert %{member_id: nil, member_name: name} = Repo.reload!(exec)
    assert name == member.name

    # Removing the pool nilifies the session's pool_id; the slugs stay.
    Repo.delete!(pool)
    assert %{pool_id: nil, pool_slug: slug} = Repo.reload!(session)
    assert slug == pool.slug

    # Execs go with their session.
    Repo.delete!(session)
    refute Repo.reload(exec)
  end

  test "one running exec per member" do
    account = account_fixture()
    credential_fixture(account)
    pool = account |> project_fixture() |> pool_fixture()
    member = member_fixture(pool)
    session = session_fixture(pool, nil)
    exec_fixture(session, member)

    assert_raise Ecto.ConstraintError, ~r/pool_execs_one_running_per_member_index/, fn ->
      exec_fixture(session, member)
    end

    exec_fixture(session, member, %{status: "exited"})
  end

  test "check constraints guard states, statuses, and counts" do
    account = account_fixture()
    credential_fixture(account)
    pool = account |> project_fixture() |> pool_fixture()
    member = member_fixture(pool)
    session = session_fixture(pool, nil)
    exec = exec_fixture(session, member, %{status: "exited"})

    violations = [
      {"UPDATE pool_members SET state = 'stale' WHERE id = $1", member.id, "pool_members_state"},
      {"UPDATE pool_sessions SET status = 'gone' WHERE id = $1", session.id,
       "pool_sessions_status"},
      {"UPDATE pool_sessions SET status = 'expired', end_reason = 'whatever' WHERE id = $1",
       session.id, "pool_sessions_end_reason"},
      {"UPDATE pool_sessions SET wanted = max_members + 1 WHERE id = $1", session.id,
       "pool_sessions_counts"},
      {"UPDATE pool_sessions SET granted_count = -1 WHERE id = $1", session.id,
       "pool_sessions_counts"},
      {"UPDATE pool_execs SET status = 'paused' WHERE id = $1", exec.id, "pool_execs_status"},
      {"UPDATE pools SET min_ready = max_members + 1 WHERE id = $1", pool.id,
       "pools_min_ready_range"},
      {"UPDATE pools SET idle_ttl_ms = 0 WHERE id = $1", pool.id, "pools_idle_ttl_ms_positive"}
    ]

    for {sql, id, constraint} <- violations do
      assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
               Repo.transact(fn -> Repo.query(sql, [Ecto.UUID.dump!(id)]) end)
    end

    assert {:ok, _} =
             Repo.query("UPDATE pool_members SET state = 'abandoned' WHERE id = $1", [
               Ecto.UUID.dump!(member.id)
             ])
  end
end
