defmodule GoodFlows.CachesConcurrencyTest do
  # Not async and outside the SQL sandbox: each racing reservation needs its
  # own database connection, or the project row lock would never contend.
  # Rows are committed for real; the account (cascading to its project and
  # entries) and the queued object keys are deleted in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.CacheFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.{Account, ApiKey, User}
  alias GoodFlows.Caches
  alias GoodFlows.Caches.{Entry, Keys}
  alias GoodFlows.Repo

  @gib 1_073_741_824

  setup do
    ctx =
      unboxed(fn ->
        user = user_fixture()
        {:ok, account} = Accounts.create_account(user, %{name: "Race #{System.unique_integer()}"})
        account_user = Accounts.get_account_user(user, account)
        {sk_key, _token} = api_key_fixture(account_user, %{type: :private})
        %{account: account, user: user, sk_key: sk_key, project: project_fixture(account)}
      end)

    on_exit(fn ->
      unboxed(fn ->
        prefix = "caches/#{ctx.project.id}/%"
        Repo.delete_all(from a in Account, where: a.id == ^ctx.account.id)
        Repo.delete_all(from u in User, where: u.id == ^ctx.user.id)
        Repo.delete_all(from d in "cache_object_deletions", where: like(d.object_key, ^prefix))
      end)
    end)

    ctx
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp racer(parent, ctx, key, attrs),
    do: unboxed(fn -> reserve_at_barrier(parent, ctx, key, attrs) end)

  defp reserve_at_barrier(parent, ctx, key, attrs) do
    send(parent, {:ready, self()})

    receive do
      :go -> Caches.reserve(ctx.account, ctx.project, ctx.sk_key, key, attrs)
    end
  end

  defp race(ctx, bodies) do
    parent = self()

    tasks =
      for {key, attrs} <- bodies do
        Task.async(fn -> racer(parent, ctx, key, attrs) end)
      end

    for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end

  test "concurrent reservations of one key in one scope yield one success", ctx do
    for round <- 1..5 do
      key = hex({:same, round})
      results = race(ctx, for(_ <- 1..4, do: {key, reservation_body("x")}))

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :cache_conflict})) == 3
    end
  end

  test "concurrent mints at the key cap yield one success", ctx do
    cap = Caches.setting(:cache_max_keys_per_project)
    now = DateTime.utc_now(:second)
    account_user = unboxed(fn -> owner_account_user(ctx.account) end)

    rows =
      for i <- 1..(cap - 1) do
        %{
          id: Ecto.UUID.generate(),
          name: "key #{i}",
          type: :cache_read,
          token_prefix: "ck_race#{i}",
          token_hash: "race-hash-#{ctx.project.id}-#{i}",
          status: :active,
          expires_at: DateTime.add(now, 3_600, :second),
          account_user_id: account_user.id,
          project_id: ctx.project.id,
          inserted_at: now,
          updated_at: now
        }
      end

    unboxed(fn -> Repo.insert_all(ApiKey, rows) end)
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Keys.mint(account_user, ctx.project, %{"access" => "read"})
            end
          end)
        end)
      end

    for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    results = Task.await_many(tasks, 15_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:unprocessable, _}}, &1)) == 1

    count =
      unboxed(fn ->
        Repo.aggregate(from(k in ApiKey, where: k.project_id == ^ctx.project.id), :count)
      end)

    assert count == cap
  end

  test "concurrent reservations never exceed the quota together", ctx do
    # An unexpired reservation cannot be evicted, so only 10 GiB stay free:
    # room for two 4 GB reservations. Six racers stay within the test pool.
    unboxed(fn -> reservation_fixture(ctx.project, size: 40 * @gib) end)
    attrs = reservation_body("x", %{"size" => 4_000_000_000})
    results = race(ctx, for(i <- 1..6, do: {hex({:q, i}), attrs}))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 2
    assert Enum.count(results, &(&1 == {:error, :quota_exceeded})) == 4

    bytes =
      unboxed(fn ->
        Repo.one(from e in Entry, where: e.project_id == ^ctx.project.id, select: sum(e.size))
      end)

    assert Decimal.to_integer(bytes) <= 50 * @gib
  end
end
