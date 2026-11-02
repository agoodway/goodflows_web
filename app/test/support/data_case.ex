defmodule GoodFlows.DataCase do
  @moduledoc """
  Test case template for tests that touch the data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use GoodFlows.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias GoodFlows.Pools.ShutdownDrain

  using do
    quote do
      alias GoodFlows.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import GoodFlows.DataCase
    end
  end

  setup tags do
    GoodFlows.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(GoodFlows.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # Pool session coordinators and exec servers outlive the test process;
    # stop them (before the sandbox owner) so they never touch the next
    # test's data. Only shared-mode tests can have started any. Channel
    # processes stop on their own when the test process exits, but their
    # `terminate/2` may still be querying the repo, so wait for them first.
    unless tags[:async] do
      on_exit(fn ->
        await_channel_processes()
        stop_pool_processes()
      end)
    end
  end

  # Waits (bounded) for every Phoenix channel process on this node to exit.
  # Phoenix labels channel servers `{Phoenix.Channel, channel, topic}`.
  defp await_channel_processes do
    refs =
      for pid <- Process.list(),
          match?({Phoenix.Channel, _, _}, :proc_lib.get_label(pid)),
          do: Process.monitor(pid)

    deadline = System.monotonic_time(:millisecond) + 5_000

    Enum.each(refs, fn ref ->
      timeout = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        timeout -> Process.demonitor(ref, [:flush])
      end
    end)
  end

  @doc "Stops every pool session coordinator and exec server on this node."
  def stop_pool_processes do
    for sup <- [GoodFlows.Pools.CoordinatorSupervisor, GoodFlows.Pools.ExecSupervisor],
        {_, pid, _, _} <- DynamicSupervisor.which_children(sup),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(sup, pid)
    end

    ShutdownDrain.reset()
    :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
