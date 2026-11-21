defmodule GoodFlows.MergeLeases.ExpirySchedulerTest do
  use ExUnit.Case, async: true

  alias GoodFlows.MergeLeases.ExpiryScheduler
  alias GoodFlows.Spry.ReaperScheduler

  test "only the leader enqueues expiry" do
    test_pid = self()
    leader_name = {__MODULE__, make_ref()}

    pids =
      for id <- [:a, :b], into: %{} do
        pid =
          start_supervised!(
            {ExpiryScheduler,
             name: :"expiry_#{id}_#{System.unique_integer([:positive])}",
             interval_ms: 10,
             leader_name: leader_name,
             enqueue: fn -> send(test_pid, {:enqueued, id}) end},
            id: id
          )

        {id, pid}
      end

    assert_receive {:enqueued, leader}, 1_000
    for _ <- 1..3, do: assert_receive({:enqueued, ^leader}, 1_000)
    follower = if leader == :a, do: :b, else: :a
    assert ReaperScheduler.leader?(pids[leader])
    refute ReaperScheduler.leader?(pids[follower])
    refute_received {:enqueued, ^follower}
  end

  test "it has its own leader name, ticks at least every 60 seconds and starts with PgFlow" do
    pid =
      start_supervised!(
        {ExpiryScheduler,
         name: :"expiry_#{System.unique_integer([:positive])}", enqueue: fn -> :ok end}
      )

    state = :sys.get_state(pid)
    assert state.leader_name == ExpiryScheduler.Leader
    assert state.leader_name != ReaperScheduler.Leader
    assert state.interval_ms <= 60_000

    assert ExpiryScheduler in GoodFlows.Application.pgflow_children(repo: GoodFlows.Repo)
  end
end
