defmodule GoodFlows.Repo.Migrations.CreateDefects do
  @moduledoc """
  Creates `defects`: defects found after change requests merged.

  A defect names the change request it is attributed to (or null), the
  `commit` it was reported against (or null), how it was attributed
  (`change_request`, `commit` or `unattributed`), an optional `severity`
  (`low`, `medium`, `high` or `critical`) and `ticket`, the membership and
  key that recorded it and `recorded_at`. Rows are written once.
  `defects_project_recorded_index` serves the newest-first list.
  """
  use Ecto.Migration

  def change do
    create table(:defects, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all)

      add :commit, :text
      add :attribution, :text, null: false
      add :severity, :text
      add :ticket, :text
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create constraint(:defects, :defects_attribution_check,
             check: "attribution IN ('change_request', 'commit', 'unattributed')"
           )

    create constraint(:defects, :defects_severity_check,
             check: "severity IS NULL OR severity IN ('low', 'medium', 'high', 'critical')"
           )

    create index(:defects, [:project_id, :recorded_at, :id],
             name: :defects_project_recorded_index
           )

    create index(:defects, [:change_request_id])
    create index(:defects, [:account_user_id])
    create index(:defects, [:api_key_id])
  end
end
