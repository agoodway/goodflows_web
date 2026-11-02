defmodule GoodFlows.Repo.Migrations.CreateSpritesCredentials do
  use Ecto.Migration

  def change do
    create table(:sprites_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :token, :binary, null: false
      add :last4, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:sprites_credentials, [:account_id])
  end
end
