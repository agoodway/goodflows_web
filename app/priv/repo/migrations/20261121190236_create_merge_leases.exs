defmodule GoodFlows.Repo.Migrations.CreateMergeLeases do
  @moduledoc """
  Creates `merge_leases`: merge slot leases per project and target branch.

  A lease names its change request, the target branch, the `head` and
  `base` the client merges, the holder's membership and key, its TTL in
  seconds, `state` (`active`, `released` or `expired`), the
  `release_reason` (`released`, `merged` or `closed`) of a released lease,
  and `acquired_at` and `expires_at`. The partial unique index
  `merge_leases_active_slot_index` allows one `active` lease per project
  and target branch; `merge_leases_active_expiry_index` serves the expiry
  job. Leases go with their change request.
  """
  use Ecto.Migration

  def change do
    create table(:merge_leases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          null: false

      add :target_branch, :text, null: false
      add :head, :text, null: false
      add :base, :text, null: false
      add :account_user_id, references(:account_users, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)
      add :ttl_seconds, :integer, null: false
      add :state, :text, null: false
      add :release_reason, :text
      add :acquired_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create constraint(:merge_leases, :merge_leases_state_check,
             check: "state IN ('active', 'released', 'expired')"
           )

    create constraint(:merge_leases, :merge_leases_release_reason_check,
             check:
               "(state = 'released') = (release_reason IS NOT NULL) AND " <>
                 "(release_reason IS NULL OR release_reason IN ('released', 'merged', 'closed'))"
           )

    create unique_index(:merge_leases, [:project_id, :target_branch],
             where: "state = 'active'",
             name: :merge_leases_active_slot_index
           )

    create index(:merge_leases, [:expires_at],
             where: "state = 'active'",
             name: :merge_leases_active_expiry_index
           )

    create index(:merge_leases, [:change_request_id])
    create index(:merge_leases, [:account_user_id])
    create index(:merge_leases, [:api_key_id])
  end
end
