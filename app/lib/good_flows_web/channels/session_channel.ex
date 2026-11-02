defmodule GoodFlowsWeb.SessionChannel do
  @moduledoc """
  The `pool_session:<id>` channel: the client side of a pool session.

  **Join.** Refused with `not_found` for a session of another account,
  `forbidden` for one created by another key, and `ended` (with
  `end_reason`) for an ended session. The reply carries `status`, the
  granted `members` (`id`, `name`, `ready`), and every running exec
  (`exec_id`, `member_id`, `job`, `step`). Joining refreshes the session's
  `last_seen_at`, as does a heartbeat every `heartbeat_interval_ms` and
  leaving; a heartbeat that finds the creating key revoked ends the session.

  **Events in** (each replies `ok` or `error` with a `reason`):

    * `exec` - start a command (see `GoodFlows.Pools.Execs.validate_request/1`);
      replies `{exec_id}` (always before that exec's first `output` or
      `exit`), or `invalid_request` (with `fields`), `not_granted`,
      `member_not_ready`, `member_busy`, `ended`, `draining`, or
      `unavailable`
    * `cancel` `{exec_id}` - kill a running exec (`cancelled`); an ended one
      is a no-op
    * `resume` `{execs: [{exec_id, last_seq}]}` - replay output after
      `last_seq` (-1 when nothing was received): a `gap` (`exec_id`,
      `from_seq`, `to_seq`) for evicted or unavailable output, then the
      buffered `output` in seq order, then newer live events, then `exit`
      if the exec ended; an exec this channel already tracks is left as is,
      malformed entries and execs of other sessions are ignored, and at
      most #{1_000} entries are accepted (`invalid_request` otherwise)
    * `want` `{wanted}`, `release_member` `{member_id}` (`not_granted`, or
      `unavailable` when the session's coordinator cannot be reached),
      `release`

  **Events out:** `member_granted`, `member_ready`, `member_lost`,
  `session_ended` (`status`, `reason`), and per exec `output` (`exec_id`,
  `seq`, `stream`, base64 `data`), `gap`, and `exit`. Output is deduplicated
  by `seq`; live output that skips seqs, and an `exit` whose
  `final_output_seq` is past the last delivered seq, are preceded by a
  `gap`; no output follows an `exit`. Every tracked exec's `exit`, and that
  of every exec listed in the join reply but not resumed, is pushed before
  `session_ended`.

  The channel is never linked to an exec, so a socket drop does not affect
  it. Joins and incoming events are not logged (`log_join: false`,
  `log_handle_in: false`), so exec commands and env values never reach the
  logs.
  """
  use Phoenix.Channel, log_join: false, log_handle_in: false

  alias GoodFlows.Accounts.Account

  alias GoodFlows.Pools.{
    Config,
    Events,
    Exec,
    Execs,
    Member,
    OwnerRPC,
    Session,
    SessionCoordinator,
    Sessions
  }

  alias GoodFlows.Repo

  @max_resume 1_000

  @impl Phoenix.Channel
  def join("pool_session:" <> id, _params, socket) do
    account = %Account{id: socket.assigns.account_id}

    case Sessions.get_owned(account, socket.assigns.api_key_id, id) do
      {:ok, %Session{} = session} ->
        if Session.ended?(session),
          do:
            {:error, %{reason: "ended", end_reason: session.end_reason, status: session.status}},
          else: join_open(session, socket)

      {:error, :forbidden} ->
        {:error, %{reason: "forbidden"}}

      {:error, :not_found} ->
        {:error, %{reason: "not_found"}}
    end
  end

  defp join_open(session, socket) do
    case Sessions.heartbeat(session.id) do
      :ok ->
        schedule_heartbeat()
        reply = join_reply(session)

        socket =
          assign(socket,
            session_id: session.id,
            owner_id: session.owner_id,
            execs: %{},
            # Running at join but not (yet) resumed: their exit still
            # precedes session_ended.
            join_execs: MapSet.new(reply.execs, & &1.exec_id)
          )

        {:ok, reply, socket}

      {:ended, status, reason} ->
        {:error, %{reason: "ended", end_reason: reason, status: status}}
    end
  end

  defp join_reply(session) do
    session = Repo.reload!(session)

    %{
      status: session.status,
      members:
        for(
          m <- Sessions.members(session.id),
          do: %{id: m.id, name: m.name, ready: Member.ready?(m)}
        ),
      execs:
        for(
          e <- Execs.running(session.id),
          do: %{exec_id: e.id, member_id: e.member_id, job: e.job, step: e.step}
        )
    }
  end

  ## Incoming

  @impl Phoenix.Channel
  def handle_in("exec", payload, socket) do
    with {:ok, request} <- Execs.validate_request(payload) do
      case OwnerRPC.call(socket.assigns.owner_id, {:start_exec, request}) do
        {:ok, exec_id} ->
          # Subscribed before the reply; the reply goes out before any
          # replayed output or exit.
          socket = track(socket, exec_id)
          reply(socket_ref(socket), {:ok, %{exec_id: exec_id}})
          {:noreply, replay(socket, Repo.get!(Exec, exec_id), -1)}

        {:error, reason} when is_binary(reason) ->
          {:reply, {:error, %{reason: reason}}, socket}

        {:error, _unavailable} ->
          {:reply, {:error, %{reason: "unavailable"}}, socket}
      end
    else
      {:error, error} -> {:reply, {:error, error}, socket}
    end
  end

  # Straight to the exec's own server (its owner id is on the row), never
  # through the session coordinator, which stays free for its lease.
  def handle_in("cancel", %{"exec_id" => exec_id}, socket) when is_binary(exec_id) do
    case session_exec(socket, exec_id) do
      {:ok, exec} ->
        _ =
          OwnerRPC.call(
            exec.owner_id,
            {:cancel, "cancelled", nil},
            SessionCoordinator.stop_call_timeout_ms()
          )

        {:reply, :ok, socket}

      :error ->
        {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in("resume", %{"execs" => execs}, socket)
      when is_list(execs) and length(execs) > @max_resume,
      do: {:reply, {:error, %{reason: "invalid_request", fields: ["execs"]}}, socket}

  def handle_in("resume", %{"execs" => execs}, socket) when is_list(execs) do
    socket =
      Enum.reduce(execs, socket, fn
        %{"exec_id" => exec_id, "last_seq" => last_seq}, socket
        when is_binary(exec_id) and is_integer(last_seq) and last_seq >= -1 ->
          case session_exec(socket, exec_id) do
            # Already tracked on this channel: everything was pushed here.
            {:ok, exec} when is_map_key(socket.assigns.execs, exec.id) -> socket
            {:ok, exec} -> socket |> track(exec.id, last_seq) |> replay(exec, last_seq)
            :error -> socket
          end

        _invalid, socket ->
          socket
      end)

    {:reply, :ok, socket}
  end

  def handle_in("want", %{"wanted" => wanted}, socket) do
    case Sessions.set_wanted(current(socket), wanted) do
      :ok ->
        {:reply, :ok, socket}

      {:error, :invalid} ->
        {:reply, {:error, %{reason: "invalid_request", fields: ["wanted"]}}, socket}
    end
  end

  def handle_in("release_member", %{"member_id" => member_id}, socket) do
    case Sessions.release_member(current(socket), member_id) do
      :ok -> {:reply, :ok, socket}
      {:error, :not_granted} -> {:reply, {:error, %{reason: "not_granted"}}, socket}
      {:error, :unavailable} -> {:reply, {:error, %{reason: "unavailable"}}, socket}
    end
  end

  def handle_in("release", _payload, socket) do
    :ok = Sessions.release(current(socket))
    {:reply, :ok, socket}
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "invalid_request", fields: []}}, socket}

  ## Outgoing

  @impl Phoenix.Channel
  def handle_info({:pool_session_event, "session_ended", payload}, socket) do
    socket = flush_exits(socket)
    push(socket, "session_ended", payload)
    {:stop, {:shutdown, :session_ended}, socket}
  end

  def handle_info({:pool_session_event, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:pool_exec_event, "output", %{exec_id: id, seq: seq} = payload}, socket) do
    case Map.fetch(socket.assigns.execs, id) do
      {:ok, %{last_seq: last, exited: false}} when seq > last ->
        socket = if seq > last + 1, do: push_gap(socket, id, last + 1, seq - 1), else: socket
        push(socket, "output", payload)
        {:noreply, put_exec(socket, id, &%{&1 | last_seq: seq})}

      _duplicate_exited_or_untracked ->
        {:noreply, socket}
    end
  end

  def handle_info({:pool_exec_event, "exit", %{exec_id: id} = payload}, socket),
    do: {:noreply, push_exit(socket, id, payload)}

  def handle_info(:heartbeat, socket) do
    case Sessions.heartbeat(socket.assigns.session_id) do
      :ok ->
        schedule_heartbeat()
        {:noreply, socket}

      {:ended, status, reason} ->
        socket = flush_exits(socket)
        push(socket, "session_ended", %{status: status, reason: reason})
        {:stop, {:shutdown, :session_ended}, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.Channel
  def terminate(_reason, socket) do
    if session_id = socket.assigns[:session_id], do: Sessions.heartbeat(session_id)
    :ok
  rescue
    # Best effort: the session may be gone, or the repo stopping.
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  ## Exec tracking

  defp current(socket), do: Repo.get!(Session, socket.assigns.session_id)

  defp session_exec(socket, exec_id) do
    with {:ok, exec_id} <- Ecto.UUID.cast(exec_id),
         %Exec{session_id: session_id} = exec when session_id == socket.assigns.session_id <-
           Repo.get(Exec, exec_id) do
      {:ok, exec}
    else
      _ -> :error
    end
  end

  defp track(socket, exec_id, last_seq \\ -1) do
    unless Map.has_key?(socket.assigns.execs, exec_id),
      do: Events.subscribe(Events.exec_topic(exec_id))

    socket
    |> assign(:join_execs, MapSet.delete(socket.assigns.join_execs, exec_id))
    |> put_exec(exec_id, fn _ -> %{last_seq: last_seq, exited: false} end)
  end

  defp put_exec(socket, id, fun) do
    current = Map.get(socket.assigns.execs, id, %{last_seq: -1, exited: false})
    assign(socket, :execs, Map.put(socket.assigns.execs, id, fun.(current)))
  end

  # Subscribed already (track/3); replays what the exec's server still
  # buffers (asked directly by the exec's owner id). Live events that
  # arrive meanwhile wait in the mailbox and are then deduplicated by seq.
  defp replay(socket, %Exec{id: exec_id, owner_id: owner_id}, last_seq) do
    case OwnerRPC.call(owner_id, {:replay, last_seq}) do
      {:ok, %{events: events, evicted_through: evicted, high_seq: high, exit: final}} ->
        socket =
          if evicted > last_seq,
            do: push_gap(socket, exec_id, last_seq + 1, evicted),
            else: socket

        socket =
          Enum.reduce(events, socket, fn event, socket ->
            handle_output(socket, exec_id, event)
          end)

        socket = put_exec(socket, exec_id, &%{&1 | last_seq: max(&1.last_seq, high)})
        if final, do: push_exit(socket, exec_id, final), else: socket

      _gone ->
        replay_persisted(socket, exec_id, last_seq)
    end
  end

  defp handle_output(socket, exec_id, %{seq: seq, stream: stream, data: data}) do
    %{last_seq: last} = Map.fetch!(socket.assigns.execs, exec_id)

    if seq > last do
      push(socket, "output", %{
        exec_id: exec_id,
        seq: seq,
        stream: stream,
        data: Base.encode64(data)
      })

      put_exec(socket, exec_id, &%{&1 | last_seq: seq})
    else
      socket
    end
  end

  # The ExecServer is gone: output is unavailable, so a gap covers
  # everything after last_seq through the persisted final seq, then exit.
  defp replay_persisted(socket, exec_id, last_seq) do
    case Repo.get(Exec, exec_id) do
      %Exec{status: status} = exec when status != "running" ->
        socket =
          if exec.final_output_seq > last_seq,
            do: push_gap(socket, exec_id, last_seq + 1, exec.final_output_seq),
            else: socket

        push_exit(socket, exec_id, Exec.exit_event(exec))

      _running_or_missing ->
        # Still running but its server is unreachable: the live `exit`
        # (subscribed already) closes any gap through its final seq.
        socket
    end
  end

  defp push_gap(socket, exec_id, from, to) do
    push(socket, "gap", %{exec_id: exec_id, from_seq: from, to_seq: to})
    put_exec(socket, exec_id, &%{&1 | last_seq: max(&1.last_seq, to)})
  end

  # `payload` is an internal exit event (`Exec.exit_event/1`): output
  # after the last seq this client received through `final_output_seq` is
  # announced as a gap first, and `final_output_seq` is not pushed.
  defp push_exit(socket, exec_id, payload) do
    {final_seq, payload} = Map.pop(payload, :final_output_seq)

    case Map.fetch(socket.assigns.execs, exec_id) do
      {:ok, %{exited: false, last_seq: last}} ->
        socket =
          if is_integer(final_seq) and final_seq > last,
            do: push_gap(socket, exec_id, last + 1, final_seq),
            else: socket

        push(socket, "exit", payload)
        put_exec(socket, exec_id, &%{&1 | exited: true})

      _already_or_untracked ->
        socket
    end
  end

  # Before session_ended: every tracked exec that has not pushed its exit
  # pushes the persisted one (ending a session finalizes its execs first).
  # Execs listed in the join reply that the client has not resumed push
  # their persisted exit too (without gap accounting: this channel never
  # carried their output).
  defp flush_exits(socket) do
    socket =
      Enum.reduce(socket.assigns[:execs] || %{}, socket, fn
        {exec_id, %{exited: false}}, socket ->
          case Repo.get(Exec, exec_id) do
            %Exec{status: status} = exec when status != "running" ->
              push_exit(socket, exec_id, Exec.exit_event(exec))

            _running ->
              socket
          end

        _exited, socket ->
          socket
      end)

    for exec_id <- socket.assigns[:join_execs] || MapSet.new(),
        %Exec{status: status} = exec when status != "running" <- [Repo.get(Exec, exec_id)],
        do: push(socket, "exit", Exec.exit_payload(exec))

    assign(socket, :join_execs, MapSet.new())
  end

  defp schedule_heartbeat,
    do: Process.send_after(self(), :heartbeat, Config.heartbeat_interval_ms())
end
