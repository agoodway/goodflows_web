defmodule GoodFlows.Migrations.AddMergedWithoutLeaseMigrationTest do
  # Migrates inside the sandbox transaction, like the other migration tests:
  # not alongside async tests, and the sandbox rollback restores the
  # migrated state even when an assertion fails midway.
  use GoodFlows.DataCase, async: false

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Migrator

  @version 20_261_121_190_238
  @migration GoodFlows.Repo.Migrations.AddMergedWithoutLeaseToChangeRequests

  setup_all do
    unless Code.ensure_loaded?(@migration) do
      Code.require_file(
        "#{@version}_add_merged_without_lease_to_change_requests.exs",
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

  defp insert_cr(project, number, state) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all("change_requests", [
        %{
          id: Ecto.UUID.dump!(id),
          account_id: Ecto.UUID.dump!(project.account_id),
          project_id: Ecto.UUID.dump!(project.id),
          number: number,
          title: "t",
          source_branch: "b#{number}",
          target_branch: "main",
          state: state,
          inserted_at: now,
          updated_at: now
        }
      ])

    id
  end

  defp flag(id) do
    %{rows: [[flag]]} =
      Repo.query!("SELECT merged_without_lease FROM change_requests WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    flag
  end

  test "up flags change requests merged before it and no others" do
    assert migrate(:down) == [@version]
    project = project_fixture(account_fixture())

    merged = insert_cr(project, 1, "merged")

    others =
      for {state, n} <- Enum.with_index(~w(draft open closed), 2),
          do: insert_cr(project, n, state)

    assert migrate(:up) == [@version]
    assert flag(merged) == true
    for id <- others, do: assert(flag(id) == false)
  end
end
