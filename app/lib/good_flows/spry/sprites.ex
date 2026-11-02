defmodule GoodFlows.Spry.Sprites do
  @moduledoc """
  The only module that talks to the Sprites SDK.

  Each VM action (`exists?/3`, `create/3`, `exec/4`, `destroy/3`) runs in a
  supervised task with a wall-clock deadline (`:timeout`, default the
  configured step timeout) that output activity cannot extend. On expiry the
  task and any SDK command process are killed and their termination is
  confirmed before `{:error, :timeout}` is returned. A guard process also
  kills them if the calling worker dies first.

  Killing the local command process closes its connection, but the SDK does
  not guarantee that an already-issued remote shell command stops.

  Pools add bounded checkpoint calls (`create_checkpoint/3`,
  `restore_checkpoint/4`), a size-checked `write_file/5` used only to
  bootstrap the transfer helper, `collect/4` for the helper's one-frame
  outputs/report manifest, and two non-blocking streams:
  `spawn_streaming/6` (execs) and `transfer/5` (helper protocol over
  stdin/stdout). A stream returns `{:ok, handle}` at once and forwards
  `{:sprites_stream, ref, event}` messages to its owner, where `event` is
  `{:stdout, data}`, `{:stderr, data}`, `{:exit, code}`, or
  `{:error, :timeout | error}`. Stdout and stderr stay separate. The owner
  enforces its own deadline and stops a stream with `stop_stream/1`; the
  stream also kills itself at its `:timeout` and when its owner dies.

  SDK errors are reduced to `%{status: integer | nil, message: String.t()}`
  with the token scrubbed. Only `{:error, {:not_found, _}}` from
  `Sprites.get_sprite/2` means a sprite is absent.
  """

  alias GoodFlows.Pools.TransferProtocol
  alias GoodFlows.Spry.{Config, Executions}

  @task_supervisor GoodFlows.Spry.TaskSupervisor
  @kill_confirm_ms 5_000
  @max_message_length 1_000

  @type client :: Sprites.Client.t()
  @type error :: %{status: integer() | nil, message: String.t()}
  @type exec_result :: %{exit_code: integer(), output: String.t(), output_truncated: boolean()}

  @typedoc "A running stream started by `spawn_streaming/6` or `transfer/5`."
  @type stream :: %{ref: reference(), pid: pid()}

  @typedoc "The decoded result of `gf-transfer collect`."
  @type collected :: %{
          outputs: binary() | nil,
          outputs_truncated: boolean(),
          reports: [map()],
          reports_truncated: boolean(),
          reports_skipped: non_neg_integer()
        }

  @bootstrap_max_bytes 16_777_216
  @stdin_frame_bytes 65_536
  @collect_max_bytes 4 + 8_192 + 65_537

  @doc "Builds an SDK client for `token`, honoring the configured base URL."
  @spec client(String.t()) :: client()
  def client(token) when is_binary(token) do
    case Config.sprites_base_url() do
      nil -> Sprites.new(token)
      base_url -> Sprites.new(token, base_url: base_url)
    end
  end

  @doc "Reports whether the sprite exists."
  @spec exists?(client(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, :timeout | error()}
  def exists?(client, name, opts \\ []) do
    bounded(client, opts, fn ->
      case Sprites.get_sprite(client, name) do
        {:ok, _info} -> {:ok, true}
        {:error, {:not_found, _body}} -> {:ok, false}
        {:error, reason} -> {:error, normalize(reason, client)}
      end
    end)
  end

  @doc "Creates the sprite with SDK defaults."
  @spec create(client(), String.t(), keyword()) :: :ok | {:error, :timeout | error()}
  def create(client, name, opts \\ []) do
    bounded(client, opts, fn ->
      case Sprites.create(client, name) do
        {:ok, _sprite} -> :ok
        {:error, reason} -> {:error, normalize(reason, client)}
      end
    end)
  end

  @doc "Destroys the sprite."
  @spec destroy(client(), String.t(), keyword()) :: :ok | {:error, :timeout | error()}
  def destroy(client, name, opts \\ []) do
    bounded(client, opts, fn ->
      case Sprites.destroy(Sprites.sprite(client, name)) do
        :ok -> :ok
        {:error, reason} -> {:error, normalize(reason, client)}
      end
    end)
  end

  @doc """
  Runs `line` inside the sprite with `bash -c`, stderr merged into stdout.

  Returns the exit code and the output tail (`:output_limit`, default the
  configured limit) with `output_truncated` set when bytes were dropped.
  """
  @spec exec(client(), String.t(), String.t(), keyword()) ::
          {:ok, exec_result()} | {:error, :timeout | error()}
  def exec(client, name, line, opts \\ []) do
    limit = Keyword.get(opts, :output_limit, Config.output_limit_bytes())
    caller = self()

    bounded(client, opts, fn ->
      sprite = Sprites.sprite(client, name)

      case Sprites.spawn(sprite, "bash", ["-c", line], stderr_to_stdout: true) do
        {:ok, command} ->
          announce_command(caller, command.pid)
          monitor = Process.monitor(command.pid)
          collect(command.ref, monitor, "", false, limit, client)

        {:error, reason} ->
          {:error, normalize(reason, client)}
      end
    end)
  end

  ## Checkpoints

  @doc """
  Creates a checkpoint and returns its id.

  The SDK makes one blocking request and returns every NDJSON message only
  once the response ends, so the `:timeout` kill is the only deadline; a
  timed-out create has an unknown remote outcome. Any `type: "error"`
  message fails the call. The id is resolved by listing the sprite's
  checkpoints and matching `opts[:comment]`, which must be unique.
  """
  @spec create_checkpoint(client(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :timeout | error()}
  def create_checkpoint(client, name, opts) do
    comment = Keyword.fetch!(opts, :comment)

    bounded(client, opts, fn ->
      with {:ok, messages} <- Sprites.Checkpoint.create_by_name(client, name, comment: comment),
           :ok <- stream_errors(messages, client),
           {:ok, checkpoints} <- Sprites.list_checkpoints(Sprites.sprite(client, name)) do
        checkpoint_id(checkpoints, comment)
      else
        {:error, reason} -> {:error, reduce(reason, client)}
      end
    end)
  end

  defp checkpoint_id(checkpoints, comment) do
    case Enum.filter(checkpoints, &(&1.comment == comment)) do
      [%{id: id}] when is_binary(id) ->
        {:ok, id}

      [] ->
        {:error, %{status: nil, message: "the new checkpoint was not found"}}

      _several ->
        {:error, %{status: nil, message: "the checkpoint comment matched several checkpoints"}}
    end
  end

  @doc """
  Restores the sprite to `checkpoint_id`, which also ends every process in
  it. Fails on any `type: "error"` message. A timeout has an unknown remote
  outcome.
  """
  @spec restore_checkpoint(client(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :timeout | error()}
  def restore_checkpoint(client, name, checkpoint_id, opts \\ []) do
    bounded(client, opts, fn ->
      case Sprites.Checkpoint.restore_by_name(client, name, checkpoint_id) do
        {:ok, messages} -> stream_errors(messages, client)
        {:error, reason} -> {:error, normalize(reason, client)}
      end
    end)
  end

  defp stream_errors(messages, client) do
    case Enum.find(messages, &match?(%{type: "error"}, &1)) do
      nil ->
        :ok

      %{error: error} ->
        {:error, %{status: nil, message: scrub(error || "checkpoint error", client)}}
    end
  end

  ## Files

  @doc """
  Writes `data` to `path` in the sprite with `mode` (default `0o755`) in one
  filesystem API request. Only for bootstrapping the transfer helper:
  `data` must be at most #{@bootstrap_max_bytes} bytes (the API's write
  limit), otherwise `{:error, :too_large}` without any request.
  """
  @spec write_file(client(), String.t(), String.t(), binary(), keyword()) ::
          :ok | {:error, :too_large | :timeout | error()}
  def write_file(client, name, path, data, opts \\ []) when is_binary(data) do
    if byte_size(data) > @bootstrap_max_bytes do
      {:error, :too_large}
    else
      mode = Keyword.get(opts, :mode, 0o755)
      bounded(client, opts, fn -> write_sprite_file(client, name, path, data, mode) end)
    end
  end

  defp write_sprite_file(client, name, path, data, mode) do
    fs = Sprites.filesystem(Sprites.sprite(client, name))

    case Sprites.Filesystem.write(fs, path, data, mode: mode) do
      :ok -> :ok
      {:error, reason} -> {:error, normalize(reason, client)}
    end
  end

  ## Helper collect

  @doc """
  Runs `argv` (a `gf-transfer collect` invocation) and decodes its single
  bounded `collect` frame: at most 65,537 outputs bytes and the report
  manifest. Never uses `exec/4`, whose text tail would corrupt binary
  outputs. Stdout beyond one frame, a non-zero exit, or a malformed frame
  is an error.
  """
  @spec collect(client(), String.t(), [String.t()], keyword()) ::
          {:ok, collected()} | {:error, :timeout | error()}
  def collect(client, name, [command | args], opts \\ []) do
    caller = self()

    bounded(client, opts, fn ->
      sprite = Sprites.sprite(client, name)

      case Sprites.spawn(sprite, command, args, tty: false) do
        {:ok, command} ->
          announce_command(caller, command.pid)
          monitor = Process.monitor(command.pid)
          collect_frame(command.ref, monitor, "", "", client)

        {:error, reason} ->
          {:error, normalize(reason, client)}
      end
    end)
  end

  defp collect_frame(ref, monitor, out, err, client) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        out = out <> data

        if byte_size(out) > @collect_max_bytes,
          do: {:error, %{status: nil, message: "collect output exceeded its limit"}},
          else: collect_frame(ref, monitor, out, err, client)

      {:stderr, %{ref: ^ref}, data} ->
        collect_frame(ref, monitor, out, binary_part_tail(err <> data, 1_000), client)

      {:exit, %{ref: ^ref}, 0} ->
        Process.demonitor(monitor, [:flush])
        decode_collect(out)

      {:exit, %{ref: ^ref}, code} ->
        Process.demonitor(monitor, [:flush])
        message = "gf-transfer collect exited with #{code}: #{String.replace_invalid(err)}"
        {:error, %{status: nil, message: scrub(message, client)}}

      {:error, %{ref: ^ref}, reason} ->
        Process.demonitor(monitor, [:flush])
        {:error, normalize(reason, client)}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, %{status: nil, message: "command ended without reporting an exit code"}}
    end
  end

  defp binary_part_tail(binary, max) when byte_size(binary) > max,
    do: binary_part(binary, byte_size(binary) - max, max)

  defp binary_part_tail(binary, _max), do: binary

  # Report files whose names the helper cannot send (absent when none).
  defp skipped(count) when is_integer(count) and count > 0, do: count
  defp skipped(_count), do: 0

  defp decode_collect(out) do
    case TransferProtocol.decode(out, max_payload: 65_537) do
      {:ok, [%{header: %{"type" => "collect"} = header, payload: payload}], ""} ->
        {:ok,
         %{
           outputs: if(header["outputs_present"] == true and payload != "", do: payload),
           outputs_truncated: header["outputs_truncated"] == true,
           reports: List.wrap(header["reports"]),
           reports_truncated: header["reports_truncated"] == true,
           reports_skipped: skipped(header["reports_skipped"])
         }}

      _other ->
        {:error, %{status: nil, message: "gf-transfer collect returned a malformed frame"}}
    end
  end

  ## Streams

  @doc """
  Starts `command args` in the sprite without waiting for it and forwards
  `{:sprites_stream, ref, event}` messages to `owner` (see the moduledoc).
  Options: `:env` (list of `{name, value}`), `:dir`, and `:timeout` (hard
  deadline in ms, default the step timeout). Stdin is closed. Exec output
  is forwarded without a cap: the exec server keeps a bounded ring buffer
  and the exec has a hard deadline.
  """
  @spec spawn_streaming(client(), String.t(), String.t(), [String.t()], pid(), keyword()) ::
          {:ok, stream()}
  def spawn_streaming(client, name, command, args, owner, opts \\ []) do
    start_stream(client, name, command, args, owner, Keyword.put(opts, :stdin, false))
  end

  @doc """
  Starts a `gf-transfer` invocation (`argv`) for a duplex protocol
  conversation: stdin open (`stdin: true`) and no TTY (`tty: false`), so
  stdout carries raw protocol bytes and stderr stays separate (only for
  scrubbed diagnostics, never fed to the protocol decoder). Write with
  `write_stream/3` and send EOF with `close_stream_stdin/2`. Events go to
  `owner` like `spawn_streaming/6`. Options as `spawn_streaming/6`, plus
  `:stdout_limit` (total stdout bytes; beyond it the command is killed and
  `{:error, …}` is forwarded) and `:stderr_limit` (stderr bytes forwarded;
  the rest is dropped), so a misbehaving helper cannot flood the owner's
  mailbox.
  """
  @spec transfer(client(), String.t(), [String.t()], pid(), keyword()) :: {:ok, stream()}
  def transfer(client, name, [command | args], owner, opts \\ []) do
    start_stream(client, name, command, args, owner, Keyword.put(opts, :stdin, true))
  end

  @doc """
  Queues `data` on the stream's stdin, split into WebSocket frames of at
  most #{@stdin_frame_bytes} bytes. `:ok` means queued, not delivered:
  backpressure comes from the protocol's acknowledgements.
  """
  @spec write_stream(stream(), iodata(), timeout()) ::
          :ok | {:error, :closed | :timeout | error()}
  def write_stream(%{pid: pid}, data, timeout \\ 5_000) do
    reply = make_ref()
    monitor = Process.monitor(pid)
    send(pid, {:stream_write, self(), reply, IO.iodata_to_binary(data)})

    receive do
      {^reply, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :closed}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  @doc """
  Sends EOF on the stream's stdin and waits (up to `timeout`) until the SDK
  has been asked to close it, so a `stop_stream/1` right after cannot drop
  the EOF. `{:error, :closed}` when the stream already ended.
  """
  @spec close_stream_stdin(stream(), timeout()) :: :ok | {:error, :closed | :timeout}
  def close_stream_stdin(%{pid: pid}, timeout \\ 5_000) do
    reply = make_ref()
    monitor = Process.monitor(pid)
    send(pid, {:stream_close_stdin, self(), reply})

    receive do
      {^reply, :ok} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :closed}
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  @doc """
  Stops a stream: kills its task (whose guard kills the SDK command
  process) and waits up to 5 seconds. Returns whether the task is
  confirmed dead. As with `exec/4`, the remote process may outlive the
  connection; a member reset ends it.
  """
  @spec stop_stream(stream()) :: boolean()
  def stop_stream(%{pid: pid}) do
    result = Executions.kill_and_confirm([pid], @kill_confirm_ms)
    Executions.untrack(pid)
    result
  end

  defp start_stream(client, name, command, args, owner, opts) do
    ref = make_ref()
    timeout = Keyword.get(opts, :timeout, Config.step_timeout_ms())

    spawn_opts =
      [stdin: Keyword.fetch!(opts, :stdin), tty: false]
      |> put_present(:env, Keyword.get(opts, :env))
      |> put_present(:dir, Keyword.get(opts, :dir))

    spawn = fn -> Sprites.spawn(Sprites.sprite(client, name), command, args, spawn_opts) end

    limits = %{
      stdout: Keyword.get(opts, :stdout_limit),
      stderr: Keyword.get(opts, :stderr_limit)
    }

    {:ok, pid} =
      Task.Supervisor.start_child(@task_supervisor, fn ->
        run_stream(client, spawn, owner, ref, timeout, limits)
      end)

    Executions.track(pid)
    {:ok, %{ref: ref, pid: pid}}
  end

  # Runs in the stream task: spawns the command and forwards its events.
  defp run_stream(client, spawn, owner, ref, timeout, limits) do
    guard = start_guard(owner, self())
    Process.put(:spry_guard, guard)
    deadline = Process.send_after(self(), :stream_deadline, max(timeout, 0))
    notify = &send(owner, {:sprites_stream, ref, &1})

    case safely(spawn, client) do
      {:ok, %Sprites.Command{} = cmd} ->
        send(guard, {:spry_command, cmd.pid})
        budget = %{limits: limits, stdout: 0, stderr: 0}
        stream_loop(cmd, Process.monitor(cmd.pid), notify, client, budget)

      {:error, reason} ->
        notify.({:error, reduce(reason, client)})
    end

    Process.cancel_timer(deadline)
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  defp stream_loop(%{ref: ref} = cmd, monitor, notify, client, budget) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        budget = %{budget | stdout: budget.stdout + byte_size(data)}

        if over?(budget.limits.stdout, budget.stdout) do
          Process.exit(cmd.pid, :kill)
          notify.({:error, %{status: nil, message: "stdout exceeded its byte budget"}})
        else
          notify.({:stdout, data})
          stream_loop(cmd, monitor, notify, client, budget)
        end

      {:stderr, %{ref: ^ref}, data} ->
        stream_loop(cmd, monitor, notify, client, forward_stderr(budget, data, notify))

      {:exit, %{ref: ^ref}, code} ->
        notify.({:exit, code})

      {:error, %{ref: ^ref}, reason} ->
        notify.({:error, normalize(reason, client)})

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        notify.({:error, %{status: nil, message: "command ended without reporting an exit code"}})

      {:stream_write, from, reply, data} ->
        send(from, {reply, write_frames(cmd, data, client)})
        stream_loop(cmd, monitor, notify, client, budget)

      {:stream_close_stdin, from, reply} ->
        _ = safely(fn -> Sprites.close_stdin(cmd) end, client)
        send(from, {reply, :ok})
        stream_loop(cmd, monitor, notify, client, budget)

      :stream_deadline ->
        Process.exit(cmd.pid, :kill)
        notify.({:error, :timeout})
    end
  end

  defp over?(nil, _bytes), do: false
  defp over?(limit, bytes), do: bytes > limit

  # Stderr beyond its limit is dropped (diagnostics only), never forwarded.
  defp forward_stderr(%{limits: %{stderr: limit}, stderr: seen} = budget, data, notify) do
    room = if limit, do: max(limit - seen, 0), else: byte_size(data)

    if room > 0, do: notify.({:stderr, binary_part(data, 0, min(room, byte_size(data)))})

    %{budget | stderr: seen + byte_size(data)}
  end

  defp write_frames(_cmd, <<>>, _client), do: :ok

  defp write_frames(cmd, data, client) do
    size = min(byte_size(data), @stdin_frame_bytes)
    <<frame::binary-size(size), rest::binary>> = data

    case safely(fn -> Sprites.write(cmd, frame) end, client) do
      :ok -> write_frames(cmd, rest, client)
      {:error, reason} -> {:error, reduce(reason, client)}
    end
  end

  ## Bounded execution

  defp bounded(client, opts, fun) do
    timeout = Keyword.get(opts, :timeout, Config.step_timeout_ms())
    caller = self()
    reply = make_ref()

    {:ok, pid} =
      Task.Supervisor.start_child(@task_supervisor, fn ->
        guard = start_guard(caller, self())
        Process.put(:spry_guard, guard)
        send(caller, {reply, safely(fun, client)})
      end)

    monitor = Process.monitor(pid)
    Executions.track(pid)
    deadline = System.monotonic_time(:millisecond) + max(timeout, 0)
    await(%{pid: pid, monitor: monitor, reply: reply}, deadline, [])
  end

  defp safely(fun, client) do
    fun.()
  rescue
    error -> {:error, normalize(error, client)}
  catch
    :exit, reason -> {:error, normalize({:exit, reason}, client)}
  end

  defp await(%{pid: pid, monitor: monitor, reply: reply} = action, deadline, commands) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^reply, result} ->
        Process.demonitor(monitor, [:flush])
        Enum.each([pid | commands], &Executions.untrack/1)
        result

      {:spry_command, ^pid, command_pid} ->
        Executions.track(command_pid)
        await(action, deadline, [command_pid | commands])

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        Enum.each([pid | commands], &Executions.untrack/1)
        {:error, %{status: nil, message: "Sprites action process exited unexpectedly"}}
    after
      remaining ->
        Executions.kill_and_confirm([pid | commands], @kill_confirm_ms)
        Process.demonitor(monitor, [:flush])
        flush_commands(pid)
        flush_reply(reply)
        Enum.each([pid | commands], &Executions.untrack/1)
        {:error, :timeout}
    end
  end

  defp flush_reply(reply) do
    receive do
      {^reply, _late_result} -> :ok
    after
      0 -> :ok
    end
  end

  defp flush_commands(task_pid) do
    receive do
      {:spry_command, ^task_pid, command_pid} ->
        Executions.kill_and_confirm([command_pid], @kill_confirm_ms)
        flush_commands(task_pid)
    after
      0 -> :ok
    end
  end

  defp announce_command(caller, command_pid) do
    send(caller, {:spry_command, self(), command_pid})

    case Process.get(:spry_guard) do
      guard when is_pid(guard) -> send(guard, {:spry_command, command_pid})
      _ -> :ok
    end
  end

  # Kills the action task and its command processes if the caller dies before
  # the task finishes; exits once the task ends.
  defp start_guard(caller, task) do
    spawn(fn ->
      caller_ref = Process.monitor(caller)
      task_ref = Process.monitor(task)
      guard_loop(caller_ref, task_ref, task, [])
    end)
  end

  defp guard_loop(caller_ref, task_ref, task, commands) do
    receive do
      {:spry_command, command_pid} ->
        guard_loop(caller_ref, task_ref, task, [command_pid | commands])

      {:DOWN, ^caller_ref, :process, _pid, _reason} ->
        Executions.kill_and_confirm([task | commands], @kill_confirm_ms)

      {:DOWN, ^task_ref, :process, _pid, _reason} ->
        Enum.each(commands, &Process.exit(&1, :kill))
    end
  end

  ## Output collection

  defp collect(ref, monitor, acc, truncated?, limit, client) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        {acc, truncated?} = append(acc, data, truncated?, limit)
        collect(ref, monitor, acc, truncated?, limit, client)

      {:stderr, %{ref: ^ref}, data} ->
        {acc, truncated?} = append(acc, data, truncated?, limit)
        collect(ref, monitor, acc, truncated?, limit, client)

      {:exit, %{ref: ^ref}, code} ->
        Process.demonitor(monitor, [:flush])
        {output, truncated?} = finish_output(acc, truncated?, limit)
        {:ok, %{exit_code: code, output: output, output_truncated: truncated?}}

      {:error, %{ref: ^ref}, reason} ->
        Process.demonitor(monitor, [:flush])
        {:error, normalize(reason, client)}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, %{status: nil, message: "command ended without reporting an exit code"}}
    end
  end

  # Keeps memory bounded: once the buffer exceeds twice the limit, keep only
  # the last `limit` bytes.
  defp append(acc, data, truncated?, limit) do
    acc = acc <> data

    if byte_size(acc) > 2 * limit,
      do: {binary_part(acc, byte_size(acc) - limit, limit), true},
      else: {acc, truncated?}
  end

  @doc """
  Returns the last `limit` bytes of `output` as valid UTF-8 text without NUL
  bytes, and whether anything was dropped.
  """
  @spec tail(binary(), pos_integer()) :: {String.t(), boolean()}
  def tail(output, limit), do: finish_output(output, false, limit)

  defp finish_output(acc, truncated?, limit) do
    {acc, truncated?} =
      if byte_size(acc) > limit,
        do: {binary_part(acc, byte_size(acc) - limit, limit), true},
        else: {acc, truncated?}

    acc = if truncated?, do: drop_continuation_bytes(acc, 3), else: acc

    text =
      acc
      |> String.replace_invalid()
      |> String.replace(<<0>>, "")

    {text, truncated?}
  end

  defp drop_continuation_bytes(<<0b10::2, _::6, rest::binary>>, n) when n > 0,
    do: drop_continuation_bytes(rest, n - 1)

  defp drop_continuation_bytes(binary, _n), do: binary

  @doc """
  A displayable message for an error returned by this module: the reduced
  `message`, else the HTTP status, else a generic text. Unknown shapes are
  never inspected, so nothing from SDK state can leak through.
  """
  @spec error_message(term()) :: String.t()
  def error_message(%{message: message}) when is_binary(message) and message != "", do: message

  def error_message(%{status: status}) when is_integer(status),
    do: "Sprites API returned #{status}"

  def error_message(_error), do: "Sprites request failed"

  ## Error normalization

  # An error this module already reduced (a plain map) passes through;
  # anything else, including SDK error structs, is normalized.
  defp reduce(%{status: _, message: _} = error, _client) when not is_struct(error), do: error
  defp reduce(reason, client), do: normalize(reason, client)

  defp normalize(reason, client) do
    {status, message} = describe(reason)
    %{status: status, message: scrub(message, client)}
  end

  defp describe({:api_error, status, body}), do: {status, body_message(body, status)}
  defp describe({:not_found, body}), do: {404, body_message(body, 404)}

  defp describe(%Sprites.Error.APIError{status: status, message: message}),
    do: {status, message || "Sprites API error"}

  defp describe(%Sprites.Error.TimeoutError{}), do: {nil, "Sprites command timed out"}
  defp describe(%{__exception__: true} = error), do: {nil, Exception.message(error)}
  defp describe({:exit, reason}), do: {nil, "Sprites action exited: #{inspect(reason)}"}
  defp describe({:upgrade_failed, status}), do: {status, "command connection was rejected"}
  defp describe(:closed_before_exit), do: {nil, "connection closed before the command exited"}
  defp describe(reason), do: {nil, "Sprites request failed: #{inspect(reason)}"}

  defp body_message(%{} = body, status) do
    Enum.find_value(["error", "message", "detail"], "Sprites API returned #{status}", fn key ->
      case Map.get(body, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp body_message(body, _status) when is_binary(body) and body != "", do: body
  defp body_message(_body, status), do: "Sprites API returned #{status}"

  defp scrub(message, client) do
    message = to_string(message)

    message =
      case client do
        %{token: token} when is_binary(token) and token != "" ->
          String.replace(message, token, "[REDACTED]")

        _ ->
          message
      end

    String.slice(message, 0, @max_message_length)
  end
end
