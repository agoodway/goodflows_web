defmodule GoodFlows.Spry.ExecutionsTest do
  use ExUnit.Case, async: true

  alias GoodFlows.Spry.Executions

  defp sleeper, do: spawn(fn -> Process.sleep(:infinity) end)

  # Runs `fun` in a fresh process registered as `owner_id` and returns the
  # process once `fun` has run.
  defp start_execution(owner_id, fun \\ fn -> :ok end) do
    test_pid = self()

    pid =
      spawn(fn ->
        result = Executions.register(owner_id)
        fun.()
        send(test_pid, {:registered, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, ^pid, :ok}
    pid
  end

  describe "owner ids" do
    test "embed this node and boot, and are unique" do
      a = Executions.new_owner_id()
      b = Executions.new_owner_id()
      assert a != b
      assert String.starts_with?(a, Executions.owner_prefix())
      assert Executions.owner_location(a) == {node(), Executions.boot_id()}
      assert Executions.owner_node(a) == node()
      assert Executions.local_owner?(a)
    end

    test "the boot id is stable for the life of the VM" do
      assert Executions.boot_id() == Executions.boot_id()
      assert Executions.boot_id() =~ ~r/\A[0-9a-f]{16}\z/
    end

    test "an id from another boot of this node is not local" do
      owner_id = "#{node()}|other-boot|#{Ecto.UUID.generate()}"
      assert Executions.owner_location(owner_id) == {node(), "other-boot"}
      refute Executions.local_owner?(owner_id)
    end

    test "unparseable ids, unknown nodes, and non-strings have no node" do
      unknown = "never-seen-#{System.unique_integer([:positive])}@nowhere|b|u"

      for owner_id <- [
            nil,
            42,
            "",
            "garbage",
            "|boot|uuid",
            "node@host||uuid",
            "node@host|boot|",
            "node@host|uuid",
            "a|b|c|d",
            unknown
          ] do
        assert Executions.owner_node(owner_id) == nil, "parsed #{inspect(owner_id)}"
        refute Executions.local_owner?(owner_id)
      end

      # Parsing never creates atoms.
      assert_raise ArgumentError, fn ->
        String.to_existing_atom("never-seen-#{System.unique_integer([:positive])}@nowhere")
      end
    end

    test "a known node name is recovered" do
      _ = :known@somewhere
      assert Executions.owner_location("known@somewhere|b00t|u") == {:known@somewhere, "b00t"}
    end
  end

  describe "register/1" do
    test "a second registration of the same owner id is rejected" do
      owner_id = Executions.new_owner_id()
      pid = start_execution(owner_id)

      assert Executions.register(owner_id) == {:error, {:already_registered, pid}}
      assert Executions.lookup(owner_id) == {:ok, pid}
    end

    test "the registration disappears when the execution exits" do
      owner_id = Executions.new_owner_id()
      pid = start_execution(owner_id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      # Registry cleanup is asynchronous to the DOWN; a bounded wait.
      Enum.reduce_while(1..200, nil, fn _, _ ->
        if Executions.lookup(owner_id) == :error,
          do: {:halt, :ok},
          else: receive(after: (5 -> {:cont, nil}))
      end)

      assert Executions.lookup(owner_id) == :error
      assert Executions.stop(owner_id) == :not_running
    end
  end

  describe "track/1 and untrack/1" do
    test "stop/2 kills the execution and its tracked pids, not untracked ones" do
      owner_id = Executions.new_owner_id()
      tracked = sleeper()
      untracked = sleeper()

      pid =
        start_execution(owner_id, fn ->
          :ok = Executions.track(tracked)
          :ok = Executions.track(untracked)
          :ok = Executions.untrack(untracked)
        end)

      assert Executions.stop(owner_id) == :stopped
      refute Process.alive?(pid)
      refute Process.alive?(tracked)
      assert Process.alive?(untracked)
      Process.exit(untracked, :kill)
    end

    test "tracking from an unregistered process is a no-op" do
      assert Executions.track(self()) == :ok
      assert Executions.untrack(self()) == :ok
      assert Executions.stop(Executions.new_owner_id()) == :not_running
    end
  end

  describe "kill_and_confirm/3" do
    test "confirms that killed processes are dead" do
      pids = [sleeper(), sleeper()]
      assert Executions.kill_and_confirm(pids ++ pids, 1_000)
      refute Enum.any?(pids, &Process.alive?/1)
    end

    test "reports false when termination is not confirmed in time" do
      pid = sleeper()
      # A kill that never lands: the process is still alive at the deadline.
      refute Executions.kill_and_confirm([pid], 20, kill: fn _pid -> true end)
      assert Process.alive?(pid)
      Process.exit(pid, :kill)
    end
  end
end
