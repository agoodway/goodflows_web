defmodule GoodFlows.ChangeRequests.InlineRecomputeLimitTest do
  # Sync: the test sets a global application env that async tests must not see.
  use GoodFlows.DataCase, async: false
  use Mimic

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.RecomputeJob
  alias GoodFlows.ReviewPolicies

  setup :verify_on_exit!

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "CR #{System.unique_integer()}"})
    account_user = Accounts.get_account_user(user, account)
    {api_key, _token} = api_key_fixture(account_user, %{type: :private})
    project = project_fixture(account, %{default_branch: "main"})

    %{account: account, account_user: account_user, api_key: api_key, project: project}
  end

  test "over the inline limit, a job is enqueued in the write transaction", ctx do
    Application.put_env(:good_flows, :change_request_inline_recompute_limit, 0)

    on_exit(fn ->
      Application.delete_env(:good_flows, :change_request_inline_recompute_limit)
    end)

    body = %{"title" => "Add login", "source_branch" => "feat/login"}
    {:ok, cr} = ChangeRequests.create(ctx.account, ctx.project, ctx.api_key, body)
    project_id = ctx.project.id

    expect(PgFlow, :enqueue, fn RecomputeJob, %{"project_id" => ^project_id} -> {:ok, "run"} end)

    policy = %{
      "previous_version" => 0,
      "policy" => %{"format" => "review-policy/1", "paths" => []}
    }

    {:ok, :created, _version} =
      ReviewPolicies.write(ctx.project, ctx.account_user, ctx.api_key, policy)

    assert ChangeRequests.verdict(cr).policy_version == 0

    assert ChangeRequests.recompute_project(project_id) == 1
    assert ChangeRequests.verdict(cr).policy_version == 1

    ctx_job = %PgFlow.Context{
      run_id: Ecto.UUID.generate(),
      step_slug: :recompute,
      task_index: 0,
      attempt: 1,
      repo: Repo
    }

    assert %{"recomputed" => 1} = RecomputeJob.perform(%{"project_id" => project_id}, ctx_job)
  end
end
