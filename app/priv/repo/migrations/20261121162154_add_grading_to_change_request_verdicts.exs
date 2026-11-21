defmodule GoodFlows.Repo.Migrations.AddGradingToChangeRequestVerdicts do
  @moduledoc """
  Adds the grading parts of a stored verdict: `scenarios` (per set its
  version, digest, approval, whether it is graded and each scenario's
  result), `coverage` (feature index version, unmapped areas and mapped
  features) and `counted_runs` (the verify run IDs that counted).
  """
  use Ecto.Migration

  def change do
    alter table(:change_request_verdicts) do
      add :scenarios, :map
      add :coverage, :map
      add :counted_runs, {:array, :text}, null: false, default: fragment("'{}'")
    end
  end
end
