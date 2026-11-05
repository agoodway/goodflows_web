defmodule GoodFlows.Repo.Migrations.PurgeExunitTimingsReports do
  @moduledoc """
  Deletes every stored `exunit-timings` test report.

  The server now accepts only `test-timings/1`, the runner-neutral contract
  goodflows v0.6.0 publishes. Storage has no read API, so a legacy row would
  only keep its project undeletable and leave any future reader with two
  payload shapes. The delete filters on the payload's `format` instead of
  truncating, so a `test-timings/1` row stored by a node already running the
  new code is kept.

  This is irreversible: `down` raises `Ecto.MigrationError`, because the
  purged rows cannot be restored. The delete must run only after every node
  that still accepts `exunit-timings` uploads has been stopped (in a rolling
  deploy, stop the old nodes before migrating). There is no second purge, so
  a row an old node inserts after this migration stays in place (and keeps
  blocking its project's deletion).
  """
  use Ecto.Migration

  @doc "The purge statement `up` runs."
  def purge_sql, do: "DELETE FROM test_reports WHERE payload->>'format' = 'exunit-timings'"

  def up, do: execute(purge_sql())

  def down do
    raise Ecto.MigrationError, """
    PurgeExunitTimingsReports is irreversible: the purged exunit-timings test
    reports cannot be restored. Roll back past it only by restoring a database
    backup taken before the purge.
    """
  end
end
