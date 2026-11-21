defmodule GoodFlows.Repo.Migrations.CreateChangeRequestGitFacts do
  @moduledoc """
  Creates `change_request_git_facts`: one immutable `git-facts/1` report
  per change request, head and target branch. `digest` is the SHA-256 of
  the document's canonical JSON (`GoodFlows.JsonDocument.digest/1`),
  compared on retries.
  """
  use Ecto.Migration

  def change do
    create table(:change_request_git_facts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :head, :text, null: false
      add :target_branch, :text, null: false
      add :document, :map, null: false
      add :digest, :binary, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:change_request_git_facts, [:change_request_id, :head, :target_branch],
             name: :change_request_git_facts_identity_index
           )

    create index(:change_request_git_facts, [:account_user_id])
    create index(:change_request_git_facts, [:api_key_id])
  end
end
