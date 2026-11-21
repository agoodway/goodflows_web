defmodule GoodFlows.Repo.Migrations.AddMergedWithoutLeaseToChangeRequests do
  @moduledoc """
  Adds `change_requests.merged_without_lease`: whether the merge report
  named no active, unexpired lease of the change request. It is written
  once with the merge and defaults to false. Change requests merged before
  this migration named no lease, so they are set to true.
  """
  use Ecto.Migration

  def up do
    alter table(:change_requests) do
      add :merged_without_lease, :boolean, null: false, default: false
    end

    execute("UPDATE change_requests SET merged_without_lease = true WHERE state = 'merged'")
  end

  def down do
    alter table(:change_requests) do
      remove :merged_without_lease
    end
  end
end
