defmodule GoodFlows.Repo.Migrations.AddCacheColumnsToApiKeys do
  @moduledoc """
  Adds the columns of cache (`ck_`) keys to `api_keys`.

  `project_id` is required for the `cache_read` and `cache_write` types and
  null for every other type. `scope` is allowed only for cache types. A
  project delete deletes its cache keys.

  `down` deletes every cache key first: code without this migration cannot
  load a row of a cache type.
  """
  use Ecto.Migration

  def up do
    alter table(:api_keys) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      add :scope, :text
    end

    create index(:api_keys, [:project_id])

    create constraint(:api_keys, :api_keys_cache_project_check,
             check: "(type IN ('cache_read', 'cache_write')) = (project_id IS NOT NULL)"
           )

    create constraint(:api_keys, :api_keys_cache_scope_check,
             check: "scope IS NULL OR type IN ('cache_read', 'cache_write')"
           )
  end

  def down do
    execute "DELETE FROM api_keys WHERE type IN ('cache_read', 'cache_write')"

    drop constraint(:api_keys, :api_keys_cache_scope_check)
    drop constraint(:api_keys, :api_keys_cache_project_check)
    drop index(:api_keys, [:project_id])

    alter table(:api_keys) do
      remove :scope
      remove :project_id
    end
  end
end
