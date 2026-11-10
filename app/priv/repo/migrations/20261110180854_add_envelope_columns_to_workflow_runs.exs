defmodule GoodFlows.Repo.Migrations.AddEnvelopeColumnsToWorkflowRuns do
  @moduledoc """
  Copies two parts of the CLI upload envelope out of `payload` so list
  summaries and filters never read `payload`: `source_branch`
  (`source.branch`) and `ci` (the `ci` object, whose `event` is the
  `event` filter). Both are nullable. Rows stored before this migration
  could not carry either key, so no backfill is needed.

  `branch` is a selective filter that CLI history lists use with and
  without `event`, so it gets its own keyset index like `source_commit`.
  `event` has a handful of values (`push`, `pull_request`, ...) and stays
  unindexed, like `environment` and `outcome`.
  """
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :source_branch, :text
      add :ci, :map
    end

    create index(
             :workflow_runs,
             [:account_id, :project_id, :source_branch, desc: :started_at, desc: :run_id],
             name: :workflow_runs_branch_list_index
           )
  end
end
