defmodule GoodFlows.Migrations.CreateProjectsMigrationTest do
  # Migrates inside the sandbox transaction: the DDL takes exclusive locks on
  # `recipes` and `projects`, so this must not run alongside async tests, and
  # the sandbox rollback at the end restores the fully migrated schema even
  # when an assertion fails midway.
  use GoodFlows.DataCase, async: false

  import GoodFlows.AccountsFixtures
  import GoodFlows.CacheFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Migrator

  @version 20_261_101_190_000
  @migration GoodFlows.Repo.Migrations.CreateProjects

  # `test_reports` and `workflow_runs` reference `projects`, so both are
  # rolled back before `projects`. A composite foreign key makes `projects`
  # down fail while either table still exists.
  @reports_version 20_261_101_200_000
  @reports_migration GoodFlows.Repo.Migrations.CreateTestReports

  @runs_version 20_261_109_162_737
  @runs_migration GoodFlows.Repo.Migrations.CreateWorkflowRuns

  # Cache entries and cache-key columns also reference `projects`, so they
  # are rolled back (newest first) before `projects` and migrated up after.
  @cache_migrations [
    {20_261_118_100_200, GoodFlows.Repo.Migrations.CreateCacheEntries, "create_cache_entries"},
    {20_261_118_100_100, GoodFlows.Repo.Migrations.AddCacheColumnsToApiKeys,
     "add_cache_columns_to_api_keys"},
    {20_261_118_100_000, GoodFlows.Repo.Migrations.AddDefaultBranchToProjects,
     "add_default_branch_to_projects"}
  ]

  setup_all do
    # `mix test` usually loaded them already through `ecto.migrate`;
    # compiling them again would only warn about redefining the modules.
    for {module, file} <-
          [
            {@migration, "#{@version}_create_projects.exs"},
            {@reports_migration, "#{@reports_version}_create_test_reports.exs"},
            {@runs_migration, "#{@runs_version}_create_workflow_runs.exs"}
          ] ++
            for(
              {version, module, name} <- @cache_migrations,
              do: {module, "#{version}_#{name}.exs"}
            ),
        not Code.ensure_loaded?(module) do
      Code.require_file(file, Migrator.migrations_path(Repo))
    end

    :ok
  end

  defp migrate(direction), do: migrate(@version, @migration, direction)

  # `migration_lock: false`: the lock would hold the shared sandbox
  # connection in this process while the migrator's task waits for it.
  defp migrate(version, migration, direction) do
    Migrator.run(Repo, [{version, migration}], direction,
      to: version,
      log: false,
      migration_lock: false
    )
  end

  defp migrated?, do: @version in Migrator.migrated_versions(Repo)

  defp recipe_columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'recipes'"
      )

    List.flatten(rows)
  end

  defp cache_key_rows do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM api_keys WHERE type IN ('cache_read','cache_write')")

    count
  end

  defp key_rows(account_user_id) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM api_keys WHERE account_user_id = $1", [
        Ecto.UUID.dump!(account_user_id)
      ])

    count
  end

  defp table?(name) do
    %{rows: [[exists?]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [name])
    exists?
  end

  test "down and up round-trip; up refuses existing recipes" do
    assert migrated?()

    # `AddCacheColumnsToApiKeys` down deletes cache keys and keeps the rest.
    key_account = account_fixture()
    owner = account_user_fixture(key_account, user_fixture(), :owner)
    {_dashboard_key, _token} = api_key_fixture(owner, %{type: :private})
    cache_key_fixture(key_account, project_fixture(key_account))
    assert cache_key_rows() == 1

    for {version, module, _name} <- @cache_migrations do
      assert migrate(version, module, :down) == [version]

      if module == GoodFlows.Repo.Migrations.AddCacheColumnsToApiKeys do
        assert cache_key_rows() == 0
        assert key_rows(owner.id) == 1
      end
    end

    refute table?("cache_entries")
    refute table?("cache_object_deletions")
    assert migrate(@runs_version, @runs_migration, :down) == [@runs_version]
    refute table?("workflow_runs")
    assert migrate(@reports_version, @reports_migration, :down) == [@reports_version]
    refute table?("test_reports")
    assert migrate(:down) == [@version]
    refute migrated?()
    refute table?("projects")
    refute "project_id" in recipe_columns()

    account = account_fixture()

    Repo.query!(
      "INSERT INTO recipes (id, account_id, name, inserted_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1, 'demo', now(), now())",
      [Ecto.UUID.dump!(account.id)]
    )

    assert_raise Ecto.MigrationError, ~r/Delete or export the existing recipes/, fn ->
      migrate(:up)
    end

    refute migrated?()
    refute table?("projects")

    Repo.query!("DELETE FROM recipes")

    assert migrate(:up) == [@version]
    assert migrated?()
    assert table?("projects")
    assert "project_id" in recipe_columns()
    assert table?("recipes_account_id_index")
    refute table?("recipes_account_id_name_index")

    assert migrate(@reports_version, @reports_migration, :up) == [@reports_version]
    assert table?("test_reports")
    assert migrate(@runs_version, @runs_migration, :up) == [@runs_version]
    assert table?("workflow_runs")

    for {version, module, _name} <- Enum.reverse(@cache_migrations) do
      assert migrate(version, module, :up) == [version]
    end

    assert table?("cache_entries")
    assert table?("cache_object_deletions")
  end

  test "down refuses while two projects of an account share a recipe name" do
    account = account_fixture()
    recipe_fixture(project_fixture(account), %{"name" => "demo"})
    recipe_fixture(project_fixture(account), %{"name" => "demo"})

    assert_raise Ecto.MigrationError, ~r/Rename or delete the duplicates/, fn ->
      migrate(:down)
    end

    assert migrated?()
    assert table?("projects")
    assert "project_id" in recipe_columns()
  end
end
