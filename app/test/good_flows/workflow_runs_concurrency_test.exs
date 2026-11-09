defmodule GoodFlows.WorkflowRunsConcurrencyTest do
  # Not async and outside the SQL sandbox: each racing request needs its own
  # real database connection, so a sandboxed test would run the inserts one
  # after another. Rows are committed for real; the account (cascading to
  # its project and runs) is deleted in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts.Account
  alias GoodFlows.Repo
  alias GoodFlows.WorkflowRuns
  alias GoodFlows.WorkflowRuns.Run

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
      :go -> WorkflowRuns.ingest(ctx.account, ctx.project, nil, body)
    end
  end

  defp rows(ctx, run_id) do
    unboxed(fn ->
      Repo.aggregate(
        from(r in Run, where: r.project_id == ^ctx.project.id and r.run_id == ^run_id),
        :count
      )
    end)
  end

  defp run_id(round, "same"), do: uuid(round)
  defp run_id(round, "diff"), do: uuid(round + @rounds)

  defp uuid(n) do
    suffix = n |> Integer.to_string() |> String.pad_leading(12, "0")
    "aaaaaaaa-aaaa-4aaa-8aaa-#{suffix}"
  end

  test "concurrent identical uploads store one row", ctx do
    for round <- 1..@rounds do
      id = run_id(round, "same")
      body = Map.put(minimal(), "run_id", id)
      results = race(ctx, [body, body])

      assert [{:ok, %{id: stored_id}} | _] = results
      assert Enum.all?(results, &match?({:ok, %{id: ^stored_id}}, &1)), inspect(results)
      assert Enum.count(results, &match?({:ok, %{duplicate: false}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, %{duplicate: true}}, &1)) == 1
      assert rows(ctx, id) == 1
    end
  end

  test "concurrent uploads that differ in duration_ms store one row and conflict", ctx do
    for round <- 1..@rounds do
      id = run_id(round, "diff")
      body = Map.put(minimal(), "run_id", id)
      other = Map.put(body, "duration_ms", 1)
      results = race(ctx, [body, other])

      assert Enum.count(results, &match?({:ok, %{duplicate: false}}, &1)) == 1, inspect(results)
      assert Enum.count(results, &(&1 == {:error, :workflow_run_conflict})) == 1
      assert rows(ctx, id) == 1
    end
  end
end
