defmodule Mix.Tasks.Pools.DestroyMembersTest do
  use GoodFlows.DataCase, async: false
  use Mimic

  import ExUnit.CaptureIO
  import GoodFlows.AccountsFixtures
  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Pools.Member
  alias Mix.Tasks.Pools.DestroyMembers

  setup :set_mimic_global

  setup do
    account = account_fixture()
    credential_fixture(account)
    pool = account |> project_fixture() |> pool_fixture()
    %{pool: pool}
  end

  test "destroys each member with its own snapshot and keeps failures", %{pool: pool} do
    ok = member_fixture(pool)
    gone = member_fixture(pool, %{state: "leased"})
    failing = member_fixture(pool, %{token: "old_token_1234"})
    test_pid = self()

    stub(Sprites, :destroy, fn %Sprites.Sprite{name: name, client: client} ->
      send(test_pid, {:destroy, name, client.token})

      cond do
        name == ok.name -> :ok
        name == gone.name -> {:error, {:not_found, %{}}}
        true -> {:error, {:api_error, 401, %{"error" => "unauthorized"}}}
      end
    end)

    output =
      capture_io(:stderr, fn ->
        info = capture_io(fn -> DestroyMembers.run([pool.id]) end)
        send(test_pid, {:info, info})
      end)

    assert_received {:info, info}
    assert info =~ "#{ok.name}: destroyed"
    assert info =~ "#{gone.name}: destroyed"
    assert output =~ "#{failing.name}: kept (unauthorized)"

    assert_received {:destroy, _, "sprites_test_token_a1b2"}
    assert_received {:destroy, name, "old_token_1234"}
    assert name == failing.name

    assert [%Member{id: id}] = Repo.all(Ecto.Query.where(Member, pool_id: ^pool.id))
    assert id == failing.id
  end

  test "usage errors" do
    assert_raise Mix.Error, ~r/usage/, fn -> DestroyMembers.run([]) end
    assert_raise Mix.Error, ~r/UUID/, fn -> DestroyMembers.run(["nope"]) end
  end
end
