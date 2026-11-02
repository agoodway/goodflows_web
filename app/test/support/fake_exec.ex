defmodule GoodFlows.FakeExec do
  @moduledoc """
  Scripted stand-ins for `GoodFlows.Spry.Sprites.spawn_streaming/6`,
  `stop_stream/1`, `collect/4`, and `exec/4` (the remote kill, announced to
  the test process as `{:remote_kill, name, line}`) (Mimic stubs).

  Every started exec announces `{:exec_started, pid, info}` to the test
  process (`info` has the sprite `name`, `command`, `args`, and spawn
  `opts`); the test then drives it with `emit/2` (`{:stdout, data}`,
  `{:stderr, data}`, `{:exit, code}`, `{:error, reason}`).
  """

  alias GoodFlows.Spry.Sprites, as: Wrapper

  @empty %{outputs: nil, outputs_truncated: false, reports: [], reports_truncated: false}

  @doc "Installs the stubs. `collect` maps the collect argv to its result."
  def stub!(test_pid, collect \\ fn _argv -> {:ok, @empty} end) do
    Mimic.stub(Wrapper, :spawn_streaming, fn _client, name, command, args, owner, opts ->
      ref = make_ref()
      pid = spawn(fn -> loop(owner, ref) end)

      send(
        test_pid,
        {:exec_started, pid, %{name: name, command: command, args: args, opts: opts}}
      )

      {:ok, %{ref: ref, pid: pid}}
    end)

    Mimic.stub(Wrapper, :stop_stream, fn %{pid: pid} ->
      Process.exit(pid, :kill)
      true
    end)

    Mimic.stub(Wrapper, :collect, fn _client, _name, argv, _opts -> collect.(argv) end)

    # The remote process-group kill after a cancel or timeout.
    Mimic.stub(Wrapper, :exec, fn _client, name, line, _opts ->
      send(test_pid, {:remote_kill, name, line})
      {:ok, %{exit_code: 0, output: "", output_truncated: false}}
    end)

    :ok
  end

  @doc "Makes the fake command deliver `event` to its exec server."
  def emit(pid, event), do: send(pid, {:emit, event})

  defp loop(owner, ref) do
    receive do
      {:emit, event} ->
        send(owner, {:sprites_stream, ref, event})
        loop(owner, ref)
    end
  end
end
