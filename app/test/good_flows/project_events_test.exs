defmodule GoodFlows.ProjectEventsTest do
  # Not async and outside the SQL sandbox: notifications are delivered only
  # on commit, and the ordering test needs two connections whose locks
  # contend. Rows are committed and the account (cascading to its projects
  # and their events) is deleted in on_exit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.{Account, User}
  alias GoodFlows.ProjectEvents
  alias GoodFlows.ProjectEvents.Event
  alias GoodFlows.Repo

  setup do
    ctx =
      unboxed(fn ->
        user = user_fixture()

        {:ok, account} =
          Accounts.create_account(user, %{name: "Events #{System.unique_integer()}"})

        %{account: account, user: user, project: project_fixture(account)}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from a in Account, where: a.id == ^ctx.account.id)
        Repo.delete_all(from u in User, where: u.id == ^ctx.user.id)
      end)
    end)

    ctx
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp record(project, version),
    do:
      ProjectEvents.record(
        project.id,
        nil,
        "policy_version_created",
        %{"version" => version, "note" => nil},
        nil
      )

  defp read(ctx, params),
    do: unboxed(fn -> ProjectEvents.read(ctx.project, ctx.account.id, params) end)

  test "a rolled-back transaction leaves no event and sends no broadcast", ctx do
    Phoenix.PubSub.subscribe(GoodFlows.PubSub, ProjectEvents.topic(ctx.project.id))
    project_id = ctx.project.id

    assert {:error, :boom} =
             unboxed(fn ->
               Repo.transaction(fn ->
                 record(ctx.project, 1)
                 Repo.rollback(:boom)
               end)
             end)

    refute_receive {:project_event, ^project_id}, 300
    assert {:ok, %{events: []}} = read(ctx, %{})

    {:ok, _event} = unboxed(fn -> Repo.transaction(fn -> record(ctx.project, 2) end) end)
    assert_receive {:project_event, ^project_id}, 2_000
    assert {:ok, %{events: [%Event{data: %{"version" => 2}}]}} = read(ctx, %{})
  end

  test "ids follow commit order, so a reader with next_cursor sees both writers", ctx do
    parent = self()

    first =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            event = record(ctx.project, 1)
            send(parent, {:first_recorded, event.id})
            receive do: (:commit_first -> event)
          end)
        end)
      end)

    assert_receive {:first_recorded, _id}, 2_000

    second =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            event = record(ctx.project, 2)
            send(parent, {:second_recorded, event.id})
            receive do: (:commit_second -> event)
          end)
        end)
      end)

    # The second writer waits on the project's event lock until the first
    # commits, so it cannot take a lower id and commit first.
    refute_receive {:second_recorded, _id}, 300
    assert {:ok, %{events: [], next_cursor: nil}} = read(ctx, %{})

    send(first.pid, :commit_first)
    {:ok, a} = Task.await(first)
    assert_receive {:second_recorded, b_id}, 2_000
    assert b_id > a.id

    assert {:ok, %{events: [%Event{id: a_id}], next_cursor: cursor}} = read(ctx, %{})
    assert a_id == a.id

    send(second.pid, :commit_second)
    {:ok, _b} = Task.await(second)
    assert {:ok, %{events: [%Event{id: ^b_id}]}} = read(ctx, %{"after" => cursor})
  end

  test "a waiting read returns when an event commits", ctx do
    started = System.monotonic_time(:millisecond)
    reader = Task.async(fn -> read(ctx, %{"wait" => 30}) end)
    wait_for_waiters(ctx.account.id, 1)

    {:ok, _event} = unboxed(fn -> Repo.transaction(fn -> record(ctx.project, 1) end) end)

    assert {:ok, %{events: [%Event{data: %{"version" => 1}}]}} = Task.await(reader, 10_000)
    assert System.monotonic_time(:millisecond) - started < 10_000
  end

  test "a waiting read whose unread events are swept before it reads again is 410", ctx do
    seen = unboxed(fn -> record(ctx.project, 1) end)
    reader = Task.async(fn -> read(ctx, %{"after" => seen.id, "wait" => 30}) end)
    wait_for_waiters(ctx.account.id, 1)

    # One commit: an unread event, a sweep that deletes it, then a newer
    # event that wakes the reader.
    {:ok, newest} =
      unboxed(fn ->
        Repo.transaction(fn ->
          _swept = record(ctx.project, 2)
          ProjectEvents.sweep(DateTime.add(DateTime.utc_now(), 91, :day))
          record(ctx.project, 3)
        end)
      end)

    assert {:error, {:gone, latest}} = Task.await(reader, 10_000)
    assert latest == newest.id
  end

  test "reads over the per-account waiter limit are answered at once", ctx do
    Application.put_env(:good_flows, :project_events_max_waiters_per_account, 1)

    on_exit(fn ->
      Application.delete_env(:good_flows, :project_events_max_waiters_per_account)
    end)

    waiting = Task.async(fn -> read(ctx, %{"wait" => 30}) end)
    wait_for_waiters(ctx.account.id, 1)

    started = System.monotonic_time(:millisecond)
    assert {:ok, %{events: []}} = read(ctx, %{"wait" => 30})
    assert System.monotonic_time(:millisecond) - started < 1_000

    {:ok, _event} = unboxed(fn -> Repo.transaction(fn -> record(ctx.project, 1) end) end)
    assert {:ok, %{events: [_event]}} = Task.await(waiting, 10_000)
  end

  defp wait_for_waiters(account_id, count) do
    if Registry.count_match(ProjectEvents.waiters(), account_id, :_) < count do
      receive after: (10 -> :ok)
      wait_for_waiters(account_id, count)
    end
  end
end
