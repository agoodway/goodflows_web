defmodule GoodFlows.Repo.Migrations.CreateVerifyRunArtifacts do
  @moduledoc """
  Creates `verify_run_artifacts` (one row per declared artifact of a
  verify run, deleted with the run) and `verify_run_counts`, the verify
  runs each change request counted in any verdict, for retention.

  Deleting an artifact row whose object was not yet expired queues its
  object in `cache_object_deletions` (trigger), with `delete_after` the
  expiry of its last upload URL, so `GoodFlows.Caches.Sweep` removes it
  from the bucket like a cache object. Retention keeps the row and sets
  `expired` instead.
  """
  use Ecto.Migration

  def up do
    create table(:verify_run_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :verify_run_id, references(:verify_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :artifact_id, :text, null: false
      add :object_key, :text, null: false
      add :size, :bigint, null: false
      add :sha256, :text, null: false
      add :content_type, :text, null: false
      add :expired, :boolean, null: false, default: false
      add :upload_expires_at, :utc_datetime_usec
    end

    create unique_index(:verify_run_artifacts, [:verify_run_id, :artifact_id],
             name: :verify_run_artifacts_run_artifact_index
           )

    create unique_index(:verify_run_artifacts, [:object_key])

    create index(:verify_run_artifacts, [:verify_run_id],
             where: "NOT expired",
             name: :verify_run_artifacts_unexpired_index
           )

    create table(:verify_run_counts, primary_key: false) do
      add :change_request_id,
          references(:change_requests, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :verify_run_id, references(:verify_runs, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:verify_run_counts, [:verify_run_id])

    execute """
    CREATE FUNCTION verify_run_artifacts_queue_object_deletion() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT OLD.expired THEN
        INSERT INTO cache_object_deletions (object_key, inserted_at, delete_after)
        VALUES (OLD.object_key, timezone('UTC', now()),
                GREATEST(timezone('UTC', now()), COALESCE(OLD.upload_expires_at, timezone('UTC', now()))))
        ON CONFLICT DO NOTHING;
      END IF;
      RETURN OLD;
    END
    $$
    """

    execute """
    CREATE TRIGGER verify_run_artifacts_queue_object_deletion
    AFTER DELETE ON verify_run_artifacts
    FOR EACH ROW EXECUTE FUNCTION verify_run_artifacts_queue_object_deletion()
    """
  end

  def down do
    drop table(:verify_run_counts)
    drop table(:verify_run_artifacts)
    execute "DROP FUNCTION verify_run_artifacts_queue_object_deletion()"
  end
end
