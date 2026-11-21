defmodule GoodFlows.Repo.Migrations.AddEventsDeletedThroughToProjects do
  @moduledoc """
  Adds `projects.events_deleted_through`: the highest `project_events.id`
  of the project that the 90-day retention sweep deleted, or null. A feed
  read whose cursor is below it has missed deleted events (`410`).
  """
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :events_deleted_through, :bigint
    end
  end
end
