defmodule GoodFlows.Repo.Migrations.CreateReviewPolicyVersions do
  @moduledoc """
  Creates `review_policy_versions`: the immutable `review-policy/1`
  versions of a project, numbered from 1 (version 0 is the default and is
  never stored). Versions are deleted with their project, so they never
  block a project delete.
  """
  use Ecto.Migration

  def change do
    create table(:review_policy_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :version, :bigint, null: false
      add :document, :map, null: false
      add :previous_version, :bigint, null: false
      add :note, :text
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:review_policy_versions, [:project_id, :version],
             name: :review_policy_versions_project_id_version_index
           )

    create index(:review_policy_versions, [:account_user_id])
    create index(:review_policy_versions, [:api_key_id])
  end
end
