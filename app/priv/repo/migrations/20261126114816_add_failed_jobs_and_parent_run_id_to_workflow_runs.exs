defmodule GoodFlows.Repo.Migrations.AddFailedJobsAndParentRunIdToWorkflowRuns do
  @moduledoc """
  Copies two more values out of `payload` so the dashboard's run list never
  reads it:

    * `failed_jobs`: each result `name` whose status is `failed` or
      `timed_out`, in result order. `text[] NOT NULL DEFAULT '{}'`; a
      constant default is a catalog-only change, so no row is rewritten.
    * `parent_run_id`: the run that called this one, or null.

  The partial index `workflow_runs_parent_index` serves the lookup of the
  runs a page of parents called. Rows stored before this migration are
  filled by `BackfillFailedJobsAndParentRunId`.

  The rollback is for development only. In production the columns stay
  when the code is rolled back; they can be rebuilt from `payload` only by
  running the backfill again.
  """
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :failed_jobs, {:array, :text}, null: false, default: fragment("'{}'")
      add :parent_run_id, :uuid
    end

    create index(:workflow_runs, [:project_id, :parent_run_id],
             name: :workflow_runs_parent_index,
             where: "parent_run_id IS NOT NULL"
           )
  end
end
