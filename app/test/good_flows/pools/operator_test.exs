defmodule GoodFlows.Pools.OperatorTest do
  use GoodFlows.DataCase, async: true

  import ExUnit.CaptureLog
  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Pools.Operator

  setup do
    account = account_fixture()
    credential_fixture(account)
    %{pool: account |> project_fixture() |> pool_fixture()}
  end

  test "forget_member/1 removes only abandoned members, with an audit log line", ctx do
    abandoned = member_fixture(ctx.pool, %{state: "abandoned", last_error: "destroy failed: 401"})
    idle = member_fixture(ctx.pool)

    log = capture_log(fn -> assert Operator.forget_member(abandoned.id) == :ok end)
    assert log =~ abandoned.name
    assert log =~ "destroy failed: 401"
    refute Repo.reload(abandoned)

    assert Operator.forget_member(idle.id) == {:error, :not_abandoned}
    assert Repo.reload(idle)
    assert Operator.forget_member(Ecto.UUID.generate()) == {:error, :not_abandoned}
  end
end
