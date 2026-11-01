defmodule GoodFlows.Migrations.CreateProjectsMigrationTest do
  # Migrates inside the sandbox transaction: the DDL takes exclusive locks on
  # `recipes` and `projects`, so this must not run alongside async tests, and
  # the sandbox rollback at the end restores the fully migrated schema even
  # when an assertion fails midway.
  use GoodFlows.DataCase, async: false

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Migrator

  @version 20_261_101_190_000
  @migration GoodFlows.Repo.Migrations.CreateProjects

  setup_all do
    # `mix test` usually loaded it already through `ecto.migrate`; compiling
    # it again would only warn about redefining the module.
    unless Code.ensure_loaded?(@migration) do
      Code.require_file("#{@version}_create_projects.exs", Migrator.migrations_path(Repo))
    end

    :ok
  end

  # `migration_lock: false`: the lock would hold the shared sandbox
  # connection in this process while the migrator's task waits for it.
  defp migrate(direction) do
    Migrator.run(Repo, [{@version, @migration}], direction,
      to: @version,
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

  defp table?(name) do
    %{rows: [[exists?]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [name])
    exists?
  end

  test "down and up round-trip; up refuses existing recipes" do
    assert migrated?()
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
