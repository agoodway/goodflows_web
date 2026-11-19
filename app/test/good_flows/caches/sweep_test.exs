defmodule GoodFlows.Caches.SweepTest do
  use GoodFlows.DataCase, async: true

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.CacheFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Caches.{Entry, Sweep, SweepJob, SweepScheduler}
  alias GoodFlows.Caches.ObjectStore.Fake

  setup do
    account = account_fixture()
    account_user_fixture(account, user_fixture(), :owner)
    %{account: account, project: project_fixture(account)}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp queued?(object_key),
    do: Repo.exists?(from d in "cache_object_deletions", where: d.object_key == ^object_key)

  # A row's object is queued with `delete_after` no earlier than the delete,
  # and the sweep waits 60 seconds past it (clock-skew margin). Moves the
  # project's queue rows past that margin.
  defp age_queue(project) do
    prefix = "caches/#{project.id}/%"

    Repo.update_all(from(d in "cache_object_deletions", where: like(d.object_key, ^prefix)),
      set: [delete_after: DateTime.to_naive(ago(61))]
    )
  end

  test "expired reservations and stale entries are deleted, and their objects removed", ctx do
    expired = reservation_fixture(ctx.project, expires_at: ago(1))
    live = reservation_fixture(ctx.project)
    stale = entry_fixture(ctx.project, last_accessed_at: ago(8 * 86_400))
    recent = entry_fixture(ctx.project, last_accessed_at: ago(6 * 86_400))
    assert Fake.exists?(stale.object_key)

    summary = Sweep.run()
    assert summary.reservations_expired >= 1
    assert summary.entries_evicted >= 1

    refute Repo.get(Entry, expired.id)
    refute Repo.get(Entry, stale.id)
    assert Repo.get(Entry, live.id)
    assert Repo.get(Entry, recent.id)

    # Queued by this sweep: within the margin, so the object stays.
    assert Fake.exists?(stale.object_key)
    assert queued?(stale.object_key)

    age_queue(ctx.project)
    Sweep.run()
    refute Fake.exists?(stale.object_key)
    refute queued?(stale.object_key)
    # The reservation never got an object: the store's 404 clears the row.
    refute queued?(expired.object_key)
  end

  test "cache keys revoked or expired more than 7 days ago are deleted", ctx do
    {old_revoked, _} = cache_key_fixture(ctx.account, ctx.project)
    {new_revoked, _} = cache_key_fixture(ctx.account, ctx.project)
    {old_expired, _} = cache_key_fixture(ctx.account, ctx.project)
    {new_expired, _} = cache_key_fixture(ctx.account, ctx.project)

    {forever, token} =
      cache_key_fixture(ctx.account, ctx.project, %{
        "access" => "read",
        "ttl_seconds" => nil,
        "name" => "orbs"
      })

    eight_days = DateTime.utc_now(:second) |> DateTime.add(-8, :day)
    six_days = DateTime.utc_now(:second) |> DateTime.add(-6, :day)

    Repo.update_all(from(k in ApiKey, where: k.id == ^old_revoked.id),
      set: [status: :revoked, updated_at: eight_days]
    )

    Repo.update_all(from(k in ApiKey, where: k.id == ^new_revoked.id),
      set: [status: :revoked, updated_at: six_days]
    )

    Repo.update_all(from(k in ApiKey, where: k.id == ^old_expired.id),
      set: [expires_at: eight_days]
    )

    Repo.update_all(from(k in ApiKey, where: k.id == ^new_expired.id),
      set: [expires_at: six_days]
    )

    # A dashboard key revoked long ago is not the sweep's to delete.
    au = owner_account_user(ctx.account)
    {dashboard, _} = api_key_fixture(au, %{type: :private})

    Repo.update_all(from(k in ApiKey, where: k.id == ^dashboard.id),
      set: [status: :revoked, updated_at: eight_days]
    )

    Sweep.run()

    refute Repo.get(ApiKey, old_revoked.id)
    refute Repo.get(ApiKey, old_expired.id)
    assert Repo.get(ApiKey, new_revoked.id)
    assert Repo.get(ApiKey, new_expired.id)
    assert Repo.get(ApiKey, forever.id)
    assert Repo.get(ApiKey, dashboard.id)
    assert {:ok, _} = GoodFlows.Accounts.verify_api_token(token)
  end

  test "deletions run in batches until done; objects one batch per sweep", ctx do
    entries = for _ <- 1..5, do: entry_fixture(ctx.project, last_accessed_at: ago(8 * 86_400))

    summary = Sweep.run(batch_size: 2)
    assert summary.entries_evicted == 5
    assert summary.objects_deleted == 0
    assert Enum.count(entries, &queued?(&1.object_key)) == 5

    age_queue(ctx.project)
    assert Sweep.run(batch_size: 2).objects_deleted == 2
    assert Enum.count(entries, &queued?(&1.object_key)) == 3
    assert Sweep.run(batch_size: 2).objects_deleted == 2
    assert Sweep.run(batch_size: 2).objects_deleted == 1
    refute Enum.any?(entries, &queued?(&1.object_key))
    refute Enum.any?(entries, &Fake.exists?(&1.object_key))
  end

  test "no object delete starts once the time budget is spent", ctx do
    entry = entry_fixture(ctx.project)
    Repo.delete!(entry)
    age_queue(ctx.project)

    assert %{objects_deleted: 0, objects_failed: 0} = Sweep.run(time_budget_ms: 0)
    assert queued?(entry.object_key)
    assert Fake.exists?(entry.object_key)

    assert Sweep.run().objects_deleted >= 1
    refute queued?(entry.object_key)
  end

  test "a failed delete stays queued and a later sweep deletes it", ctx do
    entry = entry_fixture(ctx.project)
    Fake.fail_deletes(entry.object_key)
    on_exit(fn -> Fake.heal(entry.object_key) end)
    Repo.delete!(entry)
    age_queue(ctx.project)

    assert Sweep.run().objects_failed >= 1
    assert queued?(entry.object_key)
    assert Fake.exists?(entry.object_key)

    Fake.heal(entry.object_key)
    Sweep.run()
    refute queued?(entry.object_key)
    refute Fake.exists?(entry.object_key)
  end

  test "sweeps are idempotent", ctx do
    entry_fixture(ctx.project, last_accessed_at: ago(8 * 86_400))
    Sweep.run()

    assert %{reservations_expired: 0, entries_evicted: 0, objects_deleted: 0, objects_failed: 0} =
             Sweep.run()
  end

  test "SweepJob runs a sweep" do
    pgflow_ctx = %PgFlow.Context{
      run_id: Ecto.UUID.generate(),
      step_slug: :sweep,
      task_index: 0,
      attempt: 1,
      repo: Repo
    }

    assert %{"entries_evicted" => _, "objects_deleted" => _} = SweepJob.perform(%{}, pgflow_ctx)
  end

  test "the scheduler enqueues from the leader only" do
    test_pid = self()
    leader_name = {__MODULE__, make_ref()}

    for id <- [:a, :b] do
      start_supervised!(
        {SweepScheduler,
         name: :"sweep_#{id}_#{System.unique_integer([:positive])}",
         interval_ms: 10,
         leader_name: leader_name,
         enqueue: fn -> send(test_pid, {:enqueued, id}) end},
        id: id
      )
    end

    assert_receive {:enqueued, leader}, 1_000
    for _ <- 1..3, do: assert_receive({:enqueued, ^leader}, 1_000)
    follower = if leader == :a, do: :b, else: :a
    refute_received {:enqueued, ^follower}
  end

  test "it starts next to the Spry reaper scheduler" do
    children = GoodFlows.Application.pgflow_children(repo: Repo)
    assert GoodFlows.Spry.ReaperScheduler in children
    assert GoodFlows.Caches.SweepScheduler in children
  end
end
