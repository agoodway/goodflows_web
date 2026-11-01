defmodule GoodFlows.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :recipe_id, references(:recipes, type: :binary_id, on_delete: :nilify_all)
      add :phase, :string, null: false
      add :sprite_name, :text, null: false
      add :inputs, :map, null: false, default: %{}
      add :no_create, :boolean, null: false, default: false
      add :no_destroy, :boolean, null: false, default: false
      add :plan, :map, null: false
      add :status, :string, null: false, default: "queued"
      add :error, :text
      add :owner_id, :string
      add :pgflow_run_id, :binary_id
      add :started_at, :utc_datetime_usec
      add :action_started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :reaper_checked_at, :utc_datetime_usec

      add :started_by_api_key_id,
          references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runs, [:account_id, :inserted_at])
    create index(:runs, [:recipe_id, :inserted_at])
    # The reaper's two queries: old queued runs, and running runs ordered by
    # last investigation then action age.
    create index(:runs, [:status, :inserted_at],
             where: "status = 'queued'",
             name: :runs_queued_inserted_at_index
           )

    create index(:runs, ["reaper_checked_at ASC NULLS FIRST", :action_started_at, :id],
             where: "status = 'running'",
             name: :runs_running_reaper_index
           )

    create index(:runs, [:started_by_api_key_id])

    create unique_index(:runs, [:account_id, :sprite_name],
             where: "status IN ('queued', 'running')",
             name: :runs_one_active_per_sprite_index
           )

    create constraint(:runs, :runs_status_check,
             check: "status IN ('queued', 'running', 'succeeded', 'failed')"
           )

    create constraint(:runs, :runs_phase_check,
             check: "phase IN ('setup', 'start', 'stop', 'teardown')"
           )
  end
end
