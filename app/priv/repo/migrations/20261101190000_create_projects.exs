defmodule GoodFlows.Repo.Migrations.CreateProjects do
  @moduledoc """
  Creates `projects` and makes every recipe belong to one.

  `up` refuses to run while `recipes` has rows: it does not invent a project
  for them. Delete or export the existing recipes, or run a backfill
  migration that creates projects and assigns recipes first.

  `recipes.project_id` is a composite foreign key `(project_id, account_id)`
  referencing `projects (id, account_id)`, so a recipe's account always
  matches its project's account. It is `ON DELETE NO ACTION`: deleting a
  project that still has recipes fails, while an account delete (which
  cascades to both projects and recipes) succeeds regardless of the order in
  which the cascades fire, because the check runs at the end of the
  statement.

  `down` restores the per-account `(account_id, name)` unique index, so it
  raises `Ecto.MigrationError` and changes nothing while two projects of one
  account share a recipe name. Rename or delete those recipes first.
  """
  use Ecto.Migration

  def up do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :slug, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:account_id, :slug])
    # Target of the composite recipes foreign key.
    create unique_index(:projects, [:id, :account_id])

    flush()

    %{rows: [[recipe_count]]} = repo().query!("SELECT count(*) FROM recipes")

    if recipe_count > 0 do
      raise Ecto.MigrationError, """
      recipes has #{recipe_count} row(s), and recipes.project_id is NOT NULL with
      no project to assign them to; this migration does not invent one.
      Delete or export the existing recipes, or run a backfill migration that
      creates projects and assigns the recipes before this one, then migrate again.
      """
    end

    alter table(:recipes) do
      add :project_id,
          references(:projects,
            column: :id,
            with: [account_id: :account_id],
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false
    end

    drop index(:recipes, [:account_id, :name])
    create index(:recipes, [:account_id])
    create unique_index(:recipes, [:project_id, :name])
  end

  def down do
    %{rows: duplicates} =
      repo().query!("""
      SELECT a.slug, r.name, count(*)
      FROM recipes r JOIN accounts a ON a.id = r.account_id
      GROUP BY a.slug, r.name
      HAVING count(*) > 1
      ORDER BY a.slug, r.name
      """)

    if duplicates != [] do
      listed =
        Enum.map_join(duplicates, "\n", fn [slug, name, n] -> "  #{slug}: #{name} (#{n})" end)

      raise Ecto.MigrationError, """
      cannot restore the unique index on recipes (account_id, name): these
      accounts have recipes with the same name in different projects:
      #{listed}
      Rename or delete the duplicates, then roll back again.
      """
    end

    drop index(:recipes, [:project_id, :name])

    alter table(:recipes) do
      remove :project_id
    end

    drop index(:recipes, [:account_id])
    create unique_index(:recipes, [:account_id, :name])

    drop table(:projects)
  end
end
