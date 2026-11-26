defmodule GoodFlows.WorkflowRunsNotifyTest do
  # Not async and outside the SQL sandbox: Postgres delivers a notification
  # only on commit. Rows are committed; the account (cascading to its
  # project and runs) is deleted in on_exit.
  use ExUnit.Case, async: false
  use Mimic

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts.Account
  alias GoodFlows.Repo
  alias GoodFlows.WorkflowRuns
  alias GoodFlows.WorkflowRuns.Store

  setup :verify_on_exit!

  setup do
    {account, project} =
      unboxed(fn ->
        account = account_fixture()
        {account, project_fixture(account)}
      end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from a in Account, where: a.id == ^account.id) end)
    end)

    Phoenix.PubSub.subscribe(GoodFlows.PubSub, WorkflowRuns.topic(project.id))
    %{account: account, project: project}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp ingest(ctx, document),
    do: unboxed(fn -> WorkflowRuns.ingest(ctx.account, ctx.project, nil, document) end)

  test "a first insert is broadcast, an exact retry is not", ctx do
    project_id = ctx.project.id
    run_id = minimal()["run_id"]

    assert {:ok, %{duplicate: false}} = ingest(ctx, minimal())
    assert_receive {:workflow_run_stored, ^project_id, ^run_id}, 2_000

    assert {:ok, %{duplicate: true}} = ingest(ctx, minimal())
    refute_receive {:workflow_run_stored, _project_id, _run_id}, 300
  end

  test "an upload that rolls back is not broadcast", ctx do
    expect(Store, :transaction, fn fun, opts ->
      Repo.transaction(fn -> Repo.rollback({:rolled_back, fun.()}) end, opts)
    end)

    assert_raise MatchError, fn -> ingest(ctx, minimal()) end
    refute_receive {:workflow_run_stored, _project_id, _run_id}, 300

    assert unboxed(fn ->
             Repo.aggregate(
               from(r in WorkflowRuns.Run, where: r.project_id == ^ctx.project.id),
               :count
             )
           end) == 0
  end
end
