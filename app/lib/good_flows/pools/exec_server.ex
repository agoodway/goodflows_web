defmodule GoodFlows.Pools.ExecServer do
  @moduledoc """
  Runs one exec on a leased member, on the session coordinator's node,
  under `GoodFlows.Pools.ExecSupervisor`, registered in
  `GoodFlows.Spry.Executions` under the exec row's `owner_id`.

  The command never passes through a shell string built by the server:
  the spawn is `sh -c <fixed prelude> sh <argv…>`, where the prelude
  creates `/tmp/gf-exec-<id>/outputs` (and `reports/` when requested),
  starts a new session with `setsid` whose process group id it records in
  `/tmp/gf-exec-<id>/pgid`, and `exec`s the argv, which is either
  `sh -c <command>` or the client's argv. `cwd` is the spawn `:dir`, and
  the client env (minus `GOODFLOWS_OUTPUT` and `GOODFLOWS_REPORT_DIR`,
  which the server sets) is the spawn `:env`. Stdin is closed.

  Output chunks are stamped with a per-exec `seq` (from 0, SDK arrival
  order across stdout and stderr), kept in a ring buffer of
  `exec_buffer_bytes`, and broadcast on `pool_exec:<id>`. The deadline is
  `min(timeout_ms, exec_max_ms)` of elapsed time.

  **Ending** runs off the server process, so replay and cancel calls stay
  responsive: after a timeout, cancel, stream failure, or coordinator loss
  the remote process group is killed and confirmed gone (bounded by
  `kill_timeout_ms/0`) before anything else; then, on every end,
  `gf-transfer collect` reads the outputs file and the report manifest
  (bounded by `collect_timeout_ms/0`; a failure sets `collect_failed`).
  Then the bounded exit payload is persisted (fenced on `running` and this
  owner) and `exit` is broadcast after the last `output`. Cancels that
  arrive while ending are answered once the exit is persisted. When the
  remote process cannot be confirmed dead, the member is reset
  (`member_lost`), since only the checkpoint restore is sure to end it.

  The server monitors its session coordinator: when the coordinator stops
  for any reason, a running exec ends `error`/`owner_lost` and the server
  stops. Otherwise, after the exec ends the server lingers for the
  disconnect grace so clients can still replay buffered output, then
  stops. The channel is never linked to it, so a socket drop does not
  affect the exec. The credential is held only as a `%Sprites.Client{}`
  and `format_status/1` drops it.
  """
  use GenServer, restart: :temporary

  require Logger

  alias GoodFlows.Pools.{Config, Events, Exec, Execs, Sessions, Transfers}
  alias GoodFlows.Spry.{Executions, Sprites}

  @kill_timeout_ms 10_000
  @collect_timeout_ms 30_000
  @stream_stop_ms 5_000

  @doc "How long the remote kill of a stopped exec may take."
  @spec kill_timeout_ms() :: pos_integer()
  def kill_timeout_ms, do: @kill_timeout_ms

  @doc "How long the post-exit `gf-transfer collect` may take."
  @spec collect_timeout_ms() :: pos_integer()
  def collect_timeout_ms, do: @collect_timeout_ms

  @doc """
  An upper bound on how long a `{:cancel, …}` call can take to answer:
  stopping the local stream, the remote kill, and the collect.
  """
  @spec stop_timeout_ms() :: pos_integer()
  def stop_timeout_ms, do: @stream_stop_ms + @kill_timeout_ms + @collect_timeout_ms + 5_000

  @reserved_env ~w(GOODFLOWS_OUTPUT GOODFLOWS_REPORT_DIR)

  @doc """
  Cancels the exec served by `pid` (local) and waits up to `timeout` for
  its exit to be persisted. `opts`: `reset: false` keeps the server from
  resetting the member itself when the remote process cannot be confirmed
  dead (a member release resets it anyway). Returns `:ok`, or
  `{:error, :gone}` when the server is gone or did not answer in time.
  """
  @spec cancel(pid(), String.t(), String.t() | nil, keyword(), timeout()) :: :ok | {:error, :gone}
  def cancel(pid, status, error_reason, opts, timeout) do
    GenServer.call(pid, {:cancel, status, error_reason, opts}, timeout)
  catch
    :exit, _reason -> {:error, :gone}
  end

  @doc false
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc """
  The shell prelude, paths, and remote kill script for exec `exec_id`.
  `kill` kills the exec's process group and exits 0 once no process of it
  is left (or none was ever recorded), 1 when it is still alive after
  about 5 s. Without `setsid` the recorded id is the exec's own process,
  which is killed and checked instead.
  """
  @spec layout(Ecto.UUID.t(), boolean()) :: %{
          dir: String.t(),
          outputs: String.t(),
          reports: String.t() | nil,
          prelude: String.t(),
          kill: String.t()
        }
  def layout(exec_id, collect_reports?) do
    dir = "/tmp/gf-exec-#{exec_id}"
    outputs = "#{dir}/outputs"
    pgid = "#{dir}/pgid"
    reports = if collect_reports?, do: "#{dir}/reports"

    prelude =
      "umask 077 && mkdir -p '#{dir}' && : > '#{outputs}'" <>
        if(reports, do: " && mkdir -p '#{reports}'", else: "") <>
        " && if command -v setsid >/dev/null 2>&1; then" <>
        ~s{ exec setsid -w sh -c 'echo $$ > "$0" && exec "$@"' '#{pgid}' "$@";} <>
        ~s{ else echo $$ > '#{pgid}' && exec "$@"; fi}

    kill =
      ~s{f='#{pgid}'; [ -r "$f" ] || exit 0; g=$(cat "$f"); [ -n "$g" ] || exit 0; } <>
        ~s{kill -KILL -- "-$g" 2>/dev/null; kill -KILL "$g" 2>/dev/null; i=0; } <>
        ~s{while kill -0 -- "-$g" 2>/dev/null || kill -0 "$g" 2>/dev/null; do } <>
        "i=$((i+1)); [ $i -ge 50 ] && exit 1; sleep 0.1; done; exit 0"

    %{dir: dir, outputs: outputs, reports: reports, prelude: prelude, kill: kill}
  end

  @impl GenServer
  def init(%{
        exec: exec,
        member_name: member_name,
        owner_id: owner_id,
        client: client,
        request: request,
        coordinator: coordinator
      }) do
    :ok = Executions.register(owner_id)
    coordinator_ref = Process.monitor(coordinator)
    layout = layout(exec.id, request.collect_reports)

    env =
      request.env
      |> Enum.reject(fn {name, _value} -> name in @reserved_env end)
      |> Kernel.++([{"GOODFLOWS_OUTPUT", layout.outputs}])
      |> Kernel.++(if layout.reports, do: [{"GOODFLOWS_REPORT_DIR", layout.reports}], else: [])

    {:ok, stream} =
      Sprites.spawn_streaming(
        client,
        member_name,
        "sh",
        ["-c", layout.prelude, "sh" | request.argv],
        self(),
        env: env,
        dir: request.cwd,
        timeout: request.timeout_ms + 5_000
      )

    timer = Process.send_after(self(), :exec_timeout, request.timeout_ms)

    {:ok,
     %{
       exec: exec,
       owner_id: owner_id,
       member_name: member_name,
       client: client,
       layout: layout,
       stream: stream,
       timer: timer,
       coordinator_ref: coordinator_ref,
       started: System.monotonic_time(:millisecond),
       seq: 0,
       buffer: :queue.new(),
       buffer_bytes: 0,
       evicted_through: -1,
       bytes: %{stdout: 0, stderr: 0},
       ending: nil,
       final: nil
     }}
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.update(:state, nil, fn
      %{client: _} = state -> %{state | client: :redacted}
      other -> other
    end)
    |> redact_message()
  end

  @doc false
  # Shared with the coordinator: a crash while handling an exec request
  # logs the last message, whose argv and env must not appear.
  @spec redact_message(map()) :: map()
  def redact_message(%{message: {:"$gen_call", from, {:start_exec, _request}}} = status),
    do: %{status | message: {:"$gen_call", from, {:start_exec, :redacted}}}

  def redact_message(%{message: {:start_exec, _request}} = status),
    do: %{status | message: {:start_exec, :redacted}}

  # A workspace upload chunk (up to 1 MiB of the client's files).
  def redact_message(%{message: {:"$gen_call", from, {:upload_chunk, ref, _data}}} = status),
    do: %{status | message: {:"$gen_call", from, {:upload_chunk, ref, :redacted}}}

  # Exec output.
  def redact_message(%{message: {:sprites_stream, ref, {stream, _data}}} = status)
      when stream in [:stdout, :stderr],
      do: %{status | message: {:sprites_stream, ref, {stream, :redacted}}}

  def redact_message(status), do: status

  @impl GenServer
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}

  def handle_call({:cancel, status, error_reason}, from, state),
    do: handle_call({:cancel, status, error_reason, []}, from, state)

  def handle_call({:cancel, status, error_reason, opts}, from, %{final: nil, ending: nil} = state) do
    stop_stream(state)
    attrs = %{status: status, error_reason: error_reason}

    {:noreply,
     start_ending(state, attrs,
       kill: true,
       waiters: [from],
       reset: Keyword.get(opts, :reset, true)
     )}
  end

  def handle_call({:cancel, _status, _reason, opts}, from, %{final: nil, ending: ending} = state) do
    ending = %{
      ending
      | waiters: [from | ending.waiters],
        reset: ending.reset and Keyword.get(opts, :reset, true)
    }

    {:noreply, %{state | ending: ending}}
  end

  def handle_call({:cancel, _status, _reason, _opts}, _from, state), do: {:reply, :ok, state}

  def handle_call({:replay, after_seq}, _from, state) do
    events =
      state.buffer
      |> :queue.to_list()
      |> Enum.filter(&(&1.seq > after_seq))

    {:reply,
     {:ok,
      %{
        events: events,
        evicted_through: state.evicted_through,
        high_seq: state.seq - 1,
        exit: state.final
      }}, state}
  end

  @impl GenServer
  def handle_info(
        {:sprites_stream, ref, event},
        %{stream: %{ref: ref}, final: nil, ending: nil} = state
      ) do
    case event do
      {stream, data} when stream in [:stdout, :stderr] ->
        {:noreply, output(state, stream, data)}

      {:exit, code} ->
        {:noreply, start_ending(state, %{status: "exited", exit_code: code}, kill: false)}

      {:error, :timeout} ->
        {:noreply, start_ending(state, %{status: "timed_out"}, kill: true)}

      {:error, _error} ->
        {:noreply,
         start_ending(state, %{status: "error", error_reason: "exec_failed"}, kill: true)}
    end
  end

  def handle_info(:exec_timeout, %{final: nil, ending: nil} = state) do
    stop_stream(state)
    {:noreply, start_ending(state, %{status: "timed_out"}, kill: true)}
  end

  # The coordinator is gone: nothing may keep running on its credential.
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{coordinator_ref: ref, final: nil, ending: nil} = state
      ) do
    stop_stream(state)

    attrs = %{status: "error", error_reason: "owner_lost"}
    {:noreply, start_ending(state, attrs, kill: true, stop_after: true)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{coordinator_ref: ref} = state) do
    if state.final,
      do: {:stop, :normal, state},
      else: {:noreply, %{state | ending: %{state.ending | stop_after: true}}}
  end

  def handle_info({ref, result}, %{ending: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    ended(state, result)
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{ending: %{task: %Task{ref: ref}}} = state
      ),
      do: ended(state, %{collected: %{collect_failed: true}, killed: false})

  def handle_info(:linger_over, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp stop_stream(state), do: Sprites.stop_stream(state.stream)

  # Kills (when the exec may still run remotely) and collects in a task.
  defp start_ending(state, attrs, opts) do
    Process.cancel_timer(state.timer)
    %{client: client, member_name: name, layout: layout} = state
    kill? = Keyword.fetch!(opts, :kill)

    task = Task.async(fn -> end_remotely(client, name, layout, kill?) end)

    ending = %{
      task: task,
      attrs: attrs,
      waiters: Keyword.get(opts, :waiters, []),
      stop_after: Keyword.get(opts, :stop_after, false),
      reset: Keyword.get(opts, :reset, true)
    }

    %{state | ending: ending}
  end

  # Runs in the ending task; never raises, so the linked server survives.
  defp end_remotely(client, name, layout, kill?) do
    killed = if kill?, do: remote_kill(client, name, layout), else: true
    %{collected: collect(client, name, layout), killed: killed}
  rescue
    _error -> %{collected: %{collect_failed: true}, killed: not kill?}
  end

  defp remote_kill(client, name, layout) do
    case Sprites.exec(client, name, layout.kill, timeout: @kill_timeout_ms, output_limit: 1_000) do
      {:ok, %{exit_code: 0}} -> true
      _not_confirmed -> false
    end
  end

  defp ended(state, %{collected: collected, killed: killed}) do
    %{attrs: attrs, waiters: waiters, stop_after: stop_after, reset: reset?} = state.ending
    state = finish(%{state | ending: nil}, Map.merge(collected, attrs))
    Enum.each(waiters, &GenServer.reply(&1, :ok))

    # A releasing coordinator (reset: false) resets the member itself.
    if not killed and reset?, do: reset_member(state)

    if stop_after, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  # The remote process may still run: only the member's checkpoint restore
  # is sure to end it, so the member is reset and replaced.
  defp reset_member(%{exec: exec}) do
    if exec.member_id do
      Sessions.member_lost(
        exec.member_id,
        exec.session_id,
        exec.lease_generation,
        :reset,
        "exec could not be stopped"
      )
    end
  rescue
    error -> Logger.warning("Pools: member reset after exec failed: #{Exception.message(error)}")
  end

  defp output(state, stream, data) do
    event = %{seq: state.seq, stream: Atom.to_string(stream), data: data}

    Events.exec_event(state.exec.id, "output", %{
      exec_id: state.exec.id,
      seq: event.seq,
      stream: event.stream,
      data: Base.encode64(data)
    })

    {buffer, bytes, evicted} =
      evict(
        :queue.in(event, state.buffer),
        state.buffer_bytes + byte_size(data),
        state.evicted_through
      )

    %{
      state
      | seq: state.seq + 1,
        buffer: buffer,
        buffer_bytes: bytes,
        evicted_through: evicted,
        bytes: Map.update!(state.bytes, stream, &(&1 + byte_size(data)))
    }
  end

  defp evict(buffer, bytes, evicted) do
    if bytes > Config.exec_buffer_bytes() do
      {{:value, oldest}, rest} = :queue.out(buffer)
      evict(rest, bytes - byte_size(oldest.data), oldest.seq)
    else
      {buffer, bytes, evicted}
    end
  end

  defp collect(client, name, layout) do
    argv =
      [Transfers.helper_path(), "collect", "--outputs", layout.outputs] ++
        if(layout.reports,
          do: [
            "--report-dir",
            layout.reports,
            "--max-reports",
            to_string(Config.report_max_files())
          ],
          else: []
        ) ++
        [
          "--max-outputs",
          to_string(Config.outputs_max_bytes()),
          "--max-report-bytes",
          to_string(Config.report_max_bytes())
        ]

    case Sprites.collect(client, name, argv, timeout: @collect_timeout_ms) do
      {:ok, collected} ->
        %{
          outputs: collected.outputs,
          outputs_truncated: collected.outputs_truncated,
          reports:
            if(layout.reports,
              do: %{
                "files" => sanitize_reports(collected.reports),
                "skipped" => Map.get(collected, :reports_skipped, 0)
              }
            ),
          reports_truncated: collected.reports_truncated
        }

      {:error, _reason} ->
        %{collect_failed: true}
    end
  end

  defp sanitize_reports(reports) do
    for %{"name" => name, "size" => size} = report <- reports,
        is_binary(name) and is_integer(size),
        do: %{"name" => name, "size" => size, "too_large" => report["too_large"] == true}
  end

  defp finish(state, attrs) do
    attrs =
      Map.merge(attrs, %{
        duration_ms: System.monotonic_time(:millisecond) - state.started,
        final_output_seq: state.seq - 1,
        bytes_stdout: state.bytes.stdout,
        bytes_stderr: state.bytes.stderr
      })

    final =
      case Execs.finalize(state.exec.id, state.owner_id, attrs) do
        {:ok, exec} ->
          payload = Exec.exit_event(exec)
          Events.exec_event(exec.id, "exit", payload)
          payload

        :stale ->
          case GoodFlows.Repo.get(Exec, state.exec.id) do
            %Exec{} = exec -> Exec.exit_event(exec)
            nil -> %{exec_id: state.exec.id, status: "error"}
          end
      end

    Process.send_after(self(), :linger_over, Config.disconnect_grace_ms())
    %{state | final: final}
  end
end
