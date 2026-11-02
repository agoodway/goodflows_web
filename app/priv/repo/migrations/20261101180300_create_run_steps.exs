defmodule GoodFlows.Repo.Migrations.CreateRunSteps do
  use Ecto.Migration

  def change do
    create table(:run_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :index, :integer, null: false
      add :kind, :string, null: false
      add :command, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :exit_code, :integer
      add :reason, :text
      add :output, :text
      add :output_truncated, :boolean, null: false, default: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:run_steps, [:run_id, :index])

    # Output retention sweep (GoodFlows.Spry.Reaper): finished steps that
    # still hold output.
    create index(:run_steps, [:finished_at],
             where: "output IS NOT NULL",
             name: :run_steps_output_retention_index
           )

    create constraint(:run_steps, :run_steps_kind_check,
             check: "kind IN ('create', 'exec', 'destroy')"
           )

    create constraint(:run_steps, :run_steps_status_check,
             check: "status IN ('pending', 'running', 'succeeded', 'failed', 'skipped')"
           )
  end
end
