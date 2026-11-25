defmodule GoodFlows.Repo.Migrations.AddDependenciesToChangeRequests do
  @moduledoc """
  Adds `change_requests.dependencies`: the change ids a change request
  depends on, set by `GoodFlows.ChangeRequests.set_dependencies/3`.
  Existing rows get `{}`, so their verdicts do not change.
  """
  use Ecto.Migration

  def change do
    alter table(:change_requests) do
      add :dependencies, {:array, :text}, null: false, default: []
    end
  end
end
