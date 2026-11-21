defmodule GoodFlows.Repo.Migrations.AddReviewToChangeRequestVerdicts do
  @moduledoc """
  Adds `change_request_verdicts.review`: the number of review packet
  items at the verdict's head and how many have a current `approve` or
  `choose` answer there.
  """
  use Ecto.Migration

  def change do
    alter table(:change_request_verdicts) do
      add :review, :map
    end
  end
end
