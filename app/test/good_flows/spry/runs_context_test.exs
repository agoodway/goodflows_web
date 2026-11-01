defmodule GoodFlows.Spry.RunsContextTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Spry
  alias GoodFlows.Spry.Run
  alias GoodFlows.Spry.Sprites, as: Wrapper

  @moduletag :capture_log

  setup do
    account = account_fixture()
    credential_fixture(account)

    recipe =
      recipe_fixture(account, %{
        "name" => "app-{{branch_slug}}",
        "setup" => ["echo setup {{sprite}}", "echo two"],
        "start" => ["echo start"],
        "teardown" => ["echo bye"]
      })

    %{account: account, recipe: recipe}
  end

  defp reject_mutations do
    reject(&Wrapper.create/3)
    reject(&Wrapper.exec/4)
    reject(&Wrapper.destroy/3)
  end

  describe "request_run/4 dry run" do
    test "setup with a missing VM plans create then the lines", %{
      account: account,
      recipe: recipe
    } do
      expect(Wrapper, :exists?, fn _client, "app-feat-x", _opts -> {:ok, false} end)
      reject_mutations()

      assert {:ok, %{sprite_exists: false, steps: steps, plan: plan}} =
               dry_run(account, recipe.id, %{"phase" => "setup", "branch" => "feat/x"})

      assert plan.sprite_name == "app-feat-x"

      assert steps == [
               %{kind: "create", command: "create app-feat-x"},
               %{kind: "exec", command: "echo setup app-feat-x"},
               %{kind: "exec", command: "echo two"}
             ]

      assert Repo.aggregate(Run, :count) == 0
    end

    test "teardown lists lines then destroy, or no destroy with no_destroy", ctx do
      stub(Wrapper, :exists?, fn _client, _name, _opts -> {:ok, true} end)
      reject_mutations()

      assert {:ok, %{steps: [%{kind: "exec"}, %{kind: "destroy"}]}} =
               dry_run(ctx.account, ctx.recipe.id, %{"phase" => "teardown", "branch" => "x"})

      assert {:ok, %{steps: [%{kind: "exec"}]}} =
               dry_run(ctx.account, ctx.recipe.id, %{
                 "phase" => "teardown",
                 "branch" => "x",
                 "no_destroy" => true
               })
    end

    test "fails where the run would", ctx do
      stub(Wrapper, :exists?, fn _client, _name, _opts -> {:ok, false} end)
      reject_mutations()

      assert {:error, {:unprocessable, message}} =
               dry_run(ctx.account, ctx.recipe.id, %{"phase" => "start", "branch" => "x"})

      assert message =~ "does not exist"

      assert {:error, {:unprocessable, message}} =
               dry_run(ctx.account, ctx.recipe.id, %{
                 "phase" => "setup",
                 "branch" => "x",
                 "no_create" => true
               })

      assert message =~ "does not exist"
    end

    test "lookup errors are 422 and never claim the sprite is missing", ctx do
      stub(Wrapper, :exists?, fn _client, _name, _opts ->
        {:error, %{status: 401, message: "unauthorized"}}
      end)

      assert {:error, {:unprocessable, message}} =
               dry_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"})

      assert message =~ "unauthorized"
    end

    test "the sprite lookup uses a short timeout, not the step timeout", ctx do
      expect(Wrapper, :exists?, fn _client, _name, opts ->
        assert Keyword.fetch!(opts, :timeout) == 15_000
        {:ok, true}
      end)

      assert {:ok, _} =
               dry_run(ctx.account, ctx.recipe.id, %{"phase" => "start", "branch" => "x"})
    end

    test "an invalid phase is reported before a missing credential", ctx do
      reject(&Wrapper.exists?/3)
      Spry.delete_credential(ctx.account)

      assert {:error, %Ecto.Changeset{} = cs} =
               dry_run(ctx.account, ctx.recipe.id, %{"phase" => "deploy"})

      assert %{phase: [_]} = errors_on(cs)
    end

    test "requires a credential and valid inputs", ctx do
      reject(&Wrapper.exists?/3)

      assert {:error, %Ecto.Changeset{}} =
               dry_run(ctx.account, ctx.recipe.id, %{"phase" => "setup"})

      Spry.delete_credential(ctx.account)

      assert {:error, {:unprocessable, message}} =
               dry_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"})

      assert message =~ "Sprites credential"
    end
  end

  describe "request_run/4 admission" do
    setup do
      compile_jobs!()
      reject(&Wrapper.exists?/3)
      reject_mutations()
      :ok
    end

    test "queues a run with its plan snapshot and job", %{account: account, recipe: recipe} do
      assert {:ok, run} =
               start_run(account, recipe.id, %{"phase" => "setup", "branch" => "feat/x"})

      assert run.status == "queued"
      assert run.sprite_name == "app-feat-x"
      assert run.plan["commands"] == ["echo setup app-feat-x", "echo two"]
      assert run.inputs["branch"] == "feat/x"
      assert is_binary(run.pgflow_run_id)
      assert queued_job_messages() == 1
    end

    test "requires a credential", %{account: account, recipe: recipe} do
      Spry.delete_credential(account)

      assert {:error, {:unprocessable, message}} =
               start_run(account, recipe.id, %{"phase" => "setup", "branch" => "x"})

      assert message =~ "Sprites credential"
      assert Repo.aggregate(Run, :count) == 0
    end

    test "an invalid phase is reported before a missing credential", ctx do
      Spry.delete_credential(ctx.account)

      assert {:error, %Ecto.Changeset{} = cs} =
               start_run(ctx.account, ctx.recipe.id, %{"phase" => "deploy"})

      assert %{phase: [_]} = errors_on(cs)
    end

    test "missing inputs fail before anything is created", %{account: account, recipe: recipe} do
      assert {:error, %Ecto.Changeset{} = cs} =
               start_run(account, recipe.id, %{"phase" => "setup"})

      assert %{branch: [_]} = errors_on(cs)
      assert Repo.aggregate(Run, :count) == 0
    end

    test "conflicts with an active run for the same sprite", %{account: account, recipe: recipe} do
      active = run_fixture(account, recipe, sprite_name: "app-feat-x", status: "running")

      assert start_run(account, recipe.id, %{"phase" => "teardown", "branch" => "feat/x"}) ==
               {:error, {:conflict, active.id}}

      assert Repo.aggregate(Run, :count) == 1
    end

    test "accepts a different sprite or a sprite whose run finished", ctx do
      run_fixture(ctx.account, ctx.recipe, sprite_name: "app-feat-x", status: "running")
      run_fixture(ctx.account, ctx.recipe, sprite_name: "app-feat-z", status: "failed")

      assert {:ok, _} =
               start_run(ctx.account, ctx.recipe.id, %{
                 "phase" => "setup",
                 "branch" => "feat/y"
               })

      assert {:ok, _} =
               start_run(ctx.account, ctx.recipe.id, %{
                 "phase" => "setup",
                 "branch" => "feat/z"
               })
    end

    test "queued plans do not change when the recipe is edited", ctx do
      {:ok, run} =
        start_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"})

      {:ok, _} =
        Spry.replace_recipe(ctx.account, ctx.recipe.id, %{
          "name" => "renamed",
          "setup" => ["rm -rf /"]
        })

      reloaded = Repo.get!(Run, run.id)
      assert reloaded.sprite_name == "app-x"
      assert reloaded.plan["commands"] == ["echo setup app-x", "echo two"]
    end

    test "an enqueue failure leaves neither a run nor a queue message", ctx do
      stub(PgFlow, :enqueue, fn module, input ->
        {:ok, _id} = call_original(PgFlow, :enqueue, [module, input])
        {:error, :boom}
      end)

      assert {:error, {:enqueue_failed, :boom}} =
               start_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"})

      assert Repo.aggregate(Run, :count) == 0
      assert queued_job_messages() == 0
      assert pgflow_run_count() == 0
    end

    test "only the one-active-run index is a conflict; other sprite_name errors are 422", ctx do
      reject(&Spry.active_run_id/2)

      stub(Run, :admission_changeset, fn run, attrs ->
        Run
        |> call_original(:admission_changeset, [run, attrs])
        |> Ecto.Changeset.add_error(:sprite_name, "is reserved")
      end)

      assert {:error, %Ecto.Changeset{} = cs} =
               start_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"})

      assert %{sprite_name: ["is reserved"]} = errors_on(cs)
      assert Repo.aggregate(Run, :count) == 0
    end

    test "records the API key that started the run", ctx do
      assert {:ok, %Run{started_by_api_key_id: nil}} =
               start_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"})

      user = user_fixture()
      account_user = account_user_fixture(ctx.account, user, :owner)
      {api_key, _token} = api_key_fixture(account_user, %{type: :private})

      assert {:ok, %Run{started_by_api_key_id: id}} =
               start_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "y"},
                 started_by_api_key_id: api_key.id
               )

      assert id == api_key.id
    end

    test "an enqueue failure is logged with the run id and reason", ctx do
      stub(PgFlow, :enqueue, fn _module, _input -> {:error, :queue_down} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, {:enqueue_failed, :queue_down}} =
                   start_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"})
        end)

      assert log =~ ~r/Could not enqueue Spry run [0-9a-f-]{36}/
      assert log =~ ":queue_down"
    end

    test "retries admission when the conflicting run has already finished", ctx do
      blocker = run_fixture(ctx.account, ctx.recipe, sprite_name: "app-x", status: "running")

      expect(Spry, :active_run_id, fn _account, "app-x" ->
        Repo.update!(Ecto.Changeset.change(blocker, status: "failed"))
        nil
      end)

      assert {:ok, run} =
               start_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"})

      assert run.sprite_name == "app-x"
    end

    test "never reports a conflict without identifying the active run", ctx do
      run_fixture(ctx.account, ctx.recipe, sprite_name: "app-x", status: "running")
      # Every lookup races a finishing run: admission retries, then gives up
      # with a retryable error instead of {:conflict, nil}.
      expect(Spry, :active_run_id, 5, fn _account, "app-x" -> nil end)

      assert start_run(ctx.account, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"}) ==
               {:error, :admission_contended}

      assert Repo.aggregate(Run, :count) == 1
    end

    test "unknown recipes are not found", ctx do
      assert start_run(ctx.account, Ecto.UUID.generate(), %{"phase" => "setup"}) ==
               {:error, :not_found}

      other = account_fixture()
      credential_fixture(other)

      assert start_run(other, ctx.recipe.id, %{"phase" => "setup", "branch" => "x"}) ==
               {:error, :not_found}
    end
  end

  describe "request_run/3" do
    setup do
      compile_jobs!()
      :ok
    end

    test "decides dry run from the cast flag, so \"1\" never queues a run", ctx do
      stub(Wrapper, :exists?, fn _client, _name, _opts -> {:ok, true} end)
      reject_mutations()

      for value <- [true, "true", "1"] do
        assert {:ok, {:plan, %{plan: %{dry_run: true}}}} =
                 Spry.request_run(ctx.account, ctx.recipe.id, %{
                   "phase" => "start",
                   "branch" => "x",
                   "dry_run" => value
                 })
      end

      assert Repo.aggregate(Run, :count) == 0
    end

    test "false or absent dry_run admits a run", ctx do
      reject(&Wrapper.exists?/3)

      assert {:ok, {:run, %Run{status: "queued"}}} =
               Spry.request_run(ctx.account, ctx.recipe.id, %{
                 "phase" => "start",
                 "branch" => "x",
                 "dry_run" => "0"
               })
    end
  end

  describe "request_run/4 admission without compiled jobs" do
    test "flow_not_compiled rolls back the run", %{account: account, recipe: recipe} do
      _ = PgFlow.delete_flow("spry_run")

      assert {:error, {:enqueue_failed, {:flow_not_compiled, _}}} =
               start_run(account, recipe.id, %{"phase" => "setup", "branch" => "x"})

      assert Repo.aggregate(Run, :count) == 0
    end
  end
end
