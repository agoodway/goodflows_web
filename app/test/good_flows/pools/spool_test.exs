defmodule GoodFlows.Pools.SpoolTest do
  use ExUnit.Case, async: false

  alias GoodFlows.Pools.{Config, Spool}

  setup do
    original = Application.get_env(:good_flows, GoodFlows.Pools)
    on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
    %{original: original}
  end

  defp put_config(ctx, overrides),
    do: Application.put_env(:good_flows, GoodFlows.Pools, Keyword.merge(ctx.original, overrides))

  test "the boot janitor removes spools of earlier boots and keeps this boot's" do
    old = Path.join([Spool.node_dir(), "previous-boot", "session"])
    File.mkdir_p!(old)
    current = Spool.session_dir(Ecto.UUID.generate())
    File.mkdir_p!(current)

    assert Spool.janitor() >= 1
    refute File.exists?(Path.dirname(old))
    assert File.exists?(current)
    File.rm_rf!(current)
  end

  test "the janitor never touches another node's spools under a shared spool_dir" do
    other = Path.join([Config.spool_dir(), "other-node@host", "some-boot", "session"])
    File.mkdir_p!(other)

    Spool.janitor()
    assert File.exists?(other)
    File.rm_rf!(Path.join(Config.spool_dir(), "other-node@host"))
  end

  test "reservations are bounded by the node budget and the per-account caps", ctx do
    put_config(ctx, spool_max_bytes: 1_000, spool_account_max_bytes: 1_000)
    {:ok, a} = Spool.reserve("acct-a", 1_000)
    assert Spool.reserve("acct-b", 1) == {:error, :busy}
    Spool.release(a)
    _ = Spool.reserved_bytes()

    {:ok, b} = Spool.reserve("acct-a", 10)
    assert Spool.reserve("acct-a", 10) == {:error, :busy}
    # A settled upload keeps only its actual bytes and frees the account's
    # upload slot.
    Spool.settle(b, 4)
    assert {:ok, c} = Spool.reserve("acct-a", 10)
    assert Spool.reserved_bytes() == 14
    Spool.release(b)
    Spool.release(c)
    assert Spool.reserved_bytes() == 0
  end

  test "a finished upload no longer holds its full reservation", ctx do
    put_config(ctx, spool_max_bytes: 1_000, spool_account_max_bytes: 1_000)
    {:ok, a} = Spool.reserve("acct-a", 600)
    Spool.settle(a, 50)

    # 600 + 600 would exceed the budget; 50 + 600 does not.
    assert {:ok, b} = Spool.reserve("acct-b", 600)
    Spool.release(a)
    Spool.release(b)
    assert Spool.reserved_bytes() == 0
  end

  test "one account cannot take more than its byte share of the node budget", ctx do
    put_config(ctx,
      spool_max_bytes: 1_000,
      spool_account_max_bytes: 400,
      workspace_max_concurrent_uploads_per_account: 10
    )

    {:ok, a} = Spool.reserve("acct-a", 300)
    Spool.settle(a, 300)
    assert Spool.reserve("acct-a", 200) == {:error, :busy}
    assert {:ok, b} = Spool.reserve("acct-b", 200)
    Spool.release(a)
    Spool.release(b)
    assert Spool.reserved_bytes() == 0
  end

  test "report reservations count bytes but not upload slots", ctx do
    put_config(ctx, spool_max_bytes: 1_000, spool_account_max_bytes: 1_000)
    {:ok, upload} = Spool.reserve("acct-a", 100)
    assert {:ok, report} = Spool.reserve("acct-a", 300, self(), :report)
    assert Spool.reserved_bytes() == 400
    Spool.settle(report, 20)
    assert Spool.reserved_bytes() == 120
    assert Spool.reserve("acct-a", 950, self(), :report) == {:error, :busy}
    Spool.release(upload)
    Spool.release(report)
    assert Spool.reserved_bytes() == 0
  end

  test "a reservation is released when its holder exits" do
    holder = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, _ref} = Spool.reserve("acct-x", 100, holder)
    assert Spool.reserved_bytes() >= 100
    ref = Process.monitor(holder)
    send(holder, :stop)
    assert_receive {:DOWN, ^ref, :process, _, _}
    _ = :sys.get_state(Spool)
    assert Spool.reserved_bytes() == 0
  end
end
