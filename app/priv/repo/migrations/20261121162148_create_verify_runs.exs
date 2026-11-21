defmodule GoodFlows.Repo.Migrations.CreateVerifyRuns do
  @moduledoc """
  Creates `verify_runs`: stored `verify-run/1` documents of a project.

  `project_id` is a composite foreign key `(project_id, account_id)` to
  `projects (id, account_id)` with `ON DELETE NO ACTION`, like
  `workflow_runs`: a project with verify runs cannot be deleted, while an
  account delete cascades to both. `(project_id, run_id)` is unique.

  `status` is `uploading` or `final`. `digest` is the canonical JSON
  digest of the document. The other columns are copied out of it for
  counting runs: `source_commit`, `dirty`, `scenario_set_digest`,
  `scenario_set_source`, `merge_result` (whether a non-null
  `merge_result` was sent) and `finished_at`. `api_key_id` is the
  uploading key, `expires_at` the end of an `uploading` run's commit
  window, and `finalized_at` when it became `final`.
  """
  use Ecto.Migration

  def change do
    create table(:verify_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id,
          references(:projects,
            column: :id,
            with: [account_id: :account_id],
            name: :verify_runs_project_id_fkey,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :run_id, :uuid, null: false
      add :status, :text, null: false
      add :document, :map, null: false
      add :digest, :binary, null: false
      add :source_commit, :text, null: false
      add :dirty, :boolean, null: false
      add :scenario_set_digest, :text, null: false
      add :scenario_set_source, :text, null: false
      add :merge_result, :boolean, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)
      add :expires_at, :utc_datetime_usec
      add :finalized_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:verify_runs, [:project_id, :run_id],
             name: :verify_runs_project_id_run_id_index
           )

    create index(:verify_runs, [:project_id, :source_commit],
             name: :verify_runs_source_commit_index
           )

    create index(:verify_runs, [:project_id, :scenario_set_digest],
             name: :verify_runs_scenario_set_digest_index
           )

    create index(:verify_runs, [:project_id, :finished_at, :run_id],
             name: :verify_runs_list_index
           )

    create index(:verify_runs, [:expires_at],
             where: "status = 'uploading'",
             name: :verify_runs_upload_expiry_index
           )

    create index(:verify_runs, [:account_id])
    create index(:verify_runs, [:account_user_id])
    create index(:verify_runs, [:api_key_id])
  end
end
