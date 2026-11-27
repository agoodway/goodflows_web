defmodule GoodFlows.StoredChangesConcurrencyTest do
  # Not async and outside the SQL sandbox: each racer needs its own
  # connection, or the locks would never contend. Racers check out their
  # connection after the barrier, so more racers than the pool holds
  # queue for one instead of deadlocking. Rows are committed and
  # deleted in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.{Account, User}
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.Repo
  alias GoodFlows.StoredChanges
  alias GoodFlows.StoredChanges.{Change, Version}

  setup do
    ctx =
      unboxed(fn ->
        user = user_fixture()
        {:ok, account} = Accounts.create_account(user, %{name: "Race #{System.unique_integer()}"})
        account_user = Accounts.get_account_user(user, account)
        {api_key, _token} = api_key_fixture(account_user, %{type: :private})
        %{account: account, user: user, api_key: api_key, project: project_fixture(account)}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from c in Change, where: c.project_id == ^ctx.project.id)
        Repo.delete_all(from c in ChangeRequest, where: c.account_id == ^ctx.account.id)
        Repo.delete_all(from a in Account, where: a.id == ^ctx.account.id)
        Repo.delete_all(from u in User, where: u.id == ^ctx.user.id)
      end)
    end)

    ctx
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp race(count, fun) do
    parent = self()

    tasks =
      for i <- 1..count do
        Task.async(fn -> await_go(parent, fun, i) end)
      end

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    Task.await_many(tasks, 15_000)
  end

  defp await_go(parent, fun, i) do
    send(parent, {:ready, self()})
    receive do: (:go -> unboxed(fn -> fun.(i) end))
  end

  defp body(id, text) do
    %{
      "files" => %{
        "change.md" =>
          "---\nformat: goodflows-change/1\nid: #{id}\nstatus: proposed\n---\n#{text}\n"
      },
      "source" => %{"commit" => nil, "branch" => nil, "dirty" => true}
    }
  end

  test "concurrent pushes each get their own consecutive version", ctx do
    results = race(10, &StoredChanges.push(ctx.project, ctx.api_key, body("add-login", "#{&1}")))

    assert Enum.all?(results, &match?({:ok, :created, _version, _replaced}, &1))

    versions =
      unboxed(fn ->
        Repo.all(from v in Version, order_by: v.version, select: {v.version, v.files})
      end)

    assert Enum.map(versions, &elem(&1, 0)) == Enum.to_list(1..10)

    texts = versions |> Enum.map(fn {_n, files} -> files["change.md"] end) |> Enum.sort()

    assert texts ==
             1..10 |> Enum.map(&body("add-login", "#{&1}")["files"]["change.md"]) |> Enum.sort()

    replaced =
      for {:ok, :created, _v, number} <- results, number != nil, do: number

    assert Enum.count(results, &match?({:ok, :created, _v, nil}, &1)) == 1
    assert Enum.sort(replaced) == Enum.to_list(1..9)
  end

  # Each racer reports its backend pid, so the test can wait until
  # Postgres shows it blocked on a lock instead of guessing with sleeps.
  defp start(fun) do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, self(), pid})
          fun.()
        end)
      end)

    receive do: ({:backend, _task_pid, pid} -> {task, pid})
  end

  defp hold(fun) do
    parent = self()

    start(fn ->
      Repo.transaction(fn ->
        fun.()
        send(parent, :held)
        receive do: (:release -> :ok)
      end)
    end)
    |> tap(fn _ -> assert_receive :held, 5_000 end)
  end

  defp release({task, _pid}) do
    send(task.pid, :release)
    Task.await(task, 15_000)
  end

  defp open_change_request(ctx) do
    ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, %{
      "title" => "Login",
      "source_branch" => "feat/login",
      "change_id" => "add-login"
    })
  end

  # True once `pid` waits on a lock, false if `task` finished first.
  defp blocked?({task, pid}, tries \\ 500) do
    waiting =
      unboxed(fn ->
        Repo.exists?(from l in "pg_locks", where: l.pid == ^pid and not l.granted)
      end)

    cond do
      waiting -> true
      Task.yield(task, 0) != nil or tries == 0 -> false
      true -> Process.sleep(10) && blocked?({task, pid}, tries - 1)
    end
  end

  defp stored?(ctx) do
    unboxed(fn -> Repo.exists?(from c in Change, where: c.project_id == ^ctx.project.id) end)
  end

  test "a change request open waits for a delete that has checked the links", ctx do
    {:ok, :created, _version, nil} =
      unboxed(fn -> StoredChanges.push(ctx.project, ctx.api_key, body("add-login", "v1")) end)

    # A row lock stops the delete after its link check, before it commits.
    row =
      hold(fn ->
        Repo.query!("SELECT 1 FROM stored_changes WHERE project_id = $1 FOR UPDATE", [
          Ecto.UUID.dump!(ctx.project.id)
        ])
      end)

    delete = start(fn -> StoredChanges.delete(ctx.project, ctx.api_key, "add-login") end)
    assert blocked?(delete)

    # Without the per-id lock the open would commit now, before the delete,
    # and the delete would still succeed with a change request linking it.
    open = start(fn -> open_change_request(ctx) end)
    assert blocked?(open), "the change request committed while the delete held the id"

    release(row)
    assert Task.await(elem(delete, 0), 15_000) == :ok
    assert {:ok, %ChangeRequest{change_id: "add-login"}} = Task.await(elem(open, 0), 15_000)
    refute stored?(ctx)
  end

  test "a change request committed before the delete commits makes it 409", ctx do
    {:ok, :created, _version, nil} =
      unboxed(fn -> StoredChanges.push(ctx.project, ctx.api_key, body("add-login", "v1")) end)

    # Postgres grants a held advisory lock to its waiters in queue order,
    # so the open, queued first, commits before the delete runs.
    lock = hold(fn -> ChangeRequests.lock_change_id(ctx.project.id, "add-login") end)

    open = start(fn -> open_change_request(ctx) end)
    assert blocked?(open)

    delete = start(fn -> StoredChanges.delete(ctx.project, ctx.api_key, "add-login") end)
    assert blocked?(delete), "the delete ran while another transaction held the id"

    release(lock)
    assert {:ok, %ChangeRequest{number: number}} = Task.await(elem(open, 0), 15_000)

    assert Task.await(elem(delete, 0), 15_000) ==
             {:error, {:stored_change_linked, [%{number: number, state: "draft"}]}}

    assert stored?(ctx)
  end
end
