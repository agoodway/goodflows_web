defmodule GoodFlows.Spry.ReaperTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Spry.{Config, Executions, Reaper, ReapRunsJob, Run, RunJob, Runner, RunStep}
  alias GoodFlows.Spry.Sprites, as: Wrapper
  alias Mix.Tasks.Spry.ForceAbandon

  import ExUnit.CaptureLog

  @moduletag :capture_log

  setup :set_mimic_global

  setup do
    account = account_fixture()
    credential_fixture(account)
    project = project_fixture(account)
    recipe = recipe_fixture(project, %{"name" => "box", "start" => ["a", "b", "c"]})
    %{account: account, project: project, recipe: recipe}
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 1, :day)
  defp long_ago, do: DateTime.add(DateTime.utc_now(), -1, :day)

  # Just past the bounded fallback for a run claimed now.
  defp past_owner_deadline,
    do: DateTime.add(DateTime.utc_now(), Config.owner_deadline_ms() + 60_000, :millisecond)

  # An owner id on a node name this VM has never seen (no atom is created).
  defp unknown_node_owner,
    do: "never-seen-#{System.unique_integer([:positive])}@nowhere|b00t|#{Ecto.UUID.generate()}"

  defp running_run(ctx, owner_id, attrs \\ []) do
    run =
      run_fixture(
        ctx.account,
        ctx.recipe,
        Keyword.merge(
          [
            phase: "start",
            status: "running",
            owner_id: owner_id,
            started_at: DateTime.utc_now(),
            action_started_at: DateTime.utc_now()
          ],
          attrs
        )
      )

    run_step_fixture(run, index: 0, kind: "exec", command: "a", status: "succeeded")
    run_step_fixture(run, index: 1, kind: "exec", command: "b", status: "running")
    run_step_fixture(run, index: 2, kind: "exec", command: "c", status: "pending")
    run
  end

  defp reload(run), do: Run |> Repo.get!(run.id) |> Repo.preload(:steps)

  # A stand-in worker: registers `owner_id` and tracks a child "action" pid.
  defp start_fake_worker(owner_id) do
    test_pid = self()

    worker =
      spawn(fn ->
        :ok = Executions.register(owner_id)
        child = spawn(fn -> Process.sleep(:infinity) end)
        Executions.track(child)
        send(test_pid, {:worker_ready, child})
        Process.sleep(:infinity)
      end)

    assert_receive {:worker_ready, child}
    {worker, child}
  end

  defp perform(run) do
    ctx = %PgFlow.Context{
      run_id: Ecto.UUID.generate(),
      step_slug: :execute,
      task_index: 0,
      attempt: 1,
      repo: Repo
    }

    RunJob.perform(%{"run_id" => run.id}, ctx)
  end

  describe "queued runs" do
    test "old queued runs whose job is missing fail; recent ones stay", ctx do
      old = run_fixture(ctx.account, ctx.recipe, sprite_name: "old", inserted_at: long_ago())
      fresh = run_fixture(ctx.account, ctx.recipe, sprite_name: "fresh")

      assert %{queued_failed: 1} = Reaper.reap()
      assert %{status: "failed", error: "abandoned: " <> _} = reload(old)
      assert reload(fresh).status == "queued"
    end

    test "a late delivery of a reaped queued run does nothing", ctx do
      reject(&Wrapper.exists?/3)
      reject(&Wrapper.exec/4)
      old = run_fixture(ctx.account, ctx.recipe, phase: "start", inserted_at: long_ago())

      Reaper.reap()
      assert %{"result" => "skipped"} = perform(old)
      assert reload(old).status == "failed"
    end

    test "a queued run whose PgFlow job is still pending (waiting for capacity) stays queued",
         ctx do
      compile_jobs!()

      {:ok, run} =
        start_run(ctx.account, ctx.project, ctx.recipe.id, %{
          "phase" => "start",
          "sprite" => "waits"
        })

      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [inserted_at: long_ago()])

      assert %{queued_failed: 0} = Reaper.reap()
      assert %{status: "queued", reaper_checked_at: %DateTime{}} = reload(run)

      # Once PgFlow has finished the job without the run being claimed, the
      # run can never start and is failed.
      Repo.query!(
        "UPDATE pgflow.runs SET status = 'failed', failed_at = now() WHERE run_id = $1",
        [
          Ecto.UUID.dump!(run.pgflow_run_id)
        ]
      )

      assert %{queued_failed: 1} = Reaper.reap()
      assert %{status: "failed", error: "abandoned: " <> _} = reload(run)
    end

    test "a queued run whose PgFlow job no longer exists fails", ctx do
      run =
        run_fixture(ctx.account, ctx.recipe,
          sprite_name: "nojob",
          pgflow_run_id: Ecto.UUID.generate(),
          inserted_at: long_ago()
        )

      assert %{queued_failed: 1} = Reaper.reap()
      assert reload(run).status == "failed"
    end

    test "the queued age is configurable and defaults past the run budget", ctx do
      original = Application.get_env(:good_flows, GoodFlows.Spry)
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Spry, original) end)

      # Older than the default (run budget + 5 minutes) but younger than the
      # configured hour.
      ten_minutes_ago = DateTime.add(DateTime.utc_now(), -10, :minute)

      run =
        run_fixture(ctx.account, ctx.recipe, sprite_name: "young", inserted_at: ten_minutes_ago)

      Application.put_env(
        :good_flows,
        GoodFlows.Spry,
        Keyword.put(original, :queued_reap_after_ms, 60 * 60_000)
      )

      assert %{queued_failed: 0} = Reaper.reap()
      assert reload(run).status == "queued"

      Application.put_env(:good_flows, GoodFlows.Spry, original)
      assert %{queued_failed: 1} = Reaper.reap()
    end

    test "a claimed run is not touched by queued reaping", ctx do
      stub(Wrapper, :exists?, fn _, _, _ -> {:ok, true} end)

      stub(Wrapper, :exec, fn _, _, _, _ ->
        {:ok, %{exit_code: 0, output: "", output_truncated: false}}
      end)

      run = run_fixture(ctx.account, ctx.recipe, phase: "start", inserted_at: long_ago())

      assert %{"result" => "succeeded"} = perform(run)
      assert %{queued_failed: 0} = Reaper.reap()
      assert reload(run).status == "succeeded"
    end
  end

  describe "running runs" do
    test "fresh runs are not candidates even if the owner is gone", ctx do
      run = running_run(ctx, Executions.new_owner_id())
      assert %{running_failed: 0, retained: 0} = Reaper.reap()
      assert reload(run).status == "running"
    end

    test "a stale run whose owner is gone is finalized and releases its guard", ctx do
      run = running_run(ctx, Executions.new_owner_id(), action_started_at: long_ago())

      assert %{running_failed: 1} = Reaper.reap(now: later())

      run = reload(run)
      assert run.status == "failed"
      assert run.error =~ "abandoned"

      assert Enum.map(run.steps, &{&1.status, &1.reason}) ==
               [{"succeeded", nil}, {"failed", "abandoned"}, {"skipped", nil}]

      assert run_fixture(ctx.account, ctx.recipe, sprite_name: run.sprite_name, status: "running")
    end

    test "a live stale owner is stopped, with its action processes, before release", ctx do
      owner_id = Executions.new_owner_id()
      {worker, child} = start_fake_worker(owner_id)
      run = running_run(ctx, owner_id, action_started_at: long_ago())

      assert %{running_failed: 1} = Reaper.reap(now: later())

      refute Process.alive?(worker)
      refute Process.alive?(child)
      assert reload(run).status == "failed"
    end

    test "an unknown owner node keeps the guard", ctx do
      run = running_run(ctx, unknown_node_owner(), action_started_at: long_ago())

      {summary, log} = with_log(fn -> Reaper.reap() end)
      assert %{running_failed: 0, retained: 1} = summary
      assert log =~ ":unknown_owner_node"
      assert %{status: "running", reaper_checked_at: %DateTime{}} = reload(run)
    end

    test "an unparseable owner keeps the guard", ctx do
      run = running_run(ctx, "garbage", action_started_at: long_ago())
      assert %{retained: 1} = Reaper.reap()
      assert reload(run).status == "running"
    end

    test "an unreachable owner node keeps the guard until the owner deadline", ctx do
      # A known node name (its atom exists), so the reaper tries to reach it.
      _ = :ghost@nowhere

      run =
        running_run(ctx, "ghost@nowhere|b00t|#{Ecto.UUID.generate()}",
          action_started_at: long_ago()
        )

      {summary, log} = with_log(fn -> Reaper.reap() end)
      assert %{running_failed: 0, retained: 1} = summary
      assert log =~ ":unreachable"
      assert reload(run).status == "running"

      # Past started_at + the PgFlow hard timeout + overhead, the owner's own
      # node has killed it, so the unreachable owner counts as terminated.
      {summary, log} = with_log(fn -> Reaper.reap(now: past_owner_deadline()) end)
      assert %{running_failed: 1, retained: 0} = summary
      assert log =~ "past its owner deadline"

      run = reload(run)
      assert run.status == "failed"
      assert run.error =~ "abandoned"
      assert Enum.map(run.steps, & &1.status) == ["succeeded", "failed", "skipped"]
    end

    test "unknown and unparseable owners are released after the owner deadline", ctx do
      unknown =
        running_run(ctx, unknown_node_owner(), sprite_name: "u1", action_started_at: long_ago())

      garbage = running_run(ctx, "garbage", sprite_name: "u2", action_started_at: long_ago())

      assert %{running_failed: 2} = Reaper.reap(now: past_owner_deadline())
      assert reload(unknown).status == "failed"
      assert reload(garbage).status == "failed"
    end

    test "another boot under this node name is not treated as local", ctx do
      owner_id = "#{node()}|another-boot|#{Ecto.UUID.generate()}"
      reject(&Executions.stop/1)
      reject(&Executions.stop/2)
      run = running_run(ctx, owner_id, action_started_at: long_ago())

      {summary, log} = with_log(fn -> Reaper.reap() end)
      assert %{retained: 1} = summary
      assert log =~ ":foreign_boot"
      assert reload(run).status == "running"

      assert %{running_failed: 1} = Reaper.reap(now: past_owner_deadline())
    end

    test "a reachable owner whose kill is not confirmed keeps the guard, even past the deadline",
         ctx do
      owner_id = Executions.new_owner_id()
      stub(Executions, :stop, fn ^owner_id -> {:error, :not_confirmed} end)
      run = running_run(ctx, owner_id, action_started_at: long_ago())

      {summary, log} = with_log(fn -> Reaper.reap(now: past_owner_deadline()) end)
      assert %{running_failed: 0, retained: 1} = summary
      assert log =~ ":not_confirmed"
      assert reload(run).status == "running"
    end

    test "a run that completes while the reaper investigates keeps its result", ctx do
      owner_id = Executions.new_owner_id()
      run = running_run(ctx, owner_id, action_started_at: long_ago())

      stub(Executions, :stop, fn ^owner_id ->
        # The worker finishes first; by the time the owner is asked, it is gone.
        :ok = Runner.finalize(run.id, owner_id, "succeeded", nil, nil)
        :not_running
      end)

      assert %{running_failed: 0, retained: 1} = Reaper.reap(now: later())
      assert %{status: "succeeded", error: nil} = reload(run)
    end

    test "an investigation that does not finish in time keeps the guard", ctx do
      stub(Executions, :stop, fn _owner_id -> Process.sleep(:infinity) end)
      run = running_run(ctx, Executions.new_owner_id(), action_started_at: long_ago())

      {summary, log} =
        with_log(fn -> Reaper.reap(now: later(), investigation_timeout_ms: 50) end)

      assert %{running_failed: 0, retained: 1} = summary
      assert log =~ "did not finish"
      assert reload(run).status == "running"
    end

    test "an exhausted total budget makes a run a candidate", ctx do
      run = running_run(ctx, Executions.new_owner_id(), started_at: long_ago())

      assert %{running_failed: 1} =
               Reaper.reap(now: DateTime.add(DateTime.utc_now(), 10, :minute))

      assert reload(run).status == "failed"
    end
  end

  describe "sweep bounds" do
    test "investigates candidates concurrently", ctx do
      runs =
        for i <- 1..3 do
          running_run(ctx, Executions.new_owner_id(),
            sprite_name: "box-#{i}",
            action_started_at: long_ago()
          )
        end

      test_pid = self()

      # Each investigation blocks until released, so all three can only be
      # in flight together if they run concurrently.
      stub(Executions, :stop, fn _owner_id ->
        send(test_pid, {:investigating, self()})

        receive do
          :release -> :not_running
        end
      end)

      sweep = Task.async(fn -> Reaper.reap(now: later()) end)

      pids =
        for _ <- 1..3 do
          assert_receive {:investigating, pid}, 5_000
          pid
        end

      assert length(Enum.uniq(pids)) == 3
      Enum.each(pids, &send(&1, :release))

      assert %{running_failed: 3} = Task.await(sweep)
      assert Enum.all?(runs, &(reload(&1).status == "failed"))
    end

    test "retained runs rotate behind never-checked candidates", ctx do
      # 50 old candidates whose owners can never be investigated...
      for i <- 1..50 do
        run_fixture(ctx.account, ctx.recipe,
          phase: "start",
          sprite_name: "stuck-#{i}",
          status: "running",
          owner_id: "garbage-#{i}",
          started_at: DateTime.utc_now(),
          action_started_at: DateTime.add(long_ago(), -i, :second)
        )
      end

      # ...and one newer candidate whose owner is simply gone.
      fresh =
        running_run(ctx, Executions.new_owner_id(),
          sprite_name: "fresh",
          action_started_at: long_ago()
        )

      assert %{running_failed: 0, retained: 50} = Reaper.reap()
      assert reload(fresh).status == "running"

      assert %{running_failed: 1} = Reaper.reap()
      assert reload(fresh).status == "failed"
    end

    test "a sweep takes at most 50 candidates, oldest action first", ctx do
      for i <- 1..51 do
        run_fixture(ctx.account, ctx.recipe,
          phase: "start",
          sprite_name: "cap-#{i}",
          status: "running",
          owner_id: Executions.new_owner_id(),
          started_at: DateTime.utc_now(),
          action_started_at: DateTime.add(long_ago(), -i, :second)
        )
      end

      assert %{running_failed: 50} = Reaper.reap(now: later())
      assert [%Run{sprite_name: "cap-1"}] = Repo.all(from r in Run, where: r.status == "running")
    end
  end

  describe "force_abandon/1" do
    test "clears a run whose owner node is unknown after a redeploy", ctx do
      run =
        running_run(ctx, "good_flows@old-host-gone|b00t|#{Ecto.UUID.generate()}",
          action_started_at: long_ago()
        )

      assert %{retained: 1} = Reaper.reap()

      assert {:ok, %Run{status: "failed", error: error}} = GoodFlows.Spry.force_abandon(run.id)
      assert error =~ "operator"

      run = reload(run)
      assert run.status == "failed"
      assert Enum.map(run.steps, & &1.status) == ["succeeded", "failed", "skipped"]
    end

    test "still stops a live local owner first", ctx do
      owner_id = Executions.new_owner_id()
      {worker, child} = start_fake_worker(owner_id)
      run = running_run(ctx, owner_id)

      assert {:ok, %Run{status: "failed"}} = Reaper.force_abandon(run.id)
      refute Process.alive?(worker)
      refute Process.alive?(child)
    end

    test "finalizes despite an unconfirmed reachable owner, with a warning", ctx do
      owner_id = Executions.new_owner_id()
      stub(Executions, :stop, fn ^owner_id -> {:error, :not_confirmed} end)
      run = running_run(ctx, owner_id)

      {result, log} = with_log(fn -> Reaper.force_abandon(run.id) end)
      assert {:ok, %Run{status: "failed"}} = result

      assert log =~
               "finalizing despite a reachable owner whose termination could not be confirmed"
    end

    test "an unreachable owner is not reported as an unconfirmed reachable one", ctx do
      run = running_run(ctx, unknown_node_owner())

      {result, log} = with_log(fn -> Reaper.force_abandon(run.id) end)
      assert {:ok, %Run{status: "failed"}} = result
      assert log =~ "force-abandoned"
      refute log =~ "finalizing despite"
    end

    test "leaves finished runs alone and reports unknown ids", ctx do
      owner_id = Executions.new_owner_id()
      run = running_run(ctx, owner_id)
      :ok = Runner.finalize(run.id, owner_id, "succeeded", nil, nil)

      assert Reaper.force_abandon(run.id) == {:error, :not_running}
      assert reload(run).status == "succeeded"
      assert Reaper.force_abandon(Ecto.UUID.generate()) == {:error, :not_found}
      assert Reaper.force_abandon("nope") == {:error, :not_found}
    end

    test "the mix task starts only the services it needs, idempotently" do
      assert ForceAbandon.start_services() == :ok
      assert ForceAbandon.start_services() == :ok
    end

    test "mix spry.force_abandon releases the run", ctx do
      run = running_run(ctx, "good_flows@old-host-gone|b00t|#{Ecto.UUID.generate()}")
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      ForceAbandon.run([run.id, Ecto.UUID.generate()])

      assert_received {:mix_shell, :info, [message]}
      assert message =~ "#{run.id}: failed"
      assert_received {:mix_shell, :error, [message]}
      assert message =~ "no such run"
      assert reload(run).status == "failed"
    end
  end

  test "finalization never overwrites a completed run", ctx do
    owner_id = Executions.new_owner_id()
    run = running_run(ctx, owner_id)
    assert Runner.finalize(run.id, owner_id, "succeeded", nil, nil) == :ok

    assert Runner.finalize(run.id, owner_id, "failed", "abandoned: late", "abandoned") == :noop
    assert reload(run).status == "succeeded"
  end

  test "a stale worker cannot issue another action after abandonment", ctx do
    test_pid = self()
    stub(Wrapper, :exists?, fn _, _, _ -> {:ok, true} end)

    stub(Wrapper, :exec, fn _client, _name, line, _opts ->
      send(test_pid, {:exec, line})

      # The reaper finalizes the run while this action is in flight.
      run = Repo.get_by!(Run, status: "running")
      :ok = Runner.finalize(run.id, run.owner_id, "failed", "abandoned: test", "abandoned")
      {:ok, %{exit_code: 0, output: "", output_truncated: false}}
    end)

    run = run_fixture(ctx.account, ctx.recipe, phase: "start", sprite_name: "box")
    assert %{"result" => "lost"} = perform(run)

    assert_received {:exec, "a"}
    refute_received {:exec, "b"}

    run = reload(run)
    assert run.status == "failed"
    assert run.error == "abandoned: test"
    assert Enum.map(run.steps, & &1.status) == ["failed", "skipped", "skipped"]
  end

  describe "output retention" do
    test "clears the output of steps finished before the retention period", ctx do
      run = run_fixture(ctx.account, ctx.recipe, status: "succeeded")

      old_finish =
        DateTime.add(DateTime.utc_now(), -Config.output_retention_ms() - 60_000, :millisecond)

      old =
        run_step_fixture(run,
          index: 0,
          kind: "exec",
          command: "a",
          status: "succeeded",
          output: "old",
          finished_at: old_finish
        )

      recent =
        run_step_fixture(run,
          index: 1,
          kind: "exec",
          command: "b",
          status: "succeeded",
          output: "new",
          finished_at: DateTime.utc_now()
        )

      assert %{outputs_purged: 1} = Reaper.reap()
      assert Repo.get!(RunStep, old.id).output == nil
      assert Repo.get!(RunStep, recent.id).output == "new"
      assert %{outputs_purged: 0} = Reaper.reap()
    end
  end

  test "ReapRunsJob runs a sweep" do
    ctx = %PgFlow.Context{
      run_id: Ecto.UUID.generate(),
      step_slug: :reap,
      task_index: 0,
      attempt: 1,
      repo: Repo
    }

    assert %{"queued_failed" => 0, "running_failed" => 0, "retained" => 0, "outputs_purged" => 0} =
             ReapRunsJob.perform(%{}, ctx)
  end
end
