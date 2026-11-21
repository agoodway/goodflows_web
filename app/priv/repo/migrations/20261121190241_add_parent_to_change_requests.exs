defmodule GoodFlows.Repo.Migrations.AddParentToChangeRequests do
  @moduledoc """
  Adds `change_requests.parent_id`: the one parent change request of a
  stacked change request, or null. A parent has a lower number in the same
  project (checked by `GoodFlows.ChangeRequests.set_parent/3`), so chains
  are acyclic. The index finds a parent's children.
  """
  use Ecto.Migration

  def change do
    alter table(:change_requests) do
      add :parent_id, references(:change_requests, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:change_requests, [:parent_id])
  end
end
