defmodule GoodFlows.Repo.Migrations.CreateScenarioSetDecisions do
  @moduledoc """
  Creates `scenario_set_decisions`: the `approve` and `reject` decisions on
  an intent set digest of a change request, oldest first. The `bigserial`
  id orders decisions made in the same microsecond. Decisions go with
  their change request.
  """
  use Ecto.Migration

  def change do
    create table(:scenario_set_decisions) do
      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :digest, :text, null: false
      add :decision, :text, null: false
      add :note, :text
      add :channel, :text, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:scenario_set_decisions, [:change_request_id, :digest, :inserted_at],
             name: :scenario_set_decisions_digest_index
           )

    create index(:scenario_set_decisions, [:account_user_id])
    create index(:scenario_set_decisions, [:api_key_id])
  end
end
