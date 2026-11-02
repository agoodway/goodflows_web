defmodule GoodFlows.Pools.Transfers do
  @moduledoc """
  Resumable workspace and report transfers between this node and a leased
  member, through the member's `gf-transfer` helper (protocol v1, see
  `GoodFlows.Pools.TransferProtocol` and `sprite-transfer/README.md`).

  Both functions run on the session coordinator's node, inside the caller
  (a coordinator task holding a `GoodFlows.Pools.TransferSemaphore`
  permit). Every SDK interaction goes through `GoodFlows.Spry.Sprites`
  (`transfer/5`, `write_stream/3`, `stop_stream/1`); no whole-archive
  filesystem write or whole-body read is ever made.

    * `receive_workspace/4` streams the session's immutable spooled archive
      to `gf-transfer receive` in chunks of at most the negotiated payload
      (one in flight, each acknowledged after the helper's durable commit),
      then `finish`, and waits for `complete{extracted: true}`. An
      interrupted attempt is retried with a new invocation under the same
      transfer id (`ws-<session>-<member>-g<lease generation>`), which
      resumes at the helper's committed offset.
    * `fetch_report/5` asks `gf-transfer send` for an immutable snapshot of
      one report, receives chunks into a disk spool (committing data, then
      the progress file, before each ack), verifies the whole-file SHA-256,
      and publishes `<name>` in the spool. Retries resume from the spool's
      committed offset against the same snapshot.

  Attempts are bounded by `transfer_attempts` with exponential backoff and
  by the caller's absolute `deadline` (unix ms; the session's expiry),
  which is also the helper's `--deadline-unix-ms` and the stream's hard
  timeout; no attempt starts once it has passed. Each wait for a frame is
  bounded by `transfer_ack_timeout_ms`, except the first frame of an
  attempt, which may wait `helper_idle_timeout_ms` longer: a replacement
  helper may wait that long for the previous invocation's lock before it
  answers (or reports `busy`, which is retried). Every attempt ends by
  sending EOF on stdin and waiting briefly for the helper to exit before
  the stream is stopped, so a helper whose connection is closed releases
  its lock instead of holding it until its idle timeout. Every frame must
  carry the attempt's `transfer_id`, and a download whose spooled progress
  was bound to another snapshot length or hash fails with
  `metadata_mismatch` (its progress is discarded, so the next request
  restarts). Terminal helper errors
  (`restart_required`, `archive_rejected`, `archive_too_large`,
  `disk_full`, `extract_failed`, `too_large`, `source_rejected`,
  `metadata_mismatch`) are not retried. A helper that is missing (exit 126
  or 127) or speaks another protocol version is `:helper_missing`.
  """

  alias GoodFlows.Pools.{Config, Exec, Member, TransferProtocol}
  alias GoodFlows.Spry.Sprites

  @helper_path "/usr/local/lib/goodflows/gf-transfer"
  @state_dir "/var/tmp/gf-transfer"
  @exit_wait_ms 2_000
  # Helper stdout per upload attempt: control frames only.
  @control_stdout_limit 4 * 1_048_576
  @stderr_limit 65_536
  @terminal ~w(restart_required archive_rejected archive_too_large disk_full extract_failed
               too_large source_rejected metadata_mismatch protocol bad_offset)

  @doc "Where provisioning installs the helper inside each member."
  @spec helper_path() :: String.t()
  def helper_path, do: @helper_path

  @doc "The helper's private state directory inside each member (outside `/workspace`)."
  @spec state_dir() :: String.t()
  def state_dir, do: @state_dir

  @doc """
  Delivers the spooled workspace to `member` for its current lease and
  waits for verified extraction. Returns `:ok`, `{:error, :helper_missing}`,
  or `{:error, reason}` (a string naming the failure).

  Options: `:fence` - a zero-arity function checked before every attempt
  (the session coordinator passes "the member is still leased to this
  session under this lease generation"); when it returns false no further
  attempt starts and the result is `{:error, "lease lost"}`, so an orphaned
  retry can never extract an old workspace onto a re-leased member.
  """
  @spec receive_workspace(
          Sprites.client(),
          Member.t(),
          Ecto.UUID.t(),
          map(),
          integer(),
          keyword()
        ) ::
          :ok | {:error, :helper_missing | String.t()}
  def receive_workspace(client, %Member{} = member, session_id, workspace, deadline, opts \\ []) do
    transfer_id = "ws-#{session_id}-#{member.id}-g#{member.lease_generation}"

    open = %{
      type: "open",
      transfer_id: transfer_id,
      direction: "upload",
      session_id: session_id,
      member_id: member.id,
      lease_generation: member.lease_generation,
      artifact: "workspace.tar.gz",
      max_payload: Config.transfer_chunk_bytes(),
      length: workspace.size,
      sha256: Base.encode16(workspace.sha, case: :lower)
    }

    argv = [
      @helper_path,
      "receive",
      "--state-dir",
      @state_dir,
      "--dest",
      "/workspace",
      "--max-bytes",
      to_string(Config.workspace_max_bytes()),
      "--max-expanded-bytes",
      to_string(Config.workspace_max_expanded_bytes()),
      "--max-entries",
      to_string(Config.workspace_max_entries()),
      "--extract-timeout-ms",
      to_string(Config.helper_extract_timeout_ms()),
      "--idle-timeout-ms",
      to_string(Config.helper_idle_timeout_ms()),
      "--deadline-unix-ms",
      to_string(deadline),
      "--max-payload",
      to_string(Config.transfer_chunk_bytes())
    ]

    fence = Keyword.get(opts, :fence, fn -> true end)

    with_attempts(deadline, fn ->
      if fence.(),
        do: upload_attempt(client, member.name, argv, open, workspace.path, deadline),
        else: {:error, "lease lost"}
    end)
  end

  @doc """
  Fetches report `name` of `exec` from `member` into `dir` (the spool),
  resuming any earlier partial. Returns the verified file.
  """
  @spec fetch_report(Sprites.client(), Member.t(), Exec.t(), String.t(), Path.t(), integer()) ::
          {:ok, %{path: Path.t(), size: non_neg_integer(), sha256: String.t()}}
          | {:error, :helper_missing | :transfer_failed | :not_found}
  # `dir` is the session coordinator's spool dir (spool root + session and exec UUIDs);
  # the report name only reaches local paths hashed.
  # sobelow_skip ["Traversal.FileModule"]
  def fetch_report(client, %Member{} = member, %Exec{} = exec, name, dir, deadline) do
    File.mkdir_p!(dir)
    key = name |> TransferProtocol.sha256_hex() |> binary_part(0, 16)
    final = Path.join(dir, key)

    case read_progress(dir, key) do
      %{"done" => true, "length" => length, "sha256" => sha} ->
        {:ok, %{path: final, size: length, sha256: sha}}

      _other ->
        download_report(client, member, exec, name, dir, key, deadline)
    end
  end

  defp download_report(client, member, exec, name, dir, key, deadline) do
    open = %{
      type: "open",
      transfer_id: "rp-#{exec.id}-#{key}",
      direction: "download",
      session_id: exec.session_id,
      member_id: member.id,
      lease_generation: exec.lease_generation,
      artifact: name,
      max_payload: Config.transfer_chunk_bytes()
    }

    argv = [
      @helper_path,
      "send",
      "--state-dir",
      @state_dir,
      "--source",
      "/tmp/gf-exec-#{exec.id}/reports/#{name}",
      "--max-bytes",
      to_string(Config.report_max_bytes()),
      "--idle-timeout-ms",
      to_string(Config.helper_idle_timeout_ms()),
      "--deadline-unix-ms",
      to_string(deadline),
      "--max-payload",
      to_string(Config.transfer_chunk_bytes())
    ]

    attempt = fn -> download_attempt(client, member.name, argv, open, dir, key, deadline) end

    case with_attempts(deadline, attempt) do
      {:ok, result} -> {:ok, result}
      {:error, :helper_missing} -> {:error, :helper_missing}
      {:error, "source_rejected"} -> {:error, :not_found}
      {:error, "too_large"} -> {:error, :not_found}
      {:error, _reason} -> {:error, :transfer_failed}
    end
  end

  ## Attempts

  defp with_attempts(deadline, fun), do: attempt(deadline, fun, 1)

  defp attempt(deadline, fun, n) do
    if remaining_ms(deadline) <= 0 do
      {:error, "session deadline passed"}
    else
      case fun.() do
        {:retry, reason} -> retry(deadline, fun, n, reason)
        result -> result
      end
    end
  end

  defp retry(deadline, fun, n, reason) do
    backoff = Config.transfer_backoff_ms() * Integer.pow(2, n - 1)

    cond do
      n >= Config.transfer_attempts() ->
        {:error, "transfer retries exhausted (#{reason})"}

      remaining_ms(deadline) <= backoff ->
        {:error, "session deadline passed (#{reason})"}

      true ->
        Process.sleep(backoff)
        attempt(deadline, fun, n + 1)
    end
  end

  # A download attempt's stdout: the whole report in chunks of at most the
  # configured size, each with a header of at most 8 KiB, plus control frames.
  defp report_stdout_limit do
    frames = div(Config.report_max_bytes(), Config.transfer_chunk_bytes()) + 8
    Config.report_max_bytes() + frames * (TransferProtocol.max_header() + 4)
  end

  defp remaining_ms(deadline), do: deadline - System.os_time(:millisecond)

  # The first frame of an attempt may come after a replacement helper
  # waited out the previous invocation's lock.
  defp first_frame_timeout,
    do: Config.helper_idle_timeout_ms() + Config.transfer_ack_timeout_ms()

  defp open_stream(client, sprite, argv, deadline, stdout_limit) do
    {:ok, stream} =
      Sprites.transfer(client, sprite, argv, self(),
        timeout: max(remaining_ms(deadline), 0),
        stdout_limit: stdout_limit,
        stderr_limit: @stderr_limit
      )

    %{
      stream: stream,
      decoder: TransferProtocol.decoder(),
      frames: [],
      max_payload: TransferProtocol.default_max_payload()
    }
  end

  # EOF first (synchronously), then a bounded wait for the helper to exit
  # on it, then the stream stops: a helper whose connection closes releases
  # its transfer lock at once.
  defp close_stream(%{stream: stream}) do
    _ = Sprites.close_stream_stdin(stream, @exit_wait_ms)
    await_exit(stream, @exit_wait_ms)
    Sprites.stop_stream(stream)
  end

  # The stream task ends once the helper exits (or the connection fails).
  defp await_exit(%{pid: pid}, timeout) do
    monitor = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      timeout ->
        Process.demonitor(monitor, [:flush])
        :timeout
    end
  end

  # A frame of another transfer (a stale helper's) is never accepted.
  defp same_transfer?(%{"transfer_id" => id}, id), do: true
  defp same_transfer?(_header, _id), do: false

  ## Upload

  defp upload_attempt(client, sprite, argv, open, path, deadline) do
    conn = open_stream(client, sprite, argv, deadline, @control_stdout_limit)

    try do
      with {:ok, conn} <- send_frame(conn, open),
           {:ok, %{"type" => "ready"} = ready, conn} <- await_frame(conn, first_frame_timeout()),
           true <- same_transfer?(ready, open.transfer_id) || {:error, "metadata_mismatch"},
           conn = %{conn | max_payload: negotiated(ready)},
           {:ok, conn} <- send_chunks(conn, path, open, ready),
           {:ok, conn} <-
             send_frame(conn, %{
               type: "finish",
               transfer_id: open.transfer_id,
               length: open.length,
               sha256: open.sha256
             }),
           {:ok, %{"type" => "complete", "extracted" => true} = complete, _conn} <-
             await_frame(conn, extract_timeout()),
           true <- same_transfer?(complete, open.transfer_id) || {:error, "metadata_mismatch"} do
        :ok
      else
        other -> classify(other)
      end
    after
      close_stream(conn)
    end
  end

  defp extract_timeout,
    do: Config.helper_extract_timeout_ms() + Config.transfer_ack_timeout_ms()

  defp negotiated(%{"max_payload" => max}) when is_integer(max) and max > 0,
    do: min(max, Config.transfer_chunk_bytes())

  defp negotiated(_ready), do: Config.transfer_chunk_bytes()

  defp send_chunks(conn, _path, _open, %{"completed" => true}), do: {:ok, conn}

  # `path` is the session's uploaded workspace in the node spool, named by the server.
  # sobelow_skip ["Traversal.FileModule"]
  defp send_chunks(conn, path, open, %{"committed_offset" => offset}) when is_integer(offset) do
    {:ok, file} = File.open(path, [:read, :binary, :raw])

    try do
      chunk_loop(conn, file, open, offset)
    after
      File.close(file)
    end
  end

  defp send_chunks(_conn, _path, _open, _ready), do: {:retry, "malformed ready"}

  defp chunk_loop(conn, _file, %{length: length}, offset) when offset >= length, do: {:ok, conn}

  defp chunk_loop(conn, file, open, offset) do
    size = min(conn.max_payload, open.length - offset)
    {:ok, data} = :file.pread(file, offset, size)

    frame = %{
      type: "chunk",
      transfer_id: open.transfer_id,
      offset: offset,
      sha256: TransferProtocol.sha256_hex(data)
    }

    with {:ok, conn} <- send_frame(conn, frame, data),
         {:ok, %{"type" => "ack", "committed_offset" => committed} = ack, conn} <-
           await_frame(conn),
         true <- same_transfer?(ack, open.transfer_id) || {:error, "metadata_mismatch"} do
      if committed == offset + size,
        do: chunk_loop(conn, file, open, committed),
        else: {:retry, "unexpected acknowledgement"}
    end
  end

  ## Download

  defp download_attempt(client, sprite, argv, open, dir, key, deadline) do
    conn = open_stream(client, sprite, argv, deadline, report_stdout_limit())

    try do
      with {:ok, conn} <- send_frame(conn, open),
           {:ok, %{"type" => "ready", "length" => length, "sha256" => sha} = offer, conn} <-
             await_frame(conn, first_frame_timeout()),
           true <- same_transfer?(offer, open.transfer_id) || {:error, "metadata_mismatch"},
           true <-
             (is_integer(length) and length <= Config.report_max_bytes()) || {:error, "too_large"},
           {:ok, progress} <- resume_progress(dir, key, length, sha),
           max = negotiated(offer),
           {:ok, conn} <-
             send_frame(conn, %{
               type: "ready",
               transfer_id: open.transfer_id,
               committed_offset: progress["committed"],
               max_payload: max
             }),
           {:ok, conn} <-
             receive_chunks(%{conn | max_payload: max}, dir, key, open.transfer_id, progress) do
        finish_download(conn, dir, key, open.transfer_id, length, sha)
      else
        other -> classify(other)
      end
    after
      close_stream(conn)
    end
  end

  defp receive_chunks(
         conn,
         dir,
         key,
         transfer_id,
         %{"committed" => committed, "length" => length} = progress
       )
       when committed < length do
    case await_frame(conn) do
      {:ok,
       %{
         "type" => "chunk",
         "transfer_id" => ^transfer_id,
         "offset" => ^committed,
         "sha256" => sha
       }, payload, conn} ->
        if TransferProtocol.sha256_hex(payload) == sha and
             committed + byte_size(payload) <= length,
           do: accept_chunk(conn, dir, key, transfer_id, progress, payload),
           else: {:retry, "bad chunk"}

      {:ok, %{"type" => "chunk", "transfer_id" => ^transfer_id}, _payload, _conn} ->
        {:retry, "chunk at an unexpected offset"}

      {:ok, %{"type" => "chunk"}, _payload, _conn} ->
        {:error, "metadata_mismatch"}

      other ->
        other
    end
  end

  defp receive_chunks(conn, _dir, _key, _transfer_id, _progress), do: {:ok, conn}

  defp accept_chunk(conn, dir, key, transfer_id, progress, payload) do
    progress = commit(dir, key, progress, payload)

    with {:ok, conn} <-
           send_frame(conn, %{
             type: "ack",
             transfer_id: transfer_id,
             committed_offset: progress["committed"]
           }) do
      receive_chunks(conn, dir, key, transfer_id, progress)
    end
  end

  defp finish_download(conn, dir, key, transfer_id, length, sha) do
    with {:ok, %{"type" => "finish", "transfer_id" => ^transfer_id} = finish, conn} <-
           await_frame(conn),
         true <-
           (finish["length"] == length and finish["sha256"] == sha) ||
             {:error, "metadata_mismatch"} do
      part = Path.join(dir, key <> ".part")

      if Config.file_sha256(part) == sha do
        File.rename!(part, Path.join(dir, key))
        write_progress(dir, key, %{"done" => true, "length" => length, "sha256" => sha})

        _ =
          send_frame(conn, %{
            type: "complete",
            transfer_id: transfer_id,
            length: length,
            sha256: sha
          })

        {:ok, %{path: Path.join(dir, key), size: length, sha256: sha}}
      else
        clear_progress(dir, key)
        {:retry, "restart_required"}
      end
    end
  end

  # The spool's progress for this snapshot, or a fresh one. Progress bound
  # to another length or hash is refused (`metadata_mismatch`, terminal)
  # and discarded, so the next request restarts from 0.
  # `dir` is the spool dir (spool root + session and exec UUIDs) and `key` a sha256 prefix.
  # sobelow_skip ["Traversal.FileModule"]
  defp resume_progress(dir, key, length, sha) do
    case read_progress(dir, key) do
      %{"length" => ^length, "sha256" => ^sha, "committed" => committed} = progress
      when is_integer(committed) ->
        truncate(Path.join(dir, key <> ".part"), committed)
        {:ok, progress}

      %{"length" => _, "sha256" => _} ->
        clear_progress(dir, key)
        {:error, "metadata_mismatch"}

      _none ->
        clear_progress(dir, key)
        File.write!(Path.join(dir, key <> ".part"), "")

        progress = %{"length" => length, "sha256" => sha, "committed" => 0}
        write_progress(dir, key, progress)
        {:ok, progress}
    end
  end

  # Data first (synced), then the progress file (atomically replaced).
  defp commit(dir, key, progress, payload) do
    part = Path.join(dir, key <> ".part")
    {:ok, file} = :file.open(part, [:read, :write, :binary, :raw])

    try do
      :ok = :file.pwrite(file, progress["committed"], payload)
      :ok = :file.datasync(file)
    after
      :file.close(file)
    end

    progress = %{progress | "committed" => progress["committed"] + byte_size(payload)}
    write_progress(dir, key, progress)
    progress
  end

  defp truncate(path, size) do
    {:ok, file} = :file.open(path, [:read, :write, :binary, :raw])

    try do
      {:ok, _} = :file.position(file, size)
      :ok = :file.truncate(file)
    after
      :file.close(file)
    end
  end

  # `dir` is the spool dir (spool root + session and exec UUIDs) and `key` a sha256 prefix.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_progress(dir, key) do
    with {:ok, json} <- File.read(Path.join(dir, key <> ".json")),
         {:ok, %{} = progress} <- Jason.decode(json) do
      progress
    else
      _ -> nil
    end
  end

  # `dir` is the spool dir (spool root + session and exec UUIDs) and `key` a sha256 prefix.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_progress(dir, key, progress) do
    tmp = Path.join(dir, key <> ".json.tmp")
    File.write!(tmp, Jason.encode!(progress), [:sync])
    File.rename!(tmp, Path.join(dir, key <> ".json"))
  end

  # `dir` is the spool dir (spool root + session and exec UUIDs) and `key` a sha256 prefix.
  # sobelow_skip ["Traversal.FileModule"]
  defp clear_progress(dir, key) do
    for suffix <- [".json", ".part", ""], do: File.rm(Path.join(dir, key <> suffix))
    :ok
  end

  ## Framing over the stream

  defp send_frame(conn, header, payload \\ "") do
    case TransferProtocol.encode(header, payload, max_payload: conn.max_payload) do
      {:ok, iodata} ->
        case Sprites.write_stream(conn.stream, iodata, Config.transfer_ack_timeout_ms()) do
          :ok -> {:ok, conn}
          {:error, _reason} -> {:retry, "write failed"}
        end

      {:error, reason} ->
        {:error, "encode #{reason}"}
    end
  end

  # Waits for the next complete frame on stdout. Stderr is diagnostics only
  # and never reaches the decoder. Returns {:ok, header, conn} for control
  # frames and {:ok, header, payload, conn} for chunks.
  defp await_frame(conn, timeout \\ Config.transfer_ack_timeout_ms())

  defp await_frame(%{frames: [%{header: header, payload: payload} | rest]} = conn, _timeout) do
    conn = %{conn | frames: rest}

    case header do
      %{"type" => "error", "code" => code} -> {:helper_error, code}
      %{"type" => "chunk"} -> {:ok, header, payload, conn}
      _control -> {:ok, header, conn}
    end
  end

  defp await_frame(conn, timeout), do: receive_more(conn, timeout)

  # The negotiated payload maximum applies from the next frame on.
  defp feed(conn, data) do
    decoder = TransferProtocol.limit(conn.decoder, conn.max_payload)

    case TransferProtocol.feed(decoder, data) do
      {:ok, [], decoder} -> {:more, %{conn | decoder: decoder}}
      {:ok, frames, decoder} -> {:frames, %{conn | frames: frames, decoder: decoder}}
      {:error, reason} -> {:retry, "protocol #{reason}"}
    end
  end

  defp receive_more(%{stream: %{ref: ref}} = conn, timeout) do
    receive do
      {:sprites_stream, ^ref, {:stdout, data}} ->
        case feed(conn, data) do
          {:more, conn} -> receive_more(conn, timeout)
          {:frames, conn} -> await_frame(conn, timeout)
          retry -> retry
        end

      {:sprites_stream, ^ref, {:stderr, _diagnostics}} ->
        receive_more(conn, timeout)

      {:sprites_stream, ^ref, {:exit, code}} when code in [126, 127] ->
        {:error, :helper_missing}

      {:sprites_stream, ^ref, {:exit, code}} ->
        {:retry, "helper exited with #{code}"}

      {:sprites_stream, ^ref, {:error, _error}} ->
        {:retry, "transport error"}
    after
      timeout -> {:retry, "acknowledgement timeout"}
    end
  end

  defp classify({:retry, reason}), do: {:retry, reason}
  defp classify({:error, :helper_missing}), do: {:error, :helper_missing}
  defp classify({:helper_error, "unsupported_version"}), do: {:error, :helper_missing}
  defp classify({:helper_error, code}) when code in @terminal, do: {:error, code}
  defp classify({:helper_error, code}), do: {:retry, code}
  defp classify({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp classify({:ok, %{"type" => type}, _conn}), do: {:retry, "unexpected #{type} frame"}

  defp classify({:ok, %{"type" => type}, _payload, _conn}),
    do: {:retry, "unexpected #{type} frame"}

  defp classify(_other), do: {:retry, "unexpected reply"}
end
