defmodule GoodFlows.Repo.Migrations.CreateProjectEvents do
  @moduledoc """
  Creates `project_events`: the append-only per-project event feed. The
  bigint identity `id` is the feed cursor; `GoodFlows.ProjectEvents`
  makes ids commit-ordered per project. `change_request_number` is null
  for events that concern no change request. Events go with their
  project; a deleted membership or key leaves the event with a null
  actor.
  """
  use Ecto.Migration

  def change do
    create table(:project_events, primary_key: false) do
      add :id, :bigint, primary_key: true, generated: "ALWAYS AS IDENTITY"

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :change_request_number, :bigint
      add :type, :text, null: false
      add :data, :map, null: false

      add :actor_membership_id,
          references(:account_users, type: :binary_id, on_delete: :nilify_all)

      add :actor_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:project_events, [:project_id, :id])
    create index(:project_events, [:inserted_at])
    create index(:project_events, [:actor_membership_id])
    create index(:project_events, [:actor_key_id])
  end
end
