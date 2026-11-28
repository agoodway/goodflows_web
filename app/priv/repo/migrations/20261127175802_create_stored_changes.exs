defmodule GoodFlows.Repo.Migrations.CreateStoredChanges do
  @moduledoc """
  Creates `stored_changes`, one row per goodflows change id of a project
  holding its latest version's listing fields, and
  `stored_change_versions`, every pushed version with its files as sent.
  A stored change blocks its project's deletion; its versions are deleted
  with it.
  """
  use Ecto.Migration

  def change do
    create table(:stored_changes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id), null: false
      add :change_id, :text, null: false
      add :latest_version, :bigint, null: false
      add :status, :text, null: false
      add :size, :text
      add :door, :text
      add :capabilities, {:array, :text}
      add :depends_on, {:array, :text}
      add :last_pushed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:stored_changes, [:project_id, :change_id])

    create index(:stored_changes, [:project_id, "last_pushed_at DESC", :change_id],
             name: :stored_changes_project_id_last_pushed_at_index
           )

    create table(:stored_change_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :stored_change_id,
          references(:stored_changes, type: :binary_id, on_delete: :delete_all),
          null: false

      add :version, :bigint, null: false
      add :status, :text, null: false
      add :size, :text
      add :door, :text
      add :capabilities, {:array, :text}
      add :depends_on, {:array, :text}
      add :files, :map, null: false
      add :digest, :binary, null: false
      add :commit, :text
      add :branch, :text
      add :dirty, :boolean, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:stored_change_versions, [:stored_change_id, :version])
    create index(:stored_change_versions, [:account_user_id])
    create index(:stored_change_versions, [:api_key_id])
  end
end
