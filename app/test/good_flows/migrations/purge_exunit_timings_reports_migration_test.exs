defmodule GoodFlows.Migrations.PurgeExunitTimingsReportsMigrationTest do
  # Migrates inside the sandbox transaction, like the other migration tests:
  # this must not run alongside async tests, and the sandbox rollback at the
  # end restores the migrated state even when an assertion fails midway.
  #
  # `down` is irreversible (it raises), so the test "un-applies" the version
  # by deleting its `schema_migrations` row inside the sandbox, inserts rows,
  # and then runs the real `up` through `Ecto.Migrator`.
  use GoodFlows.DataCase, async: false

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures

  alias Ecto.Migrator
  alias GoodFlows.Projects
  alias GoodFlows.TestReports.{Document, Report}

  @version 20_261_105_100_000
  @migration GoodFlows.Repo.Migrations.PurgeExunitTimingsReports

  setup_all do
    # Loaded already when `mix test` ran `ecto.migrate` in this VM.
    unless Code.ensure_loaded?(@migration) do
      Code.require_file(
        "#{@version}_purge_exunit_timings_reports.exs",
        Migrator.migrations_path(Repo)
      )
    end

    :ok
  end

  # `migration_lock: false`: the lock would hold the shared sandbox
  # connection in this process while the migrator's task waits for it.
  defp migrate(direction) do
    Migrator.run(Repo, [{@version, @migration}], direction,
      to: @version,
      log: false,
      migration_lock: false
    )
  end

  defp migrated?, do: @version in Migrator.migrated_versions(Repo)

  defp unapply! do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])
    refute migrated?()
  end

  # `format` is `:absent` for a payload without the key.
  defp insert_report(project, format, report_id) do
    payload = report("complete") |> with_report_id(report_id)

    payload =
      if format == :absent,
        do: Map.delete(payload, "format"),
        else: Map.put(payload, "format", format)

    {1, [%{id: id}]} =
      Repo.insert_all(
        Report,
        [
          %{
            account_id: project.account_id,
            project_id: project.id,
            workflow_run_id: payload["workflow_run_id"],
            workflow: payload["workflow"],
            environment: payload["environment"],
            job: payload["job"],
            job_status: payload["job_status"],
            suite_id: payload["report"]["suite_id"],
            report_id: report_id,
            partition: payload["report"]["partition"],
            partition_count: payload["report"]["partition_count"],
            status: "complete",
            payload: payload,
            payload_digest: Document.digest(payload),
            inserted_at: DateTime.utc_now()
          }
        ],
        returning: [:id]
      )

    id
  end

  defp report_ids, do: Repo.all(from r in Report, select: r.id) |> MapSet.new()

  test "up deletes only exunit-timings rows, in every account" do
    assert migrated?()
    unapply!()

    account_a = account_fixture()
    account_b = account_fixture()
    project_a = project_fixture(account_a)
    project_b = project_fixture(account_b)
    legacy_only = project_fixture(account_a)

    legacy = [
      insert_report(project_a, "exunit-timings", "a-legacy"),
      insert_report(project_b, "exunit-timings", "b-legacy"),
      insert_report(legacy_only, "exunit-timings", "only-legacy")
    ]

    kept = [
      insert_report(project_a, "test-timings/1", "a-current"),
      insert_report(project_b, "test-timings/1", "b-current"),
      insert_report(project_b, "test-timings/2", "b-future"),
      insert_report(project_b, :absent, "b-no-format")
    ]

    before = report_ids()
    assert Projects.delete_project(account_a, legacy_only) == {:error, :has_test_reports}

    assert migrate(:up) == [@version]
    assert migrated?()

    after_up = report_ids()

    # Every non-target row survives, and exactly the legacy rows are gone.
    assert MapSet.difference(before, after_up) == MapSet.new(legacy)
    assert MapSet.size(before) - MapSet.size(after_up) == length(legacy)
    for id <- kept, do: assert(id in after_up)
    for id <- legacy, do: refute(Repo.get(Report, id))

    # A project whose only report was legacy is deletable after the purge.
    assert Projects.delete_project(account_a, legacy_only) == :ok

    # No exunit-timings row is left in any account.
    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM test_reports WHERE payload->>'format' = 'exunit-timings'"
             )
  end

  test "down is irreversible and leaves the version applied" do
    assert migrated?()

    assert_raise Ecto.MigrationError, ~r/irreversible/, fn -> migrate(:down) end

    assert migrated?()
  end
end
