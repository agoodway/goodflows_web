defmodule GoodFlows.Repo.Migrations.CreateRecipes do
  use Ecto.Migration

  def change do
    create table(:recipes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :text, null: false
      add :setup, {:array, :text}, null: false, default: []
      add :start, {:array, :text}, null: false, default: []
      add :stop, {:array, :text}, null: false, default: []
      add :teardown, {:array, :text}, null: false, default: []

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:recipes, [:account_id, :name])
  end
end
