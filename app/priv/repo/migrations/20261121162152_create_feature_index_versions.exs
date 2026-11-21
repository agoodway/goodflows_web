defmodule GoodFlows.Repo.Migrations.CreateFeatureIndexVersions do
  @moduledoc """
  Creates `feature_index_versions`: the immutable synced feature indexes
  of a project, numbered from 1. `features` is the synced list as sent and
  `digest` its canonical JSON digest. Versions are deleted with their
  project, so they never block a project delete.
  """
  use Ecto.Migration

  def change do
    create table(:feature_index_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :version, :bigint, null: false
      add :features, :map, null: false
      add :digest, :binary, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:feature_index_versions, [:project_id, :version],
             name: :feature_index_versions_project_id_version_index
           )

    create index(:feature_index_versions, [:account_user_id])
    create index(:feature_index_versions, [:api_key_id])
  end
end
