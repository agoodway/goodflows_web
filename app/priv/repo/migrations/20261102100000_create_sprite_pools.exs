defmodule GoodFlows.Repo.Migrations.CreateSpritePools do
  @moduledoc """
  Creates the Sprite pool tables: `pools`, `pool_sessions`, `pool_members`,
  and `pool_execs`.

  `pools.project_id` is a composite foreign key `(project_id, account_id)`
  referencing `projects (id, account_id)` with `ON DELETE NO ACTION`, like
  `recipes` and `test_reports`: deleting a project that has pools fails
  (`Project.delete_changeset/1` maps it to `{:error, :has_pools}`), while an
  account delete cascades through every table.

  `pool_members.pool_id` is `NO ACTION` too: the reconciler destroys each
  member's sprite and deletes the member rows before the pool row.
  Sessions keep their history after a pool is removed (`pool_id` is
  nilified; `pool_slug` and `project_slug` are copied at creation), and
  execs keep theirs after a member is removed (`member_name` is copied).
  Every `account_id` cascades on account delete.

  CHECK constraints pin the state, status, and end-reason vocabularies and
  the numeric invariants the application relies on (`min_ready <=
  max_members`, `0 <= wanted <= max_members`, `granted_count >= 0`), so a
  buggy write fails loudly instead of corrupting capacity math.
  """
  use Ecto.Migration

  def change do
    create table(:pools, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id,
          references(:projects,
            column: :id,
            with: [account_id: :account_id],
            type: :binary_id,
            on_delete: :nothing
          ),
          null: false

      add :slug, :text, null: false
      add :setup, {:array, :text}, null: false, default: []
      add :min_ready, :integer, null: false, default: 1
      add :max_members, :integer, null: false
      add :setup_version, :integer, null: false, default: 1
      add :deleting_at, :utc_datetime_usec
      add :provision_failures, :integer, null: false, default: 0
      add :next_provision_at, :utc_datetime_usec
      add :last_provision_error, :text
      # Opt-in idle shrink: idle members above demand are retired after this
      # long idle. NULL disables it.
      add :idle_ttl_ms, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:pools, :pools_min_ready_range,
             check: "min_ready >= 0 AND min_ready <= max_members"
           )

    create constraint(:pools, :pools_max_members_positive, check: "max_members >= 1")

    create constraint(:pools, :pools_idle_ttl_ms_positive,
             check: "idle_ttl_ms IS NULL OR idle_ttl_ms > 0"
           )

    # A pool being deleted releases its slug.
    create unique_index(:pools, [:project_id, :slug],
             where: "deleting_at IS NULL",
             name: :pools_project_id_slug_index
           )

    # Serves the composite project foreign key's delete check.
    create index(:pools, [:account_id, :project_id])

    create table(:pool_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :pool_id, references(:pools, type: :binary_id, on_delete: :nilify_all)
      add :api_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)
      add :pool_slug, :text, null: false
      add :project_slug, :text, null: false
      add :credential_fingerprint, :binary, null: false
      add :owner_id, :text
      add :owner_lease_expires_at, :utc_datetime_usec
      add :status, :text, null: false
      add :end_reason, :text
      add :max_members, :integer, null: false
      add :wanted, :integer, null: false
      add :granted_count, :integer, null: false, default: 0
      add :wanting_since, :utc_datetime_usec
      add :label, :text
      add :acquire_deadline_at, :utc_datetime_usec, null: false
      add :first_granted_at, :utc_datetime_usec
      add :workspace_uploaded_at, :utc_datetime_usec
      add :workspace_bytes, :bigint
      add :workspace_sha256, :binary
      add :last_seen_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:pool_sessions, [:pool_id, :status])
    create index(:pool_sessions, [:status])
    create index(:pool_sessions, [:account_id])
    # Serves the ON DELETE SET NULL from api_keys.
    create index(:pool_sessions, [:api_key_id], where: "api_key_id IS NOT NULL")
    # Serves the retention sweep of ended sessions.
    create index(:pool_sessions, [:ended_at], where: "ended_at IS NOT NULL")

    create constraint(:pool_sessions, :pool_sessions_status,
             check: "status IN ('waiting', 'active', 'released', 'expired')"
           )

    create constraint(:pool_sessions, :pool_sessions_end_reason,
             check:
               "end_reason IS NULL OR end_reason IN ('no_member_available', " <>
                 "'client_disconnected', 'lifetime_exceeded', 'key_revoked', " <>
                 "'session_owner_lost')"
           )

    create constraint(:pool_sessions, :pool_sessions_counts,
             check: "granted_count >= 0 AND wanted >= 0 AND wanted <= max_members"
           )

    create table(:pool_members, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :pool_id, references(:pools, type: :binary_id, on_delete: :nothing), null: false
      add :session_id, references(:pool_sessions, type: :binary_id, on_delete: :nilify_all)
      add :name, :text, null: false
      add :state, :text, null: false
      add :setup_version, :integer, null: false
      add :helper_version, :text
      add :arch, :text
      add :golden_checkpoint_id, :text
      add :credential_fingerprint, :binary, null: false
      add :credential_snapshot, :binary, null: false
      add :lease_generation, :integer, null: false, default: 0
      add :workspace_ready_generation, :integer
      add :owner_id, :text
      add :operation_deadline_at, :utc_datetime_usec
      add :last_error, :text
      add :failures, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec
      add :leased_at, :utc_datetime_usec
      add :idle_since, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:pool_members, :pool_members_state,
             check:
               "state IN ('provisioning', 'idle', 'leased', 'resetting', 'broken', " <>
                 "'destroying', 'abandoned')"
           )

    create unique_index(:pool_members, [:name])
    create index(:pool_members, [:pool_id, :state])
    create index(:pool_members, [:session_id])
    create index(:pool_members, [:account_id])

    create table(:pool_execs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :session_id, references(:pool_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :member_id, references(:pool_members, type: :binary_id, on_delete: :nilify_all)
      add :member_name, :text, null: false
      add :lease_generation, :integer, null: false
      add :job, :text
      add :step, :text
      add :status, :text, null: false
      add :exit_code, :integer
      add :outputs, :binary
      add :outputs_truncated, :boolean, null: false, default: false
      add :collect_reports, :boolean, null: false, default: false
      add :reports, :map
      add :reports_truncated, :boolean, null: false, default: false
      add :collect_failed, :boolean, null: false, default: false
      add :owner_id, :text
      add :operation_deadline_at, :utc_datetime_usec
      add :final_output_seq, :bigint, null: false, default: -1
      add :error_reason, :text
      add :duration_ms, :bigint
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :bytes_stdout, :bigint, null: false, default: 0
      add :bytes_stderr, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    # At most one running exec per member, whatever node admits it.
    create unique_index(:pool_execs, [:member_id],
             where: "status = 'running'",
             name: :pool_execs_one_running_per_member_index
           )

    create index(:pool_execs, [:session_id, :status])
    # Serves `Execs.latest_on_member/1` (newest `started_at`, then id).
    create index(:pool_execs, [:member_id, :started_at, :id])
    create index(:pool_execs, [:account_id])

    create constraint(:pool_execs, :pool_execs_status,
             check: "status IN ('running', 'exited', 'timed_out', 'cancelled', 'error')"
           )

    create constraint(:pool_execs, :pool_execs_outputs_size,
             check: "outputs IS NULL OR octet_length(outputs) <= 65537"
           )
  end
end
