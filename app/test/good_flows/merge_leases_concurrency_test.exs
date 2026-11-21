defmodule GoodFlows.MergeLeasesConcurrencyTest do
  # Not async and outside the SQL sandbox: each racer needs its own
  # connection, or the locks would never contend. Rows are committed and
  # the accounts (cascading to their projects) are deleted in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.{Account, User}
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.MergeLeases
  alias GoodFlows.MergeLeases.Lease
  alias GoodFlows.Repo

  setup do
    ctx =
      unboxed(fn ->
        user = user_fixture()

        {:ok, account} =
          Accounts.create_account(user, %{name: "Lease #{System.unique_integer()}"})

        account_user = Accounts.get_account_user(user, account)
        {api_key, _token} = api_key_fixture(account_user, %{type: :private})

        %{
          account: account,
          user: user,
          api_key: api_key,
          project: project_fixture(account),
          other_project: project_fixture(account)
        }
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from c in ChangeRequest, where: c.account_id == ^ctx.account.id)
        Repo.delete_all(from a in Account, where: a.id == ^ctx.account.id)
        Repo.delete_all(from u in User, where: u.id == ^ctx.user.id)
      end)
    end)

    ctx
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # An open change request of `project` targeting `target`, mergeable at `head`.
  defp mergeable(ctx, project, head, target) do
    unboxed(fn ->
      {:ok, cr} =
        ChangeRequests.create(ctx.account, project, ctx.api_key, %{
          "title" => "t",
          "source_branch" => "b#{System.unique_integer([:positive])}",
          "target_branch" => target
        })

      {:ok, cr} = ChangeRequests.transition(cr, ctx.api_key, :ready)

      {:ok, :created, cr} =
        ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(head, target: target))

      claims = claims(front_matter(head, %{"cr" => cr.number}))
      {:ok, :created, cr} = ChangeRequests.upload_claims(cr, ctx.api_key, claims)
      assert ChangeRequests.verdict(cr).state == "mergeable"
      cr
    end)
  end

  defp race(funs) do
    parent = self()

    tasks = for fun <- funs, do: Task.async(fn -> racer(parent, fun) end)

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    Task.await_many(tasks, 15_000)
  end

  defp racer(parent, fun), do: unboxed(fn -> at_barrier(parent, fun) end)

  defp at_barrier(parent, fun) do
    send(parent, {:ready, self()})

    receive do
      :go -> fun.()
    end
  end

  defp acquire(ctx, cr, head),
    do: fn -> MergeLeases.acquire(cr, ctx.api_key, %{"head" => head, "base" => sha(0)}) end

  defp active(project_id, branch) do
    unboxed(fn ->
      Repo.aggregate(
        from(l in Lease,
          where:
            l.project_id == ^project_id and l.target_branch == ^branch and l.state == "active"
        ),
        :count
      )
    end)
  end

  defp backend_pid, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  # Takes `lock` in a transaction on its own connection and holds it until
  # `release/1`.
  defp gate(lock) do
    parent = self()

    task = Task.async(fn -> unboxed(fn -> hold(parent, lock) end) end)

    pid = task.pid
    receive do: ({:held, ^pid, backend} -> %{task: task, backend: backend})
  end

  defp hold(parent, lock) do
    Repo.transaction(fn ->
      lock.()
      send(parent, {:held, self(), backend_pid()})
      receive do: (:release -> :ok)
    end)
  end

  defp release(gate) do
    send(gate.task.pid, :release)
    Task.await(gate.task)
  end

  # Runs `fun` on its own connection; `backend` is that connection's pid.
  defp actor(fun) do
    parent = self()

    task =
      Task.async(fn ->
        unboxed(fn ->
          send(parent, {:backend, self(), backend_pid()})
          fun.()
        end)
      end)

    pid = task.pid
    receive do: ({:backend, ^pid, backend} -> %{task: task, backend: backend})
  end

  defp await_blocked(actor, gate, tries \\ 1000) do
    %{rows: [[blocked]]} =
      unboxed(fn ->
        Repo.query!("SELECT $2::int = ANY(pg_blocking_pids($1::int))", [
          actor.backend,
          gate.backend
        ])
      end)

    cond do
      blocked ->
        :ok

      tries == 0 ->
        flunk("the actor never waited on the gate")

      true ->
        Process.sleep(5)
        await_blocked(actor, gate, tries - 1)
    end
  end

  defp slot_lock(project_id, branch) do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('merge_slot:' || $1 || ':' || $2, 0))",
      [project_id, branch]
    )
  end

  defp row_lock(id),
    do: Repo.one!(from c in ChangeRequest, where: c.id == ^id, lock: "FOR NO KEY UPDATE")

  defp update!(id, set),
    do: unboxed(fn -> Repo.update_all(from(c in ChangeRequest, where: c.id == ^id), set: set) end)

  defp reload(cr), do: unboxed(fn -> Repo.get!(ChangeRequest, cr.id) end)

  # Acquires for `cr` while it is retargeted before each of the three
  # attempts locks it: each attempt waits on the slot lock of the branch it
  # read, held by a gate, while `cr` moves to the next branch. The last
  # move also applies `last` and ends on `moved-3`.
  defp acquire_through_retargets(ctx, cr, head, last \\ []) do
    gates = for b <- ~w(main moved-1 moved-2), do: gate(fn -> slot_lock(ctx.project.id, b) end)
    a = actor(fn -> MergeLeases.acquire(cr, ctx.api_key, %{"head" => head, "base" => sha(0)}) end)

    for {gate, next} <- Enum.zip(gates, ~w(moved-1 moved-2 moved-3)) do
      await_blocked(a, gate)
      update!(cr.id, [target_branch: next] ++ if(next == "moved-3", do: last, else: []))
      release(gate)
    end

    Task.await(a.task, 15_000)
  end

  describe "an acquire retargeted under every attempt" do
    test "with a free final slot is slot_taken without a holder", ctx do
      cr = mergeable(ctx, ctx.project, sha(1), "main")

      assert {:error, {:coded_conflict, "slot_taken", extra}} =
               acquire_through_retargets(ctx, cr, sha(1))

      assert extra == %{}
    end

    test "closed by the last attempt is not_open", ctx do
      cr = mergeable(ctx, ctx.project, sha(1), "main")

      assert {:error, {:coded_conflict, "not_open", %{}}} =
               acquire_through_retargets(ctx, cr, sha(1), state: "closed")
    end

    test "with a new head by the last attempt is stale_head with that head", ctx do
      cr = mergeable(ctx, ctx.project, sha(1), "main")

      assert {:error, {:coded_conflict, "stale_head", %{head: head}}} =
               acquire_through_retargets(ctx, cr, sha(1), head: sha(9))

      assert head == sha(9)
    end

    test "onto a live lease of another change request names that holder", ctx do
      holder = mergeable(ctx, ctx.project, sha(2), "moved-3")
      {:ok, :created, _} = unboxed(acquire(ctx, holder, sha(2)))
      cr = mergeable(ctx, ctx.project, sha(1), "main")

      assert {:error, {:coded_conflict, "slot_taken", %{holder: %{change_request: number}}}} =
               acquire_through_retargets(ctx, cr, sha(1))

      assert number == holder.number
    end

    test "onto an expired lease is slot_taken without a holder", ctx do
      holder = mergeable(ctx, ctx.project, sha(2), "moved-3")
      {:ok, :created, lease} = unboxed(acquire(ctx, holder, sha(2)))
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      unboxed(fn ->
        Repo.update_all(from(l in Lease, where: l.id == ^lease.id), set: [expires_at: past])
      end)

      cr = mergeable(ctx, ctx.project, sha(1), "main")

      assert {:error, {:coded_conflict, "slot_taken", extra}} =
               acquire_through_retargets(ctx, cr, sha(1))

      assert extra == %{}
    end

    test "onto its own lease with the same key and head is the retry", ctx do
      cr = mergeable(ctx, ctx.project, sha(1), "moved-3")
      {:ok, :created, lease} = unboxed(acquire(ctx, cr, sha(1)))
      update!(cr.id, target_branch: "main")

      assert {:ok, :retry, %Lease{id: id}} = acquire_through_retargets(ctx, reload(cr), sha(1))
      assert id == lease.id
    end
  end

  describe "a retarget whose parent link changes before it locks the child" do
    test "restarts and grades the new parent", ctx do
      merged = mergeable(ctx, ctx.project, sha(1), "main")
      open = mergeable(ctx, ctx.project, sha(2), "main")
      child = mergeable(ctx, ctx.project, sha(3), "feat/a")
      update!(merged.id, state: "merged")
      update!(child.id, parent_id: merged.id)
      child = reload(child)

      gate = gate(fn -> row_lock(merged.id) end)

      a =
        actor(fn -> ChangeRequests.retarget(child, ctx.api_key, %{"target_branch" => "main"}) end)

      await_blocked(a, gate)
      update!(child.id, parent_id: open.id)
      release(gate)

      assert {:error, {:coded_conflict, "parent_not_merged", %{}}} = Task.await(a.task, 15_000)
      assert reload(child).target_branch == "feat/a"
    end

    test "under every one of three attempts is not_editable", ctx do
      [p1, p2, p3, p4] = for i <- 1..4, do: mergeable(ctx, ctx.project, sha(i), "main")
      child = mergeable(ctx, ctx.project, sha(5), "feat/a")
      update!(child.id, parent_id: p1.id)
      child = reload(child)

      gates = for p <- [p1, p2, p3], do: gate(fn -> row_lock(p.id) end)

      a =
        actor(fn -> ChangeRequests.retarget(child, ctx.api_key, %{"target_branch" => "main"}) end)

      for {gate, next} <- Enum.zip(gates, [p2, p3, p4]) do
        await_blocked(a, gate)
        update!(child.id, parent_id: next.id)
        release(gate)
      end

      assert {:error, {:coded_conflict, "not_editable", %{}}} = Task.await(a.task, 15_000)
      assert reload(child).target_branch == "feat/a"
    end
  end

  defp insert_cr!(ctx, id, number, parent_id) do
    unboxed(fn ->
      Repo.insert!(%ChangeRequest{
        id: id,
        account_id: ctx.account.id,
        project_id: ctx.project.id,
        number: number,
        title: "t",
        source_branch: "b#{number}",
        target_branch: "main",
        state: "open",
        parent_id: parent_id
      })
    end)
  end

  defp rescued(fun) do
    fun.()
  rescue
    e -> {:raised, e}
  end

  # The child's id sorts before its parent's and the gated row's after it,
  # so an `id`-ordered bulk lock would take the child, wait on the gate,
  # and then deadlock with the parent's close, which holds the parent and
  # waits on the child. In `number` order the bulk lock takes the parent
  # first, so the close waits instead.
  test "a policy-write recompute and a parent close lock in one order", ctx do
    parent = insert_cr!(ctx, "ffffffff-0000-4000-8000-000000000001", 1, nil)
    _child = insert_cr!(ctx, "00000000-0000-4000-8000-000000000001", 2, parent.id)
    other = insert_cr!(ctx, "77777777-0000-4000-8000-000000000001", 3, nil)

    gate = gate(fn -> row_lock(other.id) end)

    recompute =
      actor(fn -> rescued(fn -> ChangeRequests.recompute_project(ctx.project.id) end) end)

    await_blocked(recompute, gate)

    close =
      actor(fn -> rescued(fn -> ChangeRequests.transition(parent, ctx.api_key, :close) end) end)

    await_blocked(close, recompute)
    release(gate)

    assert Task.await(recompute.task, 15_000) == 3
    assert {:ok, %ChangeRequest{state: "closed"}} = Task.await(close.task, 15_000)
  end

  test "two acquires for different change requests on one branch: exactly one wins", ctx do
    for round <- 1..3 do
      a = mergeable(ctx, ctx.project, sha(round * 10 + 1), "race-#{round}")
      b = mergeable(ctx, ctx.project, sha(round * 10 + 2), "race-#{round}")

      results = race([acquire(ctx, a, sha(round * 10 + 1)), acquire(ctx, b, sha(round * 10 + 2))])

      assert [{:ok, :created, _lease}] = Enum.filter(results, &match?({:ok, _, _}, &1))

      assert [{:error, {:coded_conflict, "slot_taken", %{holder: _}}}] =
               Enum.filter(results, &match?({:error, _}, &1))

      assert active(ctx.project.id, "race-#{round}") == 1
    end
  end

  test "other branches and other projects do not interact", ctx do
    main = mergeable(ctx, ctx.project, sha(1), "main")
    release = mergeable(ctx, ctx.project, sha(2), "release/1.2")
    elsewhere = mergeable(ctx, ctx.other_project, sha(3), "main")

    results =
      race([
        acquire(ctx, main, sha(1)),
        acquire(ctx, release, sha(2)),
        acquire(ctx, elsewhere, sha(3))
      ])

    assert Enum.all?(results, &match?({:ok, :created, %Lease{}}, &1))
    assert active(ctx.project.id, "main") == 1
    assert active(ctx.project.id, "release/1.2") == 1
    assert active(ctx.other_project.id, "main") == 1
  end
end
