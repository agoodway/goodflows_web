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

  # The first insert stays uncommitted until `pg_stat_activity` shows the
  # second statement waiting on it. The 1ms pause only yields the scheduler
  # between those observations.
  test "an uncommitted insert blocks the next ingest until it commits", ctx do
    identical = Map.put(minimal(), "run_id", uuid(100))
    assert_blocked(ctx, identical, identical, :duplicate)

    original = Map.put(minimal(), "run_id", uuid(101))
    assert_blocked(ctx, original, Map.put(original, "duration_ms", 1), :conflict)
  end

  defp assert_blocked(ctx, held, next, outcome) do
    parent = self()
    holder = hold_insert(parent, ctx, held)
    assert_receive {:held, %{id: id}}, 5_000
    assert rows(ctx, held["run_id"]) == 0

    waiter = start_waiter(parent, ctx, next)
    assert_receive {:backend, pid}, 5_000
    send(waiter.pid, :go)

    try do
      await_lock(pid)
      send(holder.pid, :release)
      assert_outcome(Task.await(waiter, 5_000), outcome, id)
    after
      send(holder.pid, :release)
      Task.await(holder, 5_000)
    end

    assert rows(ctx, held["run_id"]) == 1

    if outcome == :conflict do
      assert unboxed(fn -> Repo.get!(Run, id).duration_ms end) == 0
    end
  end

  defp hold_insert(parent, ctx, body) do
    Task.async(fn -> unboxed(fn -> insert_and_hold(parent, ctx, body) end) end)
  end

  defp insert_and_hold(parent, ctx, body) do
    Repo.transaction(fn -> hold_until_release(parent, ctx, body) end)
  end

  defp hold_until_release(parent, ctx, body) do
    {:ok, ack} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, body)
    send(parent, {:held, ack})

    receive do
      :release -> ack
    after
      5_000 -> Repo.rollback(:timed_out)
    end
  end

  defp start_waiter(parent, ctx, body) do
    Task.async(fn ->
      unboxed(fn ->
        %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:backend, pid})

        receive do
          :go -> WorkflowRuns.ingest(ctx.account, ctx.project, nil, body)
        after
          5_000 -> raise "ingest was not started"
        end
      end)
    end)
  end

  defp assert_outcome({:ok, %{id: id, duplicate: true}}, :duplicate, id), do: :ok

  defp assert_outcome({:error, :workflow_run_conflict}, :conflict, _id), do: :ok

  defp assert_outcome(other, outcome, id) do
    flunk("expected #{outcome} for #{id}, got: #{inspect(other)}")
  end

  defp await_lock(pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    spin_until_locked(pid, deadline)
  end

  defp spin_until_locked(pid, deadline) do
    case lock_wait(pid) do
      {"Lock", _event, _state} -> :ok
      other -> retry_lock(pid, deadline, other)
    end
  end

  defp retry_lock(pid, deadline, last) do
    if System.monotonic_time(:millisecond) >= deadline do
      flunk("ingest did not block on the uncommitted insert: #{inspect(last)}")
    else
      receive do
      after
        1 -> spin_until_locked(pid, deadline)
      end
    end
  end

  defp lock_wait(pid) do
    unboxed(fn ->
      case Repo.query!(
             "SELECT wait_event_type, wait_event, state FROM pg_stat_activity WHERE pid = $1",
             [pid]
           ) do
        %{rows: [[type, event, state]]} -> {type, event, state}
        %{rows: []} -> :missing
      end
    end)
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
