defmodule GoodFlows.Repo.Migrations.CreateCacheEntries do
  @moduledoc """
  Creates `cache_entries` (reservations and committed cache entries) and
  `cache_object_deletions`, the queue of objects to delete from object
  storage.

  The project foreign key `(project_id, account_id)` cascades, unlike the
  ones from recipes, test reports and workflow runs: caches never block a
  project delete. An `AFTER DELETE` row trigger queues every deleted row's
  `object_key`, so purge, eviction, expiry and project or account deletes
  all queue the object. The queue row's `delete_after` is the later of now
  and the row's `upload_expires_at`, so an object is never deleted while
  its presigned upload URL could still create it.
  """
  use Ecto.Migration

  def up do
    create table(:cache_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id,
          references(:projects,
            column: :id,
            with: [account_id: :account_id],
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :scope, :text, null: false
      add :key, :text, null: false
      add :partial, :text, null: false
      add :name, :text, null: false
      add :size, :bigint, null: false
      add :sha256, :text, null: false
      add :object_key, :text, null: false
      add :state, :text, null: false

      add :reserved_by_api_key_id,
          references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      add :expires_at, :utc_datetime_usec
      add :upload_expires_at, :utc_datetime_usec, null: false
      add :committed_at, :utc_datetime_usec
      add :last_accessed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:cache_entries, :cache_entries_state_check,
             check: """
             (state = 'reserved' AND expires_at IS NOT NULL AND committed_at IS NULL)
             OR (state = 'committed' AND committed_at IS NOT NULL
                 AND last_accessed_at IS NOT NULL AND expires_at IS NULL)
             """
           )

    create constraint(:cache_entries, :cache_entries_size_check, check: "size > 0")

    create unique_index(:cache_entries, [:project_id, :scope, :key])

    create index(:cache_entries, ["project_id, scope, partial, committed_at DESC, id DESC"],
             where: "state = 'committed'",
             name: :cache_entries_partial_lookup_index
           )

    create index(:cache_entries, [:project_id, :last_accessed_at, :id],
             where: "state = 'committed'",
             name: :cache_entries_eviction_index
           )

    create index(:cache_entries, [:last_accessed_at],
             where: "state = 'committed'",
             name: :cache_entries_retention_index
           )

    create index(:cache_entries, [:expires_at],
             where: "state = 'reserved'",
             name: :cache_entries_reservation_expiry_index
           )

    create index(:cache_entries, [:project_id, :name])
    create index(:cache_entries, [:reserved_by_api_key_id])
    create index(:cache_entries, [:account_id])

    create table(:cache_object_deletions, primary_key: false) do
      add :object_key, :text, primary_key: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")

      add :delete_after, :utc_datetime_usec,
        null: false,
        default: fragment("timezone('UTC', now())")
    end

    create index(:cache_object_deletions, [:delete_after, :object_key])

    execute """
    CREATE FUNCTION cache_entries_queue_object_deletion() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO cache_object_deletions (object_key, inserted_at, delete_after)
      VALUES (OLD.object_key, timezone('UTC', now()), GREATEST(timezone('UTC', now()), OLD.upload_expires_at))
      ON CONFLICT DO NOTHING;
      RETURN OLD;
    END
    $$
    """

    execute """
    CREATE TRIGGER cache_entries_queue_object_deletion
    AFTER DELETE ON cache_entries
    FOR EACH ROW EXECUTE FUNCTION cache_entries_queue_object_deletion()
    """
  end

  def down do
    drop table(:cache_entries)
    execute "DROP FUNCTION cache_entries_queue_object_deletion()"
    drop table(:cache_object_deletions)
  end
end
