defmodule GoodFlows.Repo.Migrations.AddDefaultBranchToProjects do
  @moduledoc """
  Adds `projects.default_branch`, the project's fallback cache scope.

  Existing rows get `main` through the column default; nothing else is
  rewritten.
  """
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :default_branch, :text, null: false, default: "main"
    end
  end
end
