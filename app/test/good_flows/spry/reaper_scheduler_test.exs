defmodule GoodFlows.Spry.ReaperSchedulerTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Spry.ReaperScheduler

  # Each scheduler stands in for one node; they share a :global leader name.
  defp start_scheduler(id, leader_name) do
    test_pid = self()

    start_supervised!(
      {ReaperScheduler,
       name: :"scheduler_#{id}_#{System.unique_integer([:positive])}",
       interval_ms: 10,
       leader_name: leader_name,
       enqueue: fn -> send(test_pid, {:enqueued, id}) end},
      id: id
    )
  end

  defp drain(acc \\ MapSet.new()) do
    receive do
      {:enqueued, id} -> drain(MapSet.put(acc, id))
    after
      0 -> acc
    end
  end

  # Bounded polling: retries `fun` until it returns true, without a fixed sleep.
  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        receive do
        after
          5 -> eventually(fun, attempts - 1)
        end
    end
  end

  test "only one scheduler in the cluster enqueues sweeps, and another takes over" do
    leader_name = {__MODULE__, make_ref()}
    a = start_scheduler(:a, leader_name)
    b = start_scheduler(:b, leader_name)

    assert_receive {:enqueued, leader_id}, 1_000
    {leader, follower} = if leader_id == :a, do: {a, b}, else: {b, a}
    follower_id = if leader_id == :a, do: :b, else: :a

    # Several more leader ticks; the follower ticks on the same interval, so
    # it has had its chances to enqueue by then.
    for _ <- 1..5, do: assert_receive({:enqueued, ^leader_id}, 1_000)
    # Synchronous calls: both schedulers have handled every earlier message.
    assert ReaperScheduler.leader?(leader)
    refute ReaperScheduler.leader?(follower)
    refute MapSet.member?(drain(), follower_id)

    stop_supervised!(leader_id)

    assert_receive {:enqueued, ^follower_id}, 1_000
    assert ReaperScheduler.leader?(follower)
  end

  test "a name conflict notice is ignored and leadership is re-elected" do
    leader_name = {__MODULE__, make_ref()}
    pid = start_scheduler(:solo, leader_name)
    assert_receive {:enqueued, :solo}, 1_000

    :global.unregister_name(leader_name)
    send(pid, {:global_name_conflict, leader_name})

    # The notice is handled without crashing, and the next tick re-claims
    # the name.
    eventually(fn -> ReaperScheduler.leader?(pid) end)
    _ = drain()
    assert_receive {:enqueued, :solo}, 1_000
    assert Process.alive?(pid)
  end
end
