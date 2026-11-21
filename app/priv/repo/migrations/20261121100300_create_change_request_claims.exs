defmodule GoodFlows.Repo.Migrations.CreateChangeRequestClaims do
  @moduledoc """
  Creates `change_request_claims`: one immutable `change-claims/2` file per
  change request and head. `document` is the raw Markdown file,
  `front_matter` its parsed YAML front matter, and `digest` the SHA-256 of
  the raw bytes, compared on retries.
  """
  use Ecto.Migration

  def change do
    create table(:change_request_claims, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :head, :text, null: false
      add :document, :text, null: false
      add :front_matter, :map, null: false
      add :digest, :binary, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:change_request_claims, [:change_request_id, :head],
             name: :change_request_claims_identity_index
           )

    create index(:change_request_claims, [:account_user_id])
    create index(:change_request_claims, [:api_key_id])
  end
end
