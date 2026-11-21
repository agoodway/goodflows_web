defmodule GoodFlows.Repo.Migrations.CreateChangeRequestEvents do
  @moduledoc """
  Creates `change_request_events`: one immutable row per state change of a
  change request, with the membership and key that made it. Rows are
  deleted with their change request.
  """
  use Ecto.Migration

  def change do
    create table(:change_request_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :from_state, :text, null: false
      add :to_state, :text, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:change_request_events, [:change_request_id, :inserted_at])
    create index(:change_request_events, [:account_user_id])
    create index(:change_request_events, [:api_key_id])
  end
end
