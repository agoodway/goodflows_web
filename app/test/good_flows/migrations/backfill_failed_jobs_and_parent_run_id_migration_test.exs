defmodule GoodFlows.Migrations.BackfillFailedJobsAndParentRunIdMigrationTest do
  # Runs the real `up` through `Ecto.Migrator` inside the sandbox
  # transaction: each batch's transaction becomes a savepoint, and the
  # sandbox rollback undoes it. The version is "un-applied" by deleting its
  # `schema_migrations` row inside the sandbox, so this must not run
  # alongside async tests.
  use GoodFlows.DataCase, async: false

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures

  alias Ecto.Migrator
  alias GoodFlows.Repo
  alias GoodFlows.WorkflowRuns.Run

  @version 20_261_126_114_818
  @migration GoodFlows.Repo.Migrations.BackfillFailedJobsAndParentRunId

  @failed "11111111-1111-4111-8111-111111111111"
  @passed "22222222-2222-4222-8222-222222222222"
  @child "33333333-3333-4333-8333-333333333333"
  @parent "44444444-4444-4444-8444-444444444444"

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Code.require_file(
        "#{@version}_backfill_failed_jobs_and_parent_run_id.exs",
        Migrator.migrations_path(Repo)
      )
    end

    :ok
  end

  # `migration_lock: false`: the lock would hold the shared sandbox
  # connection in this process while the migrator's task waits for it.
  defp migrate_up! do
    Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [@version])

    assert [@version] =
             Migrator.run(Repo, [{@version, @migration}], :up,
               to: @version,
               log: false,
               migration_lock: false
             )
  end

  defp result(name, status), do: %{"name" => name, "status" => status}

  defp insert_legacy_row!(account, project, run_id, outcome, payload) do
    stored_run(account, project, %{run_id: run_id, outcome: outcome, payload: payload})
  end

  defp columns do
    Run
    |> select([r], {r.run_id, r.failed_jobs, r.parent_run_id})
    |> Repo.all()
    |> Map.new(fn {run_id, failed_jobs, parent} -> {run_id, {failed_jobs, parent}} end)
  end

  test "fills only failed and called runs, and a second run changes nothing" do
    account = account_fixture()
    project = project_fixture(account)

    insert_legacy_row!(account, project, @failed, "failed", %{
      "results" => [
        result("compile", "passed"),
        result("test", "failed"),
        result("lint", "timed_out"),
        result("deploy", "cancelled"),
        result("test", "failed")
      ]
    })

    insert_legacy_row!(account, project, @passed, "passed", %{
      "results" => [result("compile", "passed"), result("lint", "skipped")]
    })

    insert_legacy_row!(account, project, @child, "passed", %{
      "parent_run_id" => @parent,
      "caller_job" => "call-suite",
      "results" => [result("suite", "passed")]
    })

    before = columns()
    assert before[@failed] == {[], nil}
    assert before[@passed] == {[], nil}
    assert before[@child] == {[], nil}

    migrate_up!()
    first = columns()

    assert first[@failed] == {["test", "lint", "test"], nil}
    assert first[@passed] == before[@passed]
    assert first[@child] == {[], @parent}

    migrate_up!()
    assert columns() == first
  end

  test "the release task fills a legacy row stored after the migration ran" do
    account = account_fixture()
    project = project_fixture(account)
    migrate_up!()

    insert_legacy_row!(account, project, @failed, "failed", %{
      "results" => [result("test", "failed"), result("lint", "timed_out")]
    })

    insert_legacy_row!(account, project, @child, "passed", %{
      "parent_run_id" => @parent,
      "results" => [result("suite", "passed")]
    })

    assert columns()[@failed] == {[], nil}

    assert :ok = GoodFlows.Release.backfill_workflow_runs()

    assert columns()[@failed] == {["test", "lint"], nil}
    assert columns()[@child] == {[], @parent}
  end
end
