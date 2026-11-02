defmodule GoodFlows.Repo.Migrations.CreateTestReports do
  @moduledoc """
  Creates `test_reports`: one immutable row per uploaded test report.

  `project_id` is a composite foreign key `(project_id, account_id)`
  referencing `projects (id, account_id)`, like `recipes.project_id`, so a
  report's account always matches its project's account. It is
  `ON DELETE NO ACTION` rather than `RESTRICT`: deleting a project that has
  reports fails, while an account delete (which cascades to both projects
  and reports) succeeds whatever order the cascades fire in, because the
  check runs at the end of the statement.

  The `projects` table and its migration are not changed.
  """
  use Ecto.Migration

  def change do
    create table(:test_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id,
          references(:projects,
            column: :id,
            with: [account_id: :account_id],
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      add :workflow_run_id, :uuid, null: false
      add :workflow, :text, null: false
      add :environment, :text
      add :job, :text, null: false
      add :job_status, :text, null: false
      add :suite_id, :text, null: false
      add :report_id, :text, null: false
      add :partition, :text
      # bigint: validated integers go up to 2^53 - 1.
      add :partition_count, :bigint
      add :status, :text, null: false
      add :payload, :map, null: false
      # SHA-256 of the payload's canonical JSON, compared on retries.
      add :payload_digest, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(
             :test_reports,
             [:account_id, :project_id, :workflow_run_id, :job, :report_id],
             name: :test_reports_identity_index
           )

    # The identity index and this one lead with (account_id, project_id),
    # which serves the composite project foreign key's delete check.
    create index(:test_reports, [:account_id, :project_id, :inserted_at])
    # Supports nilify on api key delete.
    create index(:test_reports, [:api_key_id])

    create constraint(:test_reports, :test_reports_status_check,
             check: "status IN ('complete', 'incomplete')"
           )
  end
end
