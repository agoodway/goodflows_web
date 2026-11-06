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

  SDK errors are reduced to `%{status: integer | nil, message: String.t()}`
  with the token scrubbed. Only `{:error, {:not_found, _}}` from
  `Sprites.get_sprite/2` means a sprite is absent.
  """

  alias GoodFlows.Spry.{Config, Executions}

  @task_supervisor GoodFlows.Spry.TaskSupervisor
  @kill_confirm_ms 5_000
  @max_message_length 1_000

  @type client :: Sprites.Client.t()
  @type error :: %{status: integer() | nil, message: String.t()}
  @type exec_result :: %{exit_code: integer(), output: String.t(), output_truncated: boolean()}

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
