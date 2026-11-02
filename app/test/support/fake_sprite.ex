defmodule GoodFlows.FakeSprite do
  @moduledoc """
  Runs what GoodFlows would run inside a Sprite on this machine instead,
  through Mimic stubs of the Sprites SDK (`Sprites.spawn/4`,
  `Sprites.write/2`, `Sprites.close_stdin/1`).

  Each sprite name gets its own directory under `root`; in-Sprite paths
  (`/workspace`, the helper's state dir, `/tmp/gf-exec-…`, and the helper
  binary) are mapped into it, and the real `gf-transfer` binary built from
  `sprite-transfer/` stands in for the installed helper. Other commands
  (such as an exec's `sh`) run from `PATH` with the same mapping applied to
  their arguments, environment values, and directory. Stdout reaches the
  owner as SDK `{:stdout, …}` messages; stderr is discarded, as the
  protocol decoder must never see it.

  Options for `stub!/2`:

    * `:interrupt_after_writes` - `{n, invocations}`: the first
      `invocations` helper processes are killed after `n` stdin writes,
      simulating a dropped exec connection
    * `:missing_helper` - helper invocations exit 127 (`true`, or a list of
      sprite names)
    * `:delay_ms` - helper invocations start this much later
    * `:cut_after_writes` - `{n, invocations}`: the first `invocations`
      helper processes receive `n` writes and run to completion, but the
      connection drops before any later stdout reaches GoodFlows (a lost
      completion reply)
  """

  import ExUnit.Assertions

  alias GoodFlows.Pools.Transfers

  # The debug build first: `mix check` builds it (see the `check` alias), so a
  # leftover release build can never shadow a fresh one.
  @helper_candidates [
    "../sprite-transfer/target/debug/gf-transfer",
    "../sprite-transfer/target/release/gf-transfer",
    "priv/gf-transfer/x86_64-unknown-linux-musl/gf-transfer"
  ]

  @doc "The local `gf-transfer` binary, or nil when none is built."
  def helper_binary do
    @helper_candidates
    |> Enum.map(&Path.expand(&1, File.cwd!()))
    |> Enum.find(&File.regular?/1)
  end

  @doc "A fresh root directory, removed when the test exits."
  def root! do
    root = Path.join(System.tmp_dir!(), "fake-sprite-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  @doc "The local directory that stands for `path` inside sprite `name`."
  def path(root, name, path) do
    helper = Transfers.helper_path()

    cond do
      path == helper -> helper_binary()
      not String.starts_with?(path, "/") -> System.find_executable(path)
      true -> Path.join([root, name, String.trim_leading(path, "/")])
    end
  end

  @doc "Installs the SDK stubs (call with `Mimic` set to global mode)."
  def stub!(root, opts \\ []) do
    counter = :counters.new(1, [])
    helper = Transfers.helper_path()

    Mimic.stub(Sprites, :spawn, fn %Sprites.Sprite{name: name}, command, args, spawn_opts ->
      fake_spawn({root, opts, counter, helper}, name, command, args, spawn_opts)
    end)

    Mimic.stub(Sprites, :write, fn %Sprites.Command{pid: pid}, data ->
      send(pid, {:write, IO.iodata_to_binary(data)})
      :ok
    end)

    Mimic.stub(Sprites, :close_stdin, fn %Sprites.Command{pid: pid} ->
      send(pid, :close_stdin)
      :ok
    end)

    :ok
  end

  defp fake_spawn({root, opts, counter, helper}, name, command, args, spawn_opts) do
    for dir <- ["workspace", "tmp", "var/tmp"], do: File.mkdir_p!(Path.join([root, name, dir]))
    ref = make_ref()
    owner = self()
    helper? = command == helper

    interrupt = interrupt_after(helper?, opts[:interrupt_after_writes], name, counter)
    cut = cut_after(helper?, opts[:cut_after_writes], counter)

    missing? =
      helper? and (opts[:missing_helper] == true or name in List.wrap(opts[:missing_helper]))

    delay = opts[:delay_ms]
    if delay && helper?, do: Process.sleep(delay)

    pid =
      spawn(fn ->
        start_command(
          missing?,
          {root, name, command, args, spawn_opts},
          owner,
          ref,
          {interrupt, cut}
        )
      end)

    {:ok, %Sprites.Command{ref: ref, pid: pid, owner: owner}}
  end

  defp interrupt_after(false, _setting, _name, _counter), do: nil
  defp interrupt_after(true, {_n, _invocations, only}, name, _counter) when only != name, do: nil

  defp interrupt_after(true, {n, invocations, _name}, _name2, counter),
    do: count_in(counter, n, invocations)

  defp interrupt_after(true, {n, invocations}, _name, counter),
    do: count_in(counter, n, invocations)

  defp interrupt_after(true, _setting, _name, _counter), do: nil

  defp cut_after(true, {n, invocations}, counter), do: count_in(counter, n, invocations)
  defp cut_after(_helper?, _setting, _counter), do: nil

  # Counts a helper invocation; `n` while within the first `invocations`, else nil.
  defp count_in(counter, n, invocations) do
    :counters.add(counter, 1, 1)
    if :counters.get(counter, 1) <= invocations, do: n
  end

  defp start_command(true, _command, owner, ref, _faults),
    do: send(owner, {:exit, %{ref: ref}, 127})

  defp start_command(false, {root, name, command, args, spawn_opts}, owner, ref, faults),
    do: run(root, name, command, args, spawn_opts, owner, ref, faults)

  defp run(root, name, command, args, spawn_opts, owner, ref, {interrupt, cut}) do
    executable = path(root, name, command)
    assert executable, "no local gf-transfer binary; run cargo build in sprite-transfer/"
    args = Enum.map(args, &map_arg(root, name, &1))
    dir = spawn_opts[:dir] && path(root, name, spawn_opts[:dir])
    if dir, do: File.mkdir_p!(dir)

    env =
      for {key, value} <- Keyword.get(spawn_opts, :env, []),
          do: {String.to_charlist(key), String.to_charlist(map_arg(root, name, value))}

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: ["-c", ~s(exec "$0" "$@" 2>/dev/null), executable | args],
        cd: dir || Path.join(root, name),
        env: env
      ])

    loop(port, owner, ref, interrupt, cut)
  end

  # Maps every in-Sprite absolute path inside an argument (including shell
  # preludes) into the sprite's directory.
  defp map_arg(root, name, arg) do
    base = Path.join(root, name)

    Regex.replace(
      ~r{(?<![\w/])/(workspace|tmp|var/tmp|usr/local/lib/goodflows)(?=/|'|"|\s|$)},
      arg,
      fn
        _whole, "usr/local/lib/goodflows" -> Path.dirname(helper_binary())
        _whole, dir -> Path.join(base, dir)
      end
    )
  end

  defp loop(port, owner, ref, interrupt, cut) do
    receive do
      {^port, {:data, data}} ->
        send(owner, {:stdout, %{ref: ref}, data})
        loop(port, owner, ref, interrupt, cut)

      {^port, {:exit_status, status}} ->
        send(owner, {:exit, %{ref: ref}, status})

      {:write, _data} when interrupt == 0 ->
        Port.close(port)
        send(owner, {:error, %{ref: ref}, :closed})

      {:write, data} when cut == 1 ->
        Port.command(port, data)
        drain_until_exit(port)
        send(owner, {:error, %{ref: ref}, :closed})

      {:write, data} ->
        Port.command(port, data)
        loop(port, owner, ref, interrupt && interrupt - 1, cut && cut - 1)

      # Erlang ports cannot half-close: EOF closes the whole port, and the
      # helper (which exits on EOF) is reported as exited.
      :close_stdin ->
        Port.close(port)
        send(owner, {:exit, %{ref: ref}, 0})
    end
  end

  # The helper finishes its work; nothing it writes reaches GoodFlows.
  defp drain_until_exit(port) do
    receive do
      {^port, {:data, _data}} -> drain_until_exit(port)
      {^port, {:exit_status, _status}} -> :ok
    after
      10_000 -> Port.close(port)
    end
  end
end
