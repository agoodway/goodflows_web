defmodule GoodFlows.Spry.ShutdownDrainTest do
  use GoodFlows.DataCase, async: false

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Spry.{Executions, Run, ShutdownDrain}

  @moduletag :capture_log

  setup do
    account = account_fixture()
    recipe = recipe_fixture(project_fixture(account), %{"name" => "box", "start" => ["a", "b"]})
    %{account: account, recipe: recipe}
  end

  defp running_run(ctx, sprite_name, owner_id) do
    run =
      run_fixture(ctx.account, ctx.recipe,
        phase: "start",
        sprite_name: sprite_name,
        status: "running",
        owner_id: owner_id,
        started_at: DateTime.utc_now(),
        action_started_at: DateTime.utc_now()
      )

    run_step_fixture(run, index: 0, kind: "exec", command: "a", status: "running")
    run_step_fixture(run, index: 1, kind: "exec", command: "b", status: "pending")
    run
  end

  defp reload(run), do: Run |> Repo.get!(run.id) |> Repo.preload(:steps)

  test "on shutdown, this boot's executions are stopped and their runs failed", ctx do
    test_pid = self()
    owner_id = Executions.new_owner_id()

    worker =
      spawn(fn ->
        :ok = Executions.register(owner_id)
        child = spawn(fn -> Process.sleep(:infinity) end)
        Executions.track(child)
        send(test_pid, {:ready, child})
        Process.sleep(:infinity)
      end)

    assert_receive {:ready, child}
    live = running_run(ctx, "live", owner_id)
    # Its worker already died (for example killed by PgFlow's shutdown).
    orphan = running_run(ctx, "orphan", Executions.new_owner_id())
    other_boot = running_run(ctx, "other", "#{node()}|another-boot|#{Ecto.UUID.generate()}")
    finished = run_fixture(ctx.account, ctx.recipe, sprite_name: "done", status: "succeeded")

    name = :"drain_#{System.unique_integer([:positive])}"
    start_supervised!({ShutdownDrain, name: name})
    stop_supervised!(name)

    refute Process.alive?(worker)
    refute Process.alive?(child)

    for run <- [live, orphan] do
      run = reload(run)
      assert run.status == "failed"
      assert run.error == "interrupted by server shutdown"

      assert Enum.map(run.steps, &{&1.status, &1.reason}) == [
               {"failed", "interrupted by server shutdown"},
               {"skipped", nil}
             ]
    end

    assert reload(other_boot).status == "running"
    assert reload(finished).status == "succeeded"
  end

  test "drain/0 reports how many runs it finalized", ctx do
    running_run(ctx, "one", Executions.new_owner_id())
    assert ShutdownDrain.drain() == 1
    assert ShutdownDrain.drain() == 0
  end

  test "it is started before PgFlow so it terminates after PgFlow's workers" do
    children = GoodFlows.Application.pgflow_children(repo: GoodFlows.Repo)
    assert [ShutdownDrain, {PgFlow, _opts} | _] = children
  end
end
