defmodule GoodFlows.TestReportsConcurrencyTest do
  # Not async and outside the SQL sandbox: each racing request needs its own
  # real database connection, so a sandboxed (single-connection) test would
  # run the inserts one after another. Rows are committed for real; the
  # account (cascading to its project and reports) is deleted in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts.Account
  alias GoodFlows.Repo
  alias GoodFlows.TestReports
  alias GoodFlows.TestReports.Report

  @rounds 5

  setup do
    {account, project} =
      unboxed(fn ->
        account = account_fixture()
        {account, project_fixture(account)}
      end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from a in Account, where: a.id == ^account.id) end)
    end)

    %{account: account, project: project}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Each task checks out its own connection, then waits at a barrier until
  # every task holds one, so the inserts start together.
  defp race(ctx, bodies) do
    parent = self()

    tasks = for body <- bodies, do: Task.async(fn -> racer(parent, ctx, body) end)

    for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end

  defp racer(parent, ctx, body), do: unboxed(fn -> ingest_at_barrier(parent, ctx, body) end)

  defp ingest_at_barrier(parent, ctx, body) do
    send(parent, {:ready, self()})

    receive do
      :go -> TestReports.ingest(ctx.account, ctx.project, nil, body)
    end
  end

  defp rows(ctx, report_id) do
    unboxed(fn ->
      Repo.aggregate(
        from(r in Report, where: r.project_id == ^ctx.project.id and r.report_id == ^report_id),
        :count
      )
    end)
  end

  test "concurrent exact retries store one row and acknowledge it to every request", ctx do
    for round <- 1..@rounds do
      body = with_report_id(report("complete"), "race-#{round}")
      results = race(ctx, List.duplicate(body, 4))

      assert [{:ok, %{id: id}} | _] = results
      assert Enum.all?(results, &match?({:ok, %{id: ^id}}, &1)), inspect(results)
      assert Enum.count(results, &match?({:ok, %{duplicate: false}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, %{duplicate: true}}, &1)) == 3
      assert rows(ctx, "race-#{round}") == 1
    end
  end

  test "concurrent different bodies store one row; the other conflicts", ctx do
    for round <- 1..@rounds do
      body = with_report_id(report("complete"), "conflict-#{round}")
      results = race(ctx, [body, Map.put(body, "job_status", "unknown")])

      assert Enum.count(results, &match?({:ok, %{duplicate: false}}, &1)) == 1, inspect(results)
      assert Enum.count(results, &(&1 == {:error, :test_report_conflict})) == 1
      assert rows(ctx, "conflict-#{round}") == 1
    end
  end
end
