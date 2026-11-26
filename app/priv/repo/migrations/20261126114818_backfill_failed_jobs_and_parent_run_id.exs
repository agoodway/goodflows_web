defmodule GoodFlows.Repo.Migrations.BackfillFailedJobsAndParentRunId do
  @moduledoc """
  Fills `failed_jobs` and `parent_run_id` from `payload` for rows stored
  before `AddFailedJobsAndParentRunIdToWorkflowRuns`, with
  `GoodFlows.WorkflowRuns.Backfill`.

  It runs outside a migration transaction and without the migration lock,
  one transaction per batch, so uploads continue meanwhile. `down` does
  nothing: the columns are dropped by the schema migration's rollback.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up, do: GoodFlows.WorkflowRuns.Backfill.run(repo())

  def down, do: :ok
end
