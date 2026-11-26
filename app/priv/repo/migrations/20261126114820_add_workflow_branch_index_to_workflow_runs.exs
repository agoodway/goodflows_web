defmodule GoodFlows.Repo.Migrations.AddWorkflowBranchIndexToWorkflowRuns do
  @moduledoc """
  Indexes the project overview's default branch health: the newest run of
  each workflow on one branch (`account_id`, `project_id`, `workflow`,
  `source_branch`, then `started_at DESC, run_id DESC`). Without
  `source_branch` in the index, a workflow that seldom or never runs on
  the branch would be read through its whole history on every overview
  load.

  The index is built concurrently, so uploads continue while it builds.
  `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, hence
  `@disable_ddl_transaction` and `@disable_migration_lock`.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(
             :workflow_runs,
             [
               :account_id,
               :project_id,
               :workflow,
               :source_branch,
               desc: :started_at,
               desc: :run_id
             ],
             name: :workflow_runs_workflow_branch_index,
             concurrently: true
           )
  end
end
