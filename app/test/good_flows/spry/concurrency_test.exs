defmodule GoodFlows.Spry.ConcurrencyTest do
  @moduledoc """
  Exercises admission and deletion races on real, committed connections
  (outside the SQL sandbox). Everything created is removed in `on_exit`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Repo
  alias GoodFlows.Spry
  alias GoodFlows.Spry.{Recipe, Run}

  @moduletag :capture_log

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    compile_jobs!()

    account = account_fixture()
    project = project_fixture(account)
    credential_fixture(account)
    user = user_fixture()
    account_user = account_user_fixture(account, user, :owner)
    {api_key, _token} = api_key_fixture(account_user, %{type: :private})

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      # Accounts cascade to projects, recipes, credentials, runs, and memberships
      # (and memberships to API keys); users are removed explicitly.
      Repo.delete_all(from k in GoodFlows.Accounts.ApiKey, where: k.id == ^api_key.id)

      Repo.delete_all(
        from au in GoodFlows.Accounts.AccountUser, where: au.account_id == ^account.id
      )

      Repo.delete_all(from a in GoodFlows.Accounts.Account, where: a.id == ^account.id)
      Repo.delete_all(from u in GoodFlows.Accounts.User, where: u.id == ^user.id)
      _ = PgFlow.delete_flow("spry_run")
      _ = PgFlow.delete_flow("spry_reap_runs")
      Sandbox.checkin(Repo)
    end)

    %{account: account, project: project, user: user, api_key: api_key}
  end

  defp async_db(fun) do
    test_pid = self()

    Task.async(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)
      send(test_pid, {:started, self()})
      fun.()
    end)
  end

  # Waits until at least `count` other backends are waiting on a lock.
  defp wait_for_lock_waiters(count, attempts \\ 100) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    cond do
      waiting >= count -> :ok
      attempts == 0 -> flunk("expected #{count} lock waiters, saw #{waiting}")
      true -> Process.sleep(20) && wait_for_lock_waiters(count, attempts - 1)
    end
  end

  test "concurrent admissions for one sprite admit exactly one run", %{
    account: account,
    project: project,
    api_key: api_key
  } do
    # Separate recipes share no row lock, so the inserts genuinely race on the
    # partial unique index.
    recipes = for i <- 1..4, do: recipe_fixture(project, %{"name" => "r#{i}", "setup" => []})

    results =
      recipes
      |> Enum.map(fn recipe ->
        async_db(fn ->
          receive do
            :go ->
              start_run(account, project, recipe.id, %{"phase" => "setup", "sprite" => "shared"},
                started_by_api_key_id: api_key.id
              )
          end
        end)
      end)
      |> tap(fn tasks -> Enum.each(tasks, &send(&1.pid, :go)) end)
      |> Task.await_many(10_000)

    assert [{:ok, winner}] = Enum.filter(results, &match?({:ok, _}, &1))
    losers = Enum.reject(results, &match?({:ok, _}, &1))
    assert length(losers) == 3
    assert Enum.all?(losers, &(&1 == {:error, {:conflict, winner.id}}))

    assert Repo.aggregate(where(Run, account_id: ^account.id), :count) == 1
    assert winner.started_by_api_key_id == api_key.id
    assert queued_job_messages() == 1
  end

  describe "deletion and admission serialize on the recipe row" do
    setup %{project: project} do
      recipe = recipe_fixture(project, %{"name" => "locked", "setup" => ["echo"]})
      test_pid = self()

      holder =
        async_db(fn ->
          Repo.transaction(fn ->
            Repo.one!(from r in Recipe, where: r.id == ^recipe.id, lock: "FOR UPDATE")
            send(test_pid, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked, 5_000
      %{recipe: recipe, holder: holder}
    end

    test "admission first: deletion returns active_run", ctx do
      admission =
        async_db(fn ->
          start_run(ctx.account, ctx.project, ctx.recipe.id, %{"phase" => "setup"})
        end)

      wait_for_lock_waiters(1)
      deletion = async_db(fn -> Spry.delete_recipe(ctx.account, ctx.project, ctx.recipe.id) end)
      wait_for_lock_waiters(2)

      send(ctx.holder.pid, :release)
      Task.await(ctx.holder)

      assert {:ok, %Run{status: "queued"}} = Task.await(admission)
      assert Task.await(deletion) == {:error, :active_run}
      assert {:ok, _} = Spry.get_recipe(ctx.account, ctx.project, ctx.recipe.id)
    end

    test "deletion first: admission returns not_found", ctx do
      deletion = async_db(fn -> Spry.delete_recipe(ctx.account, ctx.project, ctx.recipe.id) end)
      wait_for_lock_waiters(1)

      admission =
        async_db(fn ->
          start_run(ctx.account, ctx.project, ctx.recipe.id, %{"phase" => "setup"})
        end)

      wait_for_lock_waiters(2)

      send(ctx.holder.pid, :release)
      Task.await(ctx.holder)

      assert Task.await(deletion) == :ok
      assert Task.await(admission) == {:error, :not_found}
      assert Repo.aggregate(where(Run, account_id: ^ctx.account.id), :count) == 0
    end
  end
end
