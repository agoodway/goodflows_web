defmodule GoodFlows.ChangeRequestsConcurrencyTest do
  # Not async and outside the SQL sandbox: each racer needs its own
  # connection, or the row locks would never contend. Rows are committed
  # and the account (cascading to its projects) is deleted in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures, only: [feature: 2]
  import GoodFlows.SpryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.{Account, User}
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.{ChangeRequest, GitFacts}
  alias GoodFlows.FeatureIndex
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Repo
  alias GoodFlows.Review
  alias GoodFlows.Review.Task, as: ReviewTask
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ReviewPolicies.Version
  alias GoodFlows.WorkflowRuns

  setup do
    ctx =
      unboxed(fn ->
        user = user_fixture()
        {:ok, account} = Accounts.create_account(user, %{name: "Race #{System.unique_integer()}"})
        account_user = Accounts.get_account_user(user, account)
        {api_key, _token} = api_key_fixture(account_user, %{type: :private})

        %{
          account: account,
          account_user: account_user,
          user: user,
          api_key: api_key,
          project: project_fixture(account)
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

  defp racer(parent, fun, i), do: unboxed(fn -> run_at_barrier(parent, fun, i) end)

  defp run_at_barrier(parent, fun, i) do
    send(parent, {:ready, self()})

    receive do
      :go -> fun.(i)
    end
  end

  defp race(count, fun) do
    parent = self()

    tasks =
      for i <- 1..count do
        Task.async(fn -> racer(parent, fun, i) end)
      end

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    Task.await_many(tasks, 15_000)
  end

  test "concurrent creates get distinct numbers", ctx do
    results =
      race(8, fn i ->
        ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, %{
          "title" => "t#{i}",
          "source_branch" => "b#{i}"
        })
      end)

    numbers = for {:ok, cr} <- results, do: cr.number
    assert Enum.sort(numbers) == Enum.to_list(1..8)
  end

  test "concurrent equal Git facts store one report", ctx do
    {:ok, cr} =
      unboxed(fn ->
        ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, %{
          "title" => "t",
          "source_branch" => "b"
        })
      end)

    results =
      race(4, fn _ -> ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(1))) end)

    assert results |> Enum.map(&elem(&1, 1)) |> Enum.sort() == [:created, :retry, :retry, :retry]

    assert unboxed(fn ->
             Repo.aggregate(from(f in GitFacts, where: f.change_request_id == ^cr.id), :count)
           end) == 1
  end

  # The workflow run's transaction stores a run on `H2` and recomputes
  # (finding no change request on `H2` yet), then stays open while a Git
  # facts report moves the head to `H2`. The report must wait for the run
  # to commit and then see it; without the shared lock it recomputes
  # without the uncommitted run and the verdict misses it.
  test "a Git facts report moving the head waits for a run on the new head", ctx do
    policy = %{
      "previous_version" => 0,
      "policy" => %{
        "format" => "review-policy/1",
        "evidence" => %{"required_workflows" => ["ci"]}
      }
    }

    {:ok, cr} =
      unboxed(fn ->
        {:ok, :created, _} =
          ReviewPolicies.write(ctx.project, ctx.account_user, ctx.api_key, policy)

        {:ok, cr} =
          ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, %{
            "title" => "t",
            "source_branch" => "b"
          })

        {:ok, :created, cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(1)))
        {:ok, cr}
      end)

    parent = self()

    run =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            {:ok, _} =
              WorkflowRuns.ingest(
                ctx.account,
                ctx.project,
                ctx.api_key,
                run_document(sha(2), "passed")
              )

            send(parent, :run_stored)
            receive(do: (:commit -> :ok))
          end)
        end)
      end)

    assert_receive :run_stored, 5_000

    facts =
      Task.async(fn ->
        unboxed(fn -> ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(2))) end)
      end)

    wait_until_blocked_or_done(facts, 100)
    send(run.pid, :commit)
    assert {:ok, _} = Task.await(run, 15_000)
    assert {:ok, :created, _} = Task.await(facts, 15_000)

    rules =
      unboxed(fn ->
        cr = Repo.get!(ChangeRequest, cr.id)
        Enum.map(ChangeRequests.verdict(cr).reasons, & &1["rule"])
      end)

    refute "required_workflow_missing" in rules
  end

  # Returns once `task` waits on an advisory lock or has finished.
  defp wait_until_blocked_or_done(_task, 0),
    do: flunk("the Git facts report neither ran nor waited")

  defp wait_until_blocked_or_done(task, tries) do
    waiting =
      unboxed(fn ->
        Repo.one(
          from l in "pg_locks",
            where: l.locktype == "advisory" and not l.granted,
            select: count()
        )
      end)

    cond do
      waiting > 0 ->
        :ok

      Process.info(task.pid) == nil ->
        :ok

      true ->
        Process.sleep(50)
        wait_until_blocked_or_done(task, tries - 1)
    end
  end

  # The write locks the project row, then waits on the change request row
  # the other transaction holds; that one then records an event, whose
  # foreign key check takes FOR KEY SHARE on the project row. With a
  # FOR UPDATE project lock the two deadlock and one aborts.
  for kind <- [:policy, :feature_index] do
    @kind kind
    test "a #{kind} write and an event on a locked change request both commit", ctx do
      {:ok, cr} =
        unboxed(fn ->
          ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, %{
            "title" => "t",
            "source_branch" => "b"
          })
        end)

      parent = self()

      holder =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              cr = ChangeRequests.lock_active(cr)
              send(parent, :cr_locked)
              receive(do: (:record -> :ok))

              ProjectEvents.record(
                cr.project_id,
                cr.number,
                "cr_state_changed",
                %{"from" => "draft", "to" => "open"},
                Review.cli_actor(ctx.api_key)
              )
            end)
          end)
        end)

      assert_receive :cr_locked, 5_000
      writer = Task.async(fn -> unboxed(fn -> write(@kind, ctx) end) end)
      wait_until_row_lock_waits(writer, 100)
      send(holder.pid, :record)

      assert {:ok, _event} = Task.await(holder, 15_000)
      assert {:ok, :created, _version} = Task.await(writer, 15_000)
    end
  end

  defp write(:policy, ctx) do
    ReviewPolicies.write(ctx.project, ctx.account_user, ctx.api_key, %{
      "previous_version" => 0,
      "policy" => %{"format" => "review-policy/1", "size" => %{"max_changed_files" => 5}}
    })
  end

  defp write(:feature_index, ctx),
    do: FeatureIndex.sync(ctx.project, ctx.api_key, %{"features" => [feature("x", ["lib/**"])]})

  defp wait_until_row_lock_waits(_task, 0), do: flunk("the write neither ran nor waited")

  defp wait_until_row_lock_waits(task, tries) do
    waiting =
      unboxed(fn ->
        Repo.one(
          from l in "pg_locks",
            where: l.locktype in ["transactionid", "tuple"] and not l.granted,
            select: count()
        )
      end)

    cond do
      waiting > 0 ->
        :ok

      Process.info(task.pid) == nil ->
        :ok

      true ->
        Process.sleep(50)
        wait_until_row_lock_waits(task, tries - 1)
    end
  end

  test "a task completion queues behind the change request lock of an answer replacing its item's answer",
       ctx do
    {cr, task} =
      unboxed(fn ->
        {:ok, cr} =
          ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, %{
            "title" => "t",
            "source_branch" => "b"
          })

        {:ok, :created, cr} = ChangeRequests.report_git_facts(cr, ctx.api_key, git_facts(sha(1)))
        raw = claims(front_matter(sha(1), %{"cr" => cr.number, "door" => "one_way"}))
        {:ok, _status, cr} = ChangeRequests.upload_claims(cr, ctx.api_key, raw)
        [item] = Review.packet(cr).items
        actor = Review.cli_actor(ctx.account_user, ctx.api_key)
        body = %{"head" => sha(1), "answer" => "request_change", "note" => "split it"}
        {:ok, _answer} = Review.answer(cr, actor, item.id, body)
        {:ok, [task]} = Review.list_tasks(cr, %{"state" => "open"})
        {cr, task}
      end)

    parent = self()
    answer = Task.async(fn -> answer_replacing_item_answer(parent, ctx, cr, task) end)
    assert_receive :event_recorded, 5_000

    completer =
      Task.async(fn ->
        unboxed(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend_pid, backend_pid})

          Review.complete_task(cr, ctx.account_user, ctx.api_key, task.id)
        end)
      end)

    assert_receive {:backend_pid, backend_pid}, 5_000
    wait_until_backend_waits(completer, backend_pid, 100)
    send(answer.pid, :mark_task_stale)

    assert {:ok, {1, nil}} = Task.await(answer, 15_000)
    assert {:ok, %ReviewTask{state: "done"}} = Task.await(completer, 15_000)
  end

  defp answer_replacing_item_answer(parent, ctx, cr, task) do
    unboxed(fn ->
      Repo.transaction(fn ->
        cr = ChangeRequests.lock_active(cr)

        ProjectEvents.record(
          cr.project_id,
          cr.number,
          "answer_recorded",
          %{},
          Review.cli_actor(ctx.api_key)
        )

        send(parent, :event_recorded)
        receive(do: (:mark_task_stale -> :ok))
        Repo.update_all(from(t in ReviewTask, where: t.id == ^task.id), set: [state: "stale"])
      end)
    end)
  end

  defp wait_until_backend_waits(_task, _backend_pid, 0),
    do: flunk("the completion neither ran nor waited")

  defp wait_until_backend_waits(task, backend_pid, tries) do
    waiting =
      unboxed(fn ->
        Repo.one(
          from l in "pg_locks",
            where: l.pid == ^backend_pid and not l.granted,
            select: count()
        )
      end)

    cond do
      waiting > 0 ->
        :ok

      Process.info(task.pid) == nil ->
        :ok

      true ->
        Process.sleep(50)
        wait_until_backend_waits(task, backend_pid, tries - 1)
    end
  end

  test "two writes on the same version give one new version and one conflict", ctx do
    body = fn i ->
      %{
        "previous_version" => 0,
        "policy" => %{"format" => "review-policy/1", "size" => %{"max_changed_files" => i}}
      }
    end

    results =
      race(2, fn i ->
        ReviewPolicies.write(ctx.project, ctx.account_user, ctx.api_key, body.(i))
      end)

    assert Enum.sort_by(results, &elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sort() ==
             [:created, :policy_version_conflict]

    assert unboxed(fn ->
             Repo.aggregate(from(v in Version, where: v.project_id == ^ctx.project.id), :count)
           end) == 1
  end
end
