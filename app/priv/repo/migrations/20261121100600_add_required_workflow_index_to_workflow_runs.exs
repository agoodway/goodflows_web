defmodule GoodFlows.Repo.Migrations.AddRequiredWorkflowIndexToWorkflowRuns do
  @moduledoc """
  Indexes the required-workflow query of change request verdicts: the
  newest run of each workflow on one commit of a project
  (`project_id`, `workflow`, `source_commit`, then `started_at DESC,
  run_id DESC`). The list indexes lead with `account_id` and either omit
  `source_commit` or put `workflow` after it, so they would scan a
  workflow's whole history or sort every run of the commit.
  """
  use Ecto.Migration

  def change do
    create index(
             :workflow_runs,
             [:project_id, :workflow, :source_commit, desc: :started_at, desc: :run_id],
             name: :workflow_runs_required_workflow_index
           )
  end
end
