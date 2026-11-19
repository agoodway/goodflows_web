defmodule GoodFlows.Repo.Migrations.AddMultipartToCacheEntries do
  @moduledoc """
  Records a reservation's S3 multipart upload on `cache_entries`
  (`multipart_upload_id`, `part_size`, `part_md5s`, all set or all null)
  and in `cache_object_deletions`, so deleting a multipart row queues the
  abort of its upload with the object.

  The deletion trigger function is replaced: a multipart row is queued
  with `delete_after` now (part PUTs cannot create an object, and the sweep
  aborts before it deletes), any other row as before with the later of now
  and its `upload_expires_at`.
  """
  use Ecto.Migration

  def up do
    alter table(:cache_entries) do
      add :multipart_upload_id, :text
      add :part_size, :bigint
      add :part_md5s, {:array, :text}
    end

    create constraint(:cache_entries, :cache_entries_multipart_check,
             check: """
             (multipart_upload_id IS NULL AND part_size IS NULL AND part_md5s IS NULL)
             OR (multipart_upload_id IS NOT NULL AND part_size IS NOT NULL
                 AND part_md5s IS NOT NULL)
             """
           )

    alter table(:cache_object_deletions) do
      add :multipart_upload_id, :text
    end

    execute """
    CREATE OR REPLACE FUNCTION cache_entries_queue_object_deletion() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO cache_object_deletions (object_key, multipart_upload_id, inserted_at, delete_after)
      VALUES (
        OLD.object_key,
        OLD.multipart_upload_id,
        timezone('UTC', now()),
        CASE
          WHEN OLD.multipart_upload_id IS NOT NULL THEN timezone('UTC', now())
          ELSE GREATEST(timezone('UTC', now()), OLD.upload_expires_at)
        END
      )
      ON CONFLICT DO NOTHING;
      RETURN OLD;
    END
    $$
    """
  end

  def down do
    execute """
    CREATE OR REPLACE FUNCTION cache_entries_queue_object_deletion() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      INSERT INTO cache_object_deletions (object_key, inserted_at, delete_after)
      VALUES (OLD.object_key, timezone('UTC', now()), GREATEST(timezone('UTC', now()), OLD.upload_expires_at))
      ON CONFLICT DO NOTHING;
      RETURN OLD;
    END
    $$
    """

    alter table(:cache_object_deletions) do
      remove :multipart_upload_id
    end

    drop constraint(:cache_entries, :cache_entries_multipart_check)

    alter table(:cache_entries) do
      remove :part_md5s
      remove :part_size
      remove :multipart_upload_id
    end
  end
end
