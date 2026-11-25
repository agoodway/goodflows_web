defmodule GoodFlows.VerifyRunsConcurrencyTest do
  # Not async and outside the SQL sandbox: each racer needs its own
  # connection. Rows are committed and deleted in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.{Account, User}
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.Repo
  alias GoodFlows.ScenarioSets
  alias GoodFlows.VerifyRuns
  alias GoodFlows.VerifyRuns.Run

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    ctx =
      unboxed(fn ->
        user = user_fixture()

        {:ok, account} =
          Accounts.create_account(user, %{name: "VRace #{System.unique_integer()}"})

        owner = Accounts.get_account_user(user, account)
        {key, _} = api_key_fixture(owner, %{type: :private})
        project = project_fixture(account)

        {:ok, cr} =
          ChangeRequests.create(account, project, key, %{
            "title" => "t",
            "source_branch" => "b",
            "change_id" => "add-export"
          })

        {:ok, :created, set} =
          ScenarioSets.upload(cr, key, set_body(intent_fm("add-export", [scenario("S1")])))

        %{account: account, user: user, key: key, project: project, digest: set.digest}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from r in Run, where: r.account_id == ^ctx.account.id)
        Repo.delete_all(from c in ChangeRequest, where: c.account_id == ^ctx.account.id)
        Repo.delete_all(from a in Account, where: a.id == ^ctx.account.id)
        Repo.delete_all(from u in User, where: u.id == ^ctx.user.id)
      end)
    end)

    ctx
  end

  test "concurrent equal uploads store one run", ctx do
    document = run_doc(ctx.digest, "intent", sha(1), [result("S1")])
    parent = self()

    tasks =
      for _ <- 1..6 do
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> VerifyRuns.ingest(ctx.account, ctx.project, ctx.key, document))
          end)
        end)
      end

    pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
    Enum.each(pids, &send(&1, :go))
    results = Task.await_many(tasks, 15_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Enum.count(results, fn {:ok, r} -> not r.duplicate end) == 1
    assert results |> Enum.map(fn {:ok, r} -> r.run.id end) |> Enum.uniq() |> length() == 1

    assert unboxed(fn ->
             Repo.aggregate(from(r in Run, where: r.project_id == ^ctx.project.id), :count)
           end) == 1
  end
end
