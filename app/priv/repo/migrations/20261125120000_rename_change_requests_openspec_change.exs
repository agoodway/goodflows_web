defmodule GoodFlows.Repo.Migrations.RenameChangeRequestsOpenspecChange do
  use Ecto.Migration

  def change do
    rename table(:change_requests), :openspec_change, to: :change_id
  end
end
