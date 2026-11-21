defmodule GoodFlows.Repo.Migrations.CreateChangeRequestVerdicts do
  @moduledoc """
  Creates `change_request_verdicts`: the current verdict of each change
  request, one row per change request, replaced on every recompute.
  `reasons` is a JSON array and `inputs` the digests the verdict was
  computed from.
  """
  use Ecto.Migration

  def change do
    create table(:change_request_verdicts, primary_key: false) do
      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :state, :text, null: false
      add :head, :text
      add :policy_version, :bigint, null: false
      add :reasons, :map, null: false
      add :inputs, :map, null: false
      add :computed_at, :utc_datetime_usec, null: false
    end
  end
end
