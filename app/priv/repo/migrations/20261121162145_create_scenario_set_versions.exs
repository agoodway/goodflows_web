defmodule GoodFlows.Repo.Migrations.CreateScenarioSetVersions do
  @moduledoc """
  Creates `scenario_set_versions`: every version of a change request's
  `qa-scenarios/2` intent or diff set. `content` is the uploaded file byte
  for byte, `digest` the lowercase hex SHA-256 of it, `front_matter` the
  parsed YAML front matter (scenario IDs in string form) and `sections`
  the per-scenario section digests the client sent.

  Versions go with their change request (`ON DELETE CASCADE`).
  `project_id` is copied so verify runs can find a set by project, source
  and digest (`scenario_set_versions_project_digest_index`).
  """
  use Ecto.Migration

  def change do
    create table(:scenario_set_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :source, :text, null: false
      add :version, :bigint, null: false
      add :content, :text, null: false
      add :digest, :text, null: false
      add :front_matter, :map, null: false
      add :sections, :map, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:scenario_set_versions, [:change_request_id, :source, :version],
             name: :scenario_set_versions_change_request_source_version_index
           )

    create index(:scenario_set_versions, [:project_id, :source, :digest],
             name: :scenario_set_versions_project_digest_index
           )

    create index(:scenario_set_versions, [:account_user_id])
    create index(:scenario_set_versions, [:api_key_id])
  end
end
