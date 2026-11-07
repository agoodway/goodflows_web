defmodule GoodFlows.Spry.RunJobTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Spry
  alias GoodFlows.Spry.{Config, Plan, Reaper, Run, RunJob}
  alias GoodFlows.Spry.Sprites, as: Wrapper

  @token "original-token-1111"

  setup :set_mimic_global

  setup do
    account = account_fixture()
    credential_fixture(account, @token)
    project = project_fixture(account)

    recipe =
      recipe_fixture(project, %{
        "name" => "app-{{branch_slug}}",
        "setup" => ["echo s1 {{sprite}}", "echo s2"],
        "start" => ["echo start"],
        "stop" => [],
        "teardown" => ["echo t1"]
      })

    %{account: account, project: project, recipe: recipe, test_pid: self()}
  end

  defp queued_run(account, recipe, params) do
    {:ok, plan} = Plan.build(recipe, Map.put_new(params, "branch", "feat/x"))

    run_fixture(account, recipe,
      phase: plan.phase,
      sprite_name: plan.sprite_name,
      commands: plan.commands,
      inputs: plan.inputs,
      no_create: plan.no_create,
      no_destroy: plan.no_destroy
    )
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

  defp reload(run), do: Run |> Repo.get!(run.id) |> Repo.preload(:steps)

  defp summary(run) do
    run = reload(run)
    {run.status, Enum.map(run.steps, &{&1.kind, &1.status})}
  end

  # Records every wrapper call in the test mailbox.
  defp stub_vm(test_pid, opts) do
    exists? = Keyword.get(opts, :exists?, true)

    exec =
      Keyword.get(opts, :exec, fn _line, _opts ->
        {:ok, %{exit_code: 0, output: "ok\n", output_truncated: false}}
      end)

    stub(Wrapper, :exists?, fn client, name, _opts ->
      send(test_pid, {:vm, :exists?, name, client.token})
      {:ok, exists?}
    end)

    stub(Wrapper, :create, fn client, name, _opts ->
      send(test_pid, {:vm, :create, name, client.token})
      :ok
    end)

    stub(Wrapper, :destroy, fn client, name, _opts ->
      send(test_pid, {:vm, :destroy, name, client.token})
      :ok
    end)

    stub(Wrapper, :exec, fn client, _name, line, opts ->
      send(test_pid, {:vm, :exec, line, client.token})
      exec.(line, opts)
    end)
  end

  defp vm_calls(acc \\ []) do
    receive do
      {:vm, kind, arg, _token} -> vm_calls([{kind, arg} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "setup" do
    test "creates a missing VM, then runs the lines", ctx do
      stub_vm(ctx.test_pid, exists?: false)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})

      assert %{"result" => "succeeded"} = perform(run)

      assert vm_calls() == [
               {:exists?, "app-feat-x"},
               {:create, "app-feat-x"},
               {:exec, "echo s1 app-feat-x"},
               {:exec, "echo s2"}
             ]

      assert summary(run) ==
               {"succeeded",
                [{"create", "succeeded"}, {"exec", "succeeded"}, {"exec", "succeeded"}]}

      run = reload(run)
      assert [%{exit_code: nil}, %{exit_code: 0, output: "ok\n"} | _] = run.steps
      assert run.started_at && run.finished_at
    end

    test "an existing VM is not recreated", ctx do
      stub_vm(ctx.test_pid, exists?: true)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})

      perform(run)
      refute Enum.any?(vm_calls(), &match?({:create, _}, &1))
      assert {"succeeded", [{"exec", _}, {"exec", _}]} = summary(run)
    end

    test "no_create with a missing VM fails without creating", ctx do
      stub_vm(ctx.test_pid, exists?: false)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup", "no_create" => true})

      perform(run)
      assert vm_calls() == [{:exists?, "app-feat-x"}]
      run = reload(run)
      assert run.status == "failed"
      assert run.error =~ "does not exist"
      assert run.steps == []
    end
  end

  describe "start and stop" do
    test "a missing VM fails with no steps", ctx do
      stub_vm(ctx.test_pid, exists?: false)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})

      perform(run)
      assert vm_calls() == [{:exists?, "app-feat-x"}]
      assert summary(run) == {"failed", []}
    end

    test "start runs only start lines", ctx do
      stub_vm(ctx.test_pid, exists?: true)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})

      perform(run)
      assert vm_calls() == [{:exists?, "app-feat-x"}, {:exec, "echo start"}]
      assert summary(run) == {"succeeded", [{"exec", "succeeded"}]}
    end

    test "an empty stop on an existing VM succeeds with no steps", ctx do
      stub_vm(ctx.test_pid, exists?: true)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "stop"})

      perform(run)
      assert summary(run) == {"succeeded", []}
    end
  end

  describe "teardown" do
    test "runs the lines then destroys", ctx do
      stub_vm(ctx.test_pid, exists?: true)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "teardown"})

      perform(run)

      assert vm_calls() == [
               {:exists?, "app-feat-x"},
               {:exec, "echo t1"},
               {:destroy, "app-feat-x"}
             ]

      assert summary(run) == {"succeeded", [{"exec", "succeeded"}, {"destroy", "succeeded"}]}
    end

    test "no_destroy keeps the VM", ctx do
      stub_vm(ctx.test_pid, exists?: true)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "teardown", "no_destroy" => true})

      perform(run)
      refute Enum.any?(vm_calls(), &match?({:destroy, _}, &1))
      assert summary(run) == {"succeeded", [{"exec", "succeeded"}]}
    end

    test "a failed step skips destroy", ctx do
      stub_vm(ctx.test_pid,
        exists?: true,
        exec: fn _line, _opts ->
          {:ok, %{exit_code: 2, output: "nope", output_truncated: false}}
        end
      )

      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "teardown"})

      perform(run)
      refute Enum.any?(vm_calls(), &match?({:destroy, _}, &1))
      assert summary(run) == {"failed", [{"exec", "failed"}, {"destroy", "skipped"}]}
    end

    test "a missing VM fails with no steps", ctx do
      stub_vm(ctx.test_pid, exists?: false)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "teardown"})

      perform(run)
      assert vm_calls() == [{:exists?, "app-feat-x"}]
      assert summary(run) == {"failed", []}
    end
  end

  describe "sprite lookup errors" do
    test "an API error (e.g. 401) fails the run with no steps", ctx do
      stub(Wrapper, :exists?, fn _client, _name, _opts -> {:error, %{status: 401}} end)
      reject(&Wrapper.create/3)
      reject(&Wrapper.exec/4)
      reject(&Wrapper.destroy/3)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})

      assert %{"result" => "failed"} = perform(run)
      run = reload(run)

      assert run.error ==
               "could not check whether sprite app-feat-x exists: Sprites API returned 401"

      assert run.steps == []
    end

    test "an API error with a message reports it", ctx do
      stub(Wrapper, :exists?, fn _client, _name, _opts ->
        {:error, %{status: 401, message: "invalid token"}}
      end)

      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})
      assert %{"result" => "failed"} = perform(run)

      assert reload(run).error ==
               "could not check whether sprite app-feat-x exists: invalid token"
    end

    test "a lookup timeout fails the run with no steps", ctx do
      stub(Wrapper, :exists?, fn _client, _name, _opts -> {:error, :timeout} end)
      reject(&Wrapper.create/3)
      reject(&Wrapper.exec/4)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})

      assert %{"result" => "failed"} = perform(run)
      run = reload(run)
      assert run.error == "timed out checking whether sprite app-feat-x exists"
      assert run.steps == []
    end
  end

  test "an SDK error from create fails the create step and skips the rest", ctx do
    stub_vm(ctx.test_pid, exists?: false)

    stub(Wrapper, :create, fn _client, name, _opts ->
      send(ctx.test_pid, {:vm, :create, name, nil})
      {:error, %{status: 500, message: "quota exceeded"}}
    end)

    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})

    assert %{"result" => "failed"} = perform(run)
    assert vm_calls() == [{:exists?, "app-feat-x"}, {:create, "app-feat-x"}]

    assert summary(run) ==
             {"failed", [{"create", "failed"}, {"exec", "skipped"}, {"exec", "skipped"}]}

    run = reload(run)
    assert run.error == "step 0 (create) failed: quota exceeded"
    assert [%{reason: "quota exceeded"} | _] = run.steps
  end

  test "a middle step failure fails fast", ctx do
    {:ok, recipe} =
      Spry.replace_recipe(ctx.account, ctx.project, ctx.recipe.id, %{
        "name" => "three",
        "start" => ["a", "b", "c"]
      })

    stub_vm(ctx.test_pid,
      exec: fn
        "b", _opts -> {:ok, %{exit_code: 1, output: "boom", output_truncated: false}}
        _line, _opts -> {:ok, %{exit_code: 0, output: "", output_truncated: false}}
      end
    )

    run = queued_run(ctx.account, recipe, %{"phase" => "start"})
    perform(run)

    assert vm_calls() == [{:exists?, "three"}, {:exec, "a"}, {:exec, "b"}]
    run = reload(run)
    assert run.status == "failed"

    assert [%{status: "succeeded"}, %{status: "failed", exit_code: 1}, %{status: "skipped"}] =
             run.steps

    assert run.error =~ "exited with code 1"
  end

  test "a step that hits its wall-clock deadline fails with reason timeout", ctx do
    stub_vm(ctx.test_pid,
      exec: fn
        "echo s1 app-feat-x", _opts -> {:error, :timeout}
        _line, _opts -> flunk("no later step may run")
      end
    )

    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})
    perform(run)

    run = reload(run)
    assert run.status == "failed"
    assert [%{status: "failed", reason: "timeout"}, %{status: "skipped"}] = run.steps
  end

  test "actions receive at most the step timeout", ctx do
    stub_vm(ctx.test_pid,
      exec: fn _line, opts ->
        assert opts[:timeout] <= Config.step_timeout_ms()
        {:ok, %{exit_code: 0, output: "", output_truncated: false}}
      end
    )

    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})
    assert %{"result" => "succeeded"} = perform(run)
  end

  test "exhausting the total run budget fails with run_timeout", ctx do
    lines = for i <- 1..12, do: "step #{i}"

    {:ok, recipe} =
      Spry.replace_recipe(ctx.account, ctx.project, ctx.recipe.id, %{
        "name" => "slow",
        "start" => lines
      })

    # Each step takes 250ms (under the 300ms step timeout); a budget-limited
    # timeout below that behaves like the wrapper's deadline.
    stub_vm(ctx.test_pid,
      exec: fn _line, opts ->
        timeout = opts[:timeout]

        if timeout < 250 do
          Process.sleep(timeout)
          {:error, :timeout}
        else
          Process.sleep(250)
          {:ok, %{exit_code: 0, output: "", output_truncated: false}}
        end
      end
    )

    run = queued_run(ctx.account, recipe, %{"phase" => "start"})
    perform(run)

    run = reload(run)
    assert run.status == "failed"
    assert run.error == "run_timeout"
    statuses = Enum.map(run.steps, & &1.status)
    assert "skipped" in statuses
    refute "running" in statuses
    refute "pending" in statuses
    exec_calls = Enum.count(vm_calls(), &match?({:exec, _}, &1))
    assert exec_calls < 12

    assert Enum.count(statuses, &(&1 == "succeeded")) + Enum.count(statuses, &(&1 == "failed")) ==
             exec_calls
  end

  test "an externally killed worker is finalized by the reaper after its owner is gone", ctx do
    test_pid = ctx.test_pid

    stub_vm(test_pid,
      exec: fn _line, _opts ->
        send(test_pid, {:blocked, self()})
        Process.sleep(:infinity)
      end
    )

    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})
    worker = spawn(fn -> perform(run) end)
    assert_receive {:blocked, ^worker}, 2_000

    # Live owner: the guard stays until the reaper stops it.
    assert reload(run).status == "running"

    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}

    later = DateTime.add(DateTime.utc_now(), 1, :day)
    assert %{running_failed: 1} = Reaper.reap(now: later)

    run = reload(run)
    assert run.status == "failed"
    assert run.error =~ "abandoned"
    assert [%{status: "failed", reason: "abandoned"}, %{status: "skipped"}] = run.steps
  end

  test "large output is stored as its last 64 KiB", ctx do
    stub_vm(ctx.test_pid,
      exec: fn _line, _opts ->
        output = String.duplicate("x", 65_535) <> "!"
        {:ok, %{exit_code: 0, output: output, output_truncated: true}}
      end
    )

    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})
    perform(run)

    [step] = reload(run).steps
    assert byte_size(step.output) == 65_536
    assert String.ends_with?(step.output, "!")
    assert step.output_truncated
  end

  test "a duplicate delivery is a no-op", ctx do
    stub_vm(ctx.test_pid, exists?: true)
    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})

    assert %{"result" => "succeeded"} = perform(run)
    _ = vm_calls()
    assert %{"result" => "skipped"} = perform(run)
    assert vm_calls() == []
  end

  test "recipe edits after enqueue do not change the commands", ctx do
    stub_vm(ctx.test_pid, exists?: true)
    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})

    {:ok, _} =
      Spry.replace_recipe(ctx.account, ctx.project, ctx.recipe.id, %{
        "name" => "renamed",
        "setup" => ["rm -rf /"]
      })

    perform(run)

    assert vm_calls() == [
             {:exists?, "app-feat-x"},
             {:exec, "echo s1 app-feat-x"},
             {:exec, "echo s2"}
           ]
  end

  describe "credentials" do
    test "a replacement before claim is used for every operation", ctx do
      stub_vm(ctx.test_pid, exists?: false)
      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})
      credential_fixture(ctx.account, "replacement-2222")

      perform(run)
      tokens = collect_tokens()
      assert tokens != []
      assert Enum.all?(tokens, &(&1 == "replacement-2222"))
    end

    test "removal before claim fails before any VM operation", ctx do
      reject(&Wrapper.exists?/3)
      reject(&Wrapper.create/3)
      reject(&Wrapper.exec/4)
      reject(&Wrapper.destroy/3)

      run = queued_run(ctx.account, ctx.recipe, %{"phase" => "setup"})
      Spry.delete_credential(ctx.account)

      perform(run)
      run = reload(run)
      assert run.status == "failed"
      assert run.error =~ "credential"
    end

    test "a change during execution keeps the original client", ctx do
      account = ctx.account

      stub_vm(ctx.test_pid,
        exists?: false,
        exec: fn
          "echo s1 app-feat-x", _opts ->
            credential_fixture(account, "mid-run-3333")
            {:ok, %{exit_code: 0, output: "", output_truncated: false}}

          _line, _opts ->
            Spry.delete_credential(account)
            {:ok, %{exit_code: 0, output: "", output_truncated: false}}
        end
      )

      run = queued_run(account, ctx.recipe, %{"phase" => "setup"})
      assert %{"result" => "succeeded"} = perform(run)

      tokens = collect_tokens()
      assert length(tokens) == 4
      assert Enum.all?(tokens, &(&1 == @token))
    end
  end

  test "a raised exception marks the run failed without leaking the token", ctx do
    stub_vm(ctx.test_pid, exec: fn _line, _opts -> raise "kaboom #{@token}" end)
    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})

    perform(run)
    run = reload(run)
    assert run.status == "failed"
    assert run.error =~ "kaboom"
    refute run.error =~ @token
    assert [%{status: "failed"}] = run.steps
  end

  test "a credential fetch failure (e.g. decryption) marks the run failed", ctx do
    stub_vm(ctx.test_pid, [])
    stub(Spry, :fetch_token, fn _account_id -> raise "decryption failed" end)
    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})

    assert %{"result" => "failed"} = perform(run)
    run = reload(run)
    assert run.status == "failed"
    assert run.error =~ "internal error: decryption failed"
    assert run.steps == []
    assert vm_calls() == []
  end

  test "an exit during a step marks the run failed without leaking the token", ctx do
    stub_vm(ctx.test_pid,
      exec: fn _line, _opts -> exit({:timeout, {GenServer, :call, [@token]}}) end
    )

    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})

    assert %{"result" => "failed"} = perform(run)
    run = reload(run)
    assert run.status == "failed"
    assert run.error =~ "internal error: process exited"
    refute run.error =~ @token
    assert [%{status: "failed"}] = run.steps
  end

  test "a throw during a step marks the run failed", ctx do
    stub_vm(ctx.test_pid, exec: fn _line, _opts -> throw(:oops) end)
    run = queued_run(ctx.account, ctx.recipe, %{"phase" => "start"})

    assert %{"result" => "failed"} = perform(run)
    assert reload(run).error =~ "uncaught throw: :oops"
  end

  defp collect_tokens(acc \\ []) do
    receive do
      {:vm, _kind, _arg, token} -> collect_tokens([token | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
