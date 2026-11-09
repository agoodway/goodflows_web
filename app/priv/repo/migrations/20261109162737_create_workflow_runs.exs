defmodule GoodFlows.Repo.Migrations.CreateWorkflowRuns do
  @moduledoc """
  Creates `workflow_runs`: one immutable row per uploaded run-history document.

  `project_id` is a composite foreign key `(project_id, account_id)`
  referencing `projects (id, account_id)`, like `test_reports.project_id`.
  It is `ON DELETE NO ACTION`: deleting a project that has runs fails, while
  an account delete (which cascades to both projects and runs) succeeds
  whatever order the cascades fire in.

  Copied columns are the list filters. `parent_run_id`, `caller_job`, a
  result's call fields, and the upload envelope (`graph`, `ci`,
  `source.branch`) stay inside `payload`, so a later migration can copy
  them out without rewriting stored documents. `environment` and `outcome`
  are filterable but unindexed.

  This migration only creates `workflow_runs`. It does not alter existing
  tables. `down` drops the new table and its indexes.
  """
  use Ecto.Migration

  def change do
    create table(:workflow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id,
          references(:projects,
            column: :id,
            with: [account_id: :account_id],
            name: :workflow_runs_project_id_fkey,
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      add :run_id, :uuid, null: false
      add :workflow, :text, null: false
      add :environment, :text
      add :outcome, :text, null: false
      add :started_at, :utc_datetime, null: false
      # bigint: validated integers go up to 2^53 - 1. A PostgreSQL integer
      # overflows at 2^31 - 1 (SQLSTATE 22003), which is not transient.
      add :duration_ms, :bigint, null: false
      add :parallelism, :bigint, null: false
      add :max_in_flight, :bigint, null: false
      add :graph_sha256, :text, null: false
      add :source_commit, :text
      add :source_dirty, :boolean
      # Copied out so a list never reads `payload`.
      add :host, :map, null: false
      add :payload, :map, null: false
      # SHA-256 of the payload's canonical JSON, compared on retries.
      add :payload_digest, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:workflow_runs, [:account_id, :project_id, :run_id],
             name: :workflow_runs_identity_index
           )

    # Default list: started_at DESC, run_id DESC within a project.
    create index(
             :workflow_runs,
             [:account_id, :project_id, desc: :started_at, desc: :run_id],
             name: :workflow_runs_list_index
           )

    # A workflow's history. The graph index cannot serve `workflow` alone,
    # because `graph_sha256` sits between `workflow` and `started_at`.
    create index(
             :workflow_runs,
             [:account_id, :project_id, :workflow, desc: :started_at, desc: :run_id],
             name: :workflow_runs_workflow_list_index
           )

    create index(
             :workflow_runs,
             [
               :account_id,
               :project_id,
               :workflow,
               :graph_sha256,
               desc: :started_at,
               desc: :run_id
             ],
             name: :workflow_runs_workflow_graph_index
           )

    create index(
             :workflow_runs,
             [:account_id, :project_id, :source_commit, desc: :started_at, desc: :run_id],
             name: :workflow_runs_commit_list_index
           )

    # Supports nilify on api key delete.
    create index(:workflow_runs, [:api_key_id], name: :workflow_runs_api_key_id_index)
  end
end
