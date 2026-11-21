defmodule GoodFlows.MergeLeases.ExpirySchedulerTest do
  use ExUnit.Case, async: true

  alias GoodFlows.MergeLeases.ExpiryScheduler
  alias GoodFlows.Spry.ReaperScheduler

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
