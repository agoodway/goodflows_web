defmodule GoodFlows.Pools.SessionCoordinator do
  @moduledoc """
  The per-session owner process, supervised on the node that created the
  session and registered in `GoodFlows.Spry.Executions` under the session's
  `owner_id`.

  It alone holds the session's captured Sprites credential, as a
  `%Sprites.Client{}` (so `GoodFlows.Spry.Redaction` recognizes it), and
  `format_status/1` drops it from crash reports. Every resource-dependent
  operation runs here, reached through `GoodFlows.Pools.OwnerRPC`:

    * workspace upload: admission (node spool budget, the account's byte
      share, and its concurrent upload cap), chunk writes to
      `workspace.tar.gz` in the session spool, archive preflight
      (`GoodFlows.Pools.Archive`), and recording the upload; a finished
      upload keeps only its actual size reserved
    * hydration: each granted member (including later grants) receives the
      spooled workspace through `GoodFlows.Pools.Transfers` under the node
      transfer semaphore, one member at a time per session (writes per
      session are sequential); readiness is recorded only for the lease
      generation captured when hydration started, and every attempt first
      checks that lease is still current
    * execs: admission and `GoodFlows.Pools.ExecServer` processes on this
      node (an exec's `replay` and `cancel` go straight to its ExecServer)
    * report retrieval: one shared transfer per report into the spool
      (reserving the report cap from the spool budget first), served to
      callers on any node
    * ending: cancelling execs before the session's members are released

  **Responsiveness.** Anything that waits on a member (hydration, report
  transfers, archive preflight, and the exec cancels of `release_member`
  and `end_session`) runs in a linked, monitored task under
  `GoodFlows.Spry.TaskSupervisor`, so the coordinator keeps renewing its
  lease and answering `ping` and RPCs. A task that dies without reporting
  is noticed through its monitor: a hydration counts as failed (the member
  is reset), a report's waiters are answered with an error.

  **Lease.** It renews `owner_lease_expires_at` periodically and tracks the
  lease's deadline locally. A database error during renewal is retried
  until that deadline; past it the coordinator admits no more work and
  stops (deleting its spool), since the reconciler may then treat it as
  lost. Once renewal finds the session ended or owned by someone else it
  stops. Each renewal also re-checks the session's leased members for a
  missing hydration, so a lost `member_granted` broadcast only delays it.

  Database errors in a callback are logged and answered as
  `owner_unavailable` instead of crashing the coordinator (which would end
  every session it owns). A coordinator whose session row is never
  activated stops after `activation_timeout_ms`.
  """
  use GenServer, restart: :temporary

  require Logger

  alias GoodFlows.Pools.{
    Archive,
    Config,
    Events,
    Exec,
    Execs,
    ExecServer,
    Member,
    Session,
    Sessions,
    ShutdownDrain,
    Spool,
    Transfers,
    TransferSemaphore
  }

  alias GoodFlows.Repo
  alias GoodFlows.Spry.{Executions, Sprites}

  @supervisor GoodFlows.Pools.CoordinatorSupervisor
  @exec_supervisor GoodFlows.Pools.ExecSupervisor
  @task_supervisor GoodFlows.Spry.TaskSupervisor
  @activation_timeout_ms 30_000
  @renew_retry_ms 1_000

  ## API

  @doc "Starts a coordinator under the coordinator supervisor."
  @spec start(map()) :: {:ok, pid()} | {:error, term()}
  def start(%{session_id: _, owner_id: _, account_id: _, token: _} = args) do
    DynamicSupervisor.start_child(@supervisor, {__MODULE__, args})
  end

  @doc false
  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @doc "Tells a coordinator that its session row exists."
  @spec activate(pid()) :: :ok
  def activate(pid), do: GenServer.cast(pid, :activate)

  @doc "Stops a coordinator (deleting its spool)."
  @spec stop(pid()) :: :ok
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The timeout for owner calls that cancel execs (`end_session`,
  `release_member`, an exec `cancel`): an exec stop plus the RPC margin.
  """
  @spec stop_call_timeout_ms() :: pos_integer()
  def stop_call_timeout_ms, do: ExecServer.stop_timeout_ms() + Config.owner_rpc_timeout_ms()

  ## Callbacks

  @impl GenServer
  def init(args) do
    Process.flag(:trap_exit, true)

    case Executions.register(args.owner_id) do
      :ok ->
        Events.subscribe(Events.session_topic(args.session_id))

        Process.send_after(
          self(),
          :activation_timeout,
          Map.get(args, :activation_timeout_ms, @activation_timeout_ms)
        )

        state = %{
          session_id: args.session_id,
          owner_id: args.owner_id,
          account_id: args.account_id,
          client: Sprites.client(args.token),
          active: false,
          # The session row is inserted after this, with a lease of now plus
          # the grace, so this local deadline is never later than the row's.
          lease_deadline: now_ms() + Config.disconnect_grace_ms(),
          ending: nil,
          upload: nil,
          workspace: nil,
          hydration: nil,
          hydration_queue: [],
          execs: %{},
          releasing: %{},
          reports: %{}
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.update(:state, nil, fn
      %{client: _} = state -> %{state | client: :redacted}
      other -> other
    end)
    |> ExecServer.redact_message()
  end

  @impl GenServer
  def handle_cast(:activate, state) do
    schedule_renewal()
    {:noreply, %{state | active: true}}
  end

  @impl GenServer
  def handle_call(request, from, state) do
    call(request, from, state)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      log_db_error(state, error)
      {:reply, {:error, :owner_unavailable}, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    info(message, state)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      log_db_error(state, error)
      {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if state.hydration, do: kill_task(state.hydration.task)

    for {_key, %{status: {:running, task}}} <- state.reports, do: kill_task(task)
    for {_member, %{task: task}} <- state.releasing, do: kill_task(task)

    case state.upload do
      %{file: file} when file != nil -> File.close(file)
      %{preflight: %Task{} = task} -> kill_task(task)
      _other -> :ok
    end

    Spool.delete_session(state.session_id)
    :ok
  end

  ## Calls

  defp call(:ping, _from, state), do: {:reply, :pong, state}

  defp call({:upload_begin, uploader}, _from, state) do
    cond do
      ShutdownDrain.draining?() -> {:reply, {:error, :busy}, state}
      state.ending != nil -> {:reply, {:error, :session_ended}, state}
      lease_lapsed?(state) -> {:reply, {:error, :owner_unavailable}, state}
      state.workspace != nil -> {:reply, {:error, :already_uploaded}, state}
      state.upload != nil -> {:reply, {:error, :upload_in_progress}, state}
      true -> begin_upload(uploader, state)
    end
  end

  defp call(
         {:upload_chunk, ref, data},
         _from,
         %{upload: %{ref: ref, file: file} = upload} = state
       )
       when file != nil do
    size = upload.size + byte_size(data)

    if size > Config.workspace_max_bytes() do
      {:reply, {:error, :too_large}, abort_upload(state)}
    else
      case :file.write(file, data) do
        :ok ->
          upload = %{upload | size: size, hash: :crypto.hash_update(upload.hash, data)}
          {:reply, :ok, %{state | upload: upload}}

        {:error, _reason} ->
          {:reply, {:error, :spool_failed}, abort_upload(state)}
      end
    end
  end

  defp call({:upload_chunk, _ref, _data}, _from, state),
    do: {:reply, {:error, :no_upload}, state}

  defp call({:upload_abort, ref}, _from, %{upload: %{ref: ref}} = state),
    do: {:reply, :ok, abort_upload(state)}

  defp call({:upload_abort, _ref}, _from, state), do: {:reply, :ok, state}

  defp call({:upload_finish, ref}, from, %{upload: %{ref: ref, file: file} = upload} = state)
       when file != nil do
    File.close(file)
    sha = :crypto.hash_final(upload.hash)
    path = upload.path

    # Preflight off the coordinator process so it stays responsive.
    task = start_task(fn -> Archive.validate(path, Archive.limits()) end)

    upload = %{upload | file: nil, preflight: task, finish_from: from, sha: sha}
    {:noreply, %{state | upload: upload}}
  end

  defp call({:upload_finish, _ref}, _from, state), do: {:reply, {:error, :no_upload}, state}

  ## Execs

  defp call({:start_exec, request}, _from, state) do
    with :ok <- admitting(state),
         :ok <- not_releasing(state, request.member_id),
         {:ok, session} <- fetch_session(state),
         deadline = DateTime.add(DateTime.utc_now(), request.timeout_ms + 60_000, :millisecond),
         exec_owner = Executions.new_owner_id(),
         {:ok, exec, member} <- Execs.admit(session, request, exec_owner, deadline) do
      state = drop_member_reports(state, member.id)

      case start_exec_server(state, exec, member, request, exec_owner) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          entry = %{pid: pid, ref: ref, member_id: member.id}
          {:reply, {:ok, exec.id}, %{state | execs: Map.put(state.execs, exec.id, entry)}}

        {:error, _reason} ->
          # Nothing runs: the admitted row must not stay `running`.
          _ = Execs.finalize(exec.id, exec_owner, %{status: "error", error_reason: "exec_failed"})
          {:reply, {:error, "unavailable"}, state}
      end
    else
      {:error, reason} when is_binary(reason) -> {:reply, {:error, reason}, state}
    end
  end

  # Releasing one member: its in-flight hydration stops at once, its
  # running exec is cancelled in a task (without the ExecServer resetting
  # the member itself), and no exec is admitted on it meanwhile; then the
  # database release runs here and its reports are invalidated
  # (`release_finished/3`). When an exec cannot be confirmed stopped, the
  # release is refused and the member stays leased.
  defp call({:release_member, member_id}, from, state) do
    case Map.fetch(state.releasing, member_id) do
      {:ok, entry} ->
        releasing =
          Map.put(state.releasing, member_id, %{entry | waiters: [from | entry.waiters]})

        {:noreply, %{state | releasing: releasing}}

      :error ->
        state = stop_hydration(state, member_id)
        entries = state.execs |> Map.values() |> Enum.filter(&(&1.member_id == member_id))
        task = start_task(fn -> cancel_all(entries, "cancelled", nil, reset: false) end)
        releasing = Map.put(state.releasing, member_id, %{task: task, waiters: [from]})
        {:noreply, %{state | releasing: releasing}}
    end
  end

  # Ending: no more work is admitted, running execs are cancelled in a
  # task, and the coordinator stops once their exits are persisted.
  defp call({:end_session, status, error_reason}, from, %{ending: nil} = state) do
    entries = Map.values(state.execs)
    task = start_task(fn -> cancel_all(entries, status, error_reason, []) end)
    {:noreply, %{state | ending: %{task: task, waiters: [from]}}}
  end

  defp call({:end_session, _status, _reason}, from, %{ending: ending} = state),
    do: {:noreply, %{state | ending: %{ending | waiters: [from | ending.waiters]}}}

  ## Reports

  defp call({:fetch_report, exec_id, name}, from, state) do
    case authorize_report(state, exec_id, name) do
      {:ok, exec, member} -> fetch_report(state, from, exec, member, name)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp call({:read_report, exec_id, name, offset, max}, _from, state) do
    with %{status: {:ready, path, size, _sha}} <- Map.get(state.reports, {exec_id, name}),
         {:ok, data} <- read_spooled(path, offset, min(max, max(size - offset, 0))) do
      {:reply, {:ok, data}, state}
    else
      _ -> {:reply, {:error, :gone}, state}
    end
  end

  ## Messages

  defp info(:renew, state) do
    started = now_ms()

    case renew(state) do
      :ok ->
        schedule_renewal()
        state = %{state | lease_deadline: started + Config.disconnect_grace_ms()}
        {:noreply, hydrate_leased(state)}

      :stale ->
        {:stop, :normal, state}

      {:error, error} ->
        remaining = state.lease_deadline - now_ms()

        if remaining <= 0 do
          Logger.error(
            "Pools: session coordinator #{state.session_id} could not renew its lease " <>
              "before it lapsed (#{Exception.message(error)}); stopping"
          )

          {:stop, :normal, state}
        else
          Logger.warning(
            "Pools: session coordinator #{state.session_id} lease renewal failed " <>
              "(#{Exception.message(error)}); retrying"
          )

          Process.send_after(self(), :renew, min(@renew_retry_ms, remaining))
          {:noreply, state}
        end
    end
  end

  defp info(:activation_timeout, %{active: false} = state) do
    Logger.warning("Pools: session coordinator #{state.session_id} was never activated; stopping")
    {:stop, :normal, state}
  end

  defp info(:activation_timeout, state), do: {:noreply, state}

  defp info({:pool_session_event, "member_granted", %{member_id: member_id}}, state),
    do: {:noreply, maybe_hydrate(state, member_id)}

  defp info({:pool_session_event, "session_ended", _payload}, %{ending: nil} = state),
    do: {:stop, :normal, state}

  defp info({:pool_session_event, _event, _payload}, state), do: {:noreply, state}

  # Task results: each task kind is matched by its reference.
  defp info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    task_done(ref, {:ok, result}, state)
  end

  defp info({:DOWN, ref, :process, _pid, reason}, state) do
    case task_kind(state, ref) do
      nil -> process_down(ref, state)
      _kind -> task_done(ref, {:exit, reason}, state)
    end
  end

  defp info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  defp info(_message, state), do: {:noreply, state}

  # A monitored ExecServer or uploader exited.
  defp process_down(ref, state) do
    {lost, execs} = Enum.split_with(state.execs, fn {_id, %{ref: r}} -> r == ref end)
    execs = Map.new(execs)

    # An exec server that died without finalizing: its owner is confirmed
    # lost (it ran on this node), so the exec ends error/owner_lost and the
    # member is reset (the restore ends any orphaned remote process).
    for {exec_id, _entry} <- lost, do: Execs.recover_lost(exec_id)

    state =
      case state.upload do
        %{monitor: ^ref} -> abort_upload(%{state | execs: execs})
        _ -> %{state | execs: execs}
      end

    {:noreply, state}
  end

  ## Tasks

  defp start_task(fun), do: Task.Supervisor.async(@task_supervisor, fun)

  defp kill_task(%Task{ref: ref, pid: pid}) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
  end

  defp task_kind(state, ref) do
    cond do
      match?(%{task: %Task{ref: ^ref}}, state.hydration) -> :hydration
      match?(%{preflight: %Task{ref: ^ref}}, state.upload) -> :preflight
      match?(%{task: %Task{ref: ^ref}}, state.ending) -> :ending
      release_key(state, ref) -> :release
      report_key(state, ref) -> :report
      true -> nil
    end
  end

  defp release_key(state, ref),
    do: Enum.find_value(state.releasing, fn {id, %{task: t}} -> if t.ref == ref, do: id end)

  defp report_key(state, ref) do
    Enum.find_value(state.reports, fn
      {key, %{status: {:running, %Task{ref: ^ref}}}} -> key
      _other -> nil
    end)
  end

  # `outcome` is `{:ok, result}` or `{:exit, reason}` (the task died
  # without reporting).
  defp task_done(ref, outcome, state) do
    case task_kind(state, ref) do
      :hydration -> hydrated(state, outcome)
      :preflight -> preflight_done(state, outcome)
      :ending -> ended(state)
      :release -> release_finished(state, release_key(state, ref))
      :report -> report_done(state, report_key(state, ref), outcome)
      nil -> {:noreply, state}
    end
  end

  ## Upload helpers

  # The path is this node's spool dir joined with the session UUID; never user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp begin_upload(uploader, state) do
    case Spool.reserve(state.account_id, Config.workspace_max_bytes(), self(), :upload) do
      {:ok, reservation} ->
        dir = Spool.session_dir(state.session_id)
        File.mkdir_p!(dir)
        path = Path.join(dir, "workspace.tar.gz")
        {:ok, file} = File.open(path, [:write, :binary, :raw])
        ref = make_ref()

        upload = %{
          ref: ref,
          path: path,
          file: file,
          size: 0,
          hash: :crypto.hash_init(:sha256),
          sha: nil,
          reservation: reservation,
          monitor: Process.monitor(uploader),
          preflight: nil,
          finish_from: nil
        }

        {:reply, {:ok, ref}, %{state | upload: upload}}

      {:error, :busy} ->
        {:reply, {:error, :busy}, state}
    end
  end

  defp abort_upload(%{upload: nil} = state), do: state

  # The upload path was built by begin_upload/2 under the spool dir; never user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp abort_upload(%{upload: upload} = state) do
    if upload.file, do: File.close(upload.file)
    if upload.preflight, do: kill_task(upload.preflight)
    if upload.finish_from, do: GenServer.reply(upload.finish_from, {:error, :no_upload})
    Process.demonitor(upload.monitor, [:flush])
    File.rm(upload.path)
    Spool.release(upload.reservation)
    %{state | upload: nil}
  end

  defp preflight_done(%{upload: upload} = state, outcome) do
    from = upload.finish_from
    state = %{state | upload: %{upload | preflight: nil, finish_from: nil}}

    case outcome do
      {:ok, :ok} ->
        record_upload(state, from)

      {:ok, {:error, reason}} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, abort_upload(state)}

      {:exit, _reason} ->
        GenServer.reply(from, {:error, :owner_unavailable})
        {:noreply, abort_upload(state)}
    end
  end

  defp record_upload(%{upload: upload} = state, from) do
    case safe_db(fn ->
           Sessions.mark_workspace_uploaded(
             state.session_id,
             state.owner_id,
             upload.size,
             upload.sha
           )
         end) do
      :ok ->
        Spool.settle(upload.reservation, upload.size)
        GenServer.reply(from, :ok)
        Process.demonitor(upload.monitor, [:flush])

        workspace = %{
          path: upload.path,
          size: upload.size,
          sha: upload.sha,
          reservation: upload.reservation
        }

        {:noreply, hydrate_leased(%{state | upload: nil, workspace: workspace})}

      :stale ->
        GenServer.reply(from, {:error, :session_ended})
        {:noreply, abort_upload(state)}

      {:error, error} ->
        log_db_error(state, error)
        GenServer.reply(from, {:error, :owner_unavailable})
        {:noreply, abort_upload(state)}
    end
  end

  ## Hydration

  # Queues every leased member still missing its workspace (after an
  # upload, and on each renewal, in case a `member_granted` was missed).
  defp hydrate_leased(%{workspace: nil} = state), do: state

  defp hydrate_leased(state) do
    state.session_id
    |> Sessions.members()
    |> Enum.reject(&Member.ready?/1)
    |> Enum.reduce(state, &maybe_hydrate(&2, &1.id))
  end

  defp maybe_hydrate(%{workspace: nil} = state, _member_id), do: state

  defp maybe_hydrate(state, member_id) do
    cond do
      match?(%{member_id: ^member_id}, state.hydration) ->
        state

      member_id in state.hydration_queue ->
        state

      Map.has_key?(state.releasing, member_id) ->
        state

      true ->
        start_next_hydration(%{state | hydration_queue: state.hydration_queue ++ [member_id]})
    end
  end

  # Writes per session are sequential: one hydration runs at a time.
  defp start_next_hydration(%{hydration: nil, hydration_queue: [member_id | rest]} = state) do
    state = %{state | hydration_queue: rest}

    case hydration_target(state, member_id) do
      %Member{} = member ->
        %{client: client, session_id: session_id, workspace: workspace} = state
        deadline = session_deadline_ms(session_id)
        task = start_task(fn -> hydrate(client, member, session_id, workspace, deadline) end)

        %{
          state
          | hydration: %{member_id: member.id, generation: member.lease_generation, task: task}
        }

      nil ->
        start_next_hydration(state)
    end
  end

  defp start_next_hydration(state), do: state

  defp hydration_target(state, member_id) do
    case Repo.get(Member, member_id) do
      %Member{state: "leased", session_id: session_id} = member
      when session_id == state.session_id ->
        if Member.ready?(member), do: nil, else: member

      _other ->
        nil
    end
  end

  # Runs in the hydration task.
  defp hydrate(client, member, session_id, workspace, deadline) do
    generation = member.lease_generation
    fence = fn -> Sessions.lease_current?(member.id, session_id, generation) end

    case TransferSemaphore.with_permit(remaining_ms(deadline), fn ->
           Transfers.receive_workspace(client, member, session_id, workspace, deadline,
             fence: fence
           )
         end) do
      {:error, :busy} -> {:error, "transfer capacity"}
      other -> other
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, _reason -> {:error, "hydration #{kind}"}
  end

  defp hydrated(%{hydration: %{member_id: member_id, generation: generation}} = state, outcome) do
    state = %{state | hydration: nil}

    result =
      case outcome do
        {:ok, result} -> result
        {:exit, _reason} -> {:error, "the hydration task exited"}
      end

    case result do
      :ok ->
        Sessions.mark_member_ready(member_id, state.session_id, generation)

      {:error, :helper_missing} ->
        Sessions.member_lost(
          member_id,
          state.session_id,
          generation,
          :broken,
          "transfer helper is missing or incompatible"
        )

      {:error, "lease lost"} ->
        # Released or re-leased meanwhile: nothing to report.
        :stale

      {:error, reason} ->
        Sessions.member_lost(
          member_id,
          state.session_id,
          generation,
          :reset,
          "workspace hydration failed: #{reason}"
        )
    end

    {:noreply, start_next_hydration(state)}
  end

  defp stop_hydration(state, member_id) do
    state = %{state | hydration_queue: List.delete(state.hydration_queue, member_id)}

    case state.hydration do
      %{member_id: ^member_id, task: task} ->
        kill_task(task)
        start_next_hydration(%{state | hydration: nil})

      _other ->
        state
    end
  end

  ## Exec helpers

  defp admitting(state) do
    cond do
      ShutdownDrain.draining?() -> {:error, "draining"}
      state.ending != nil -> {:error, "ended"}
      lease_lapsed?(state) -> {:error, "unavailable"}
      true -> :ok
    end
  end

  defp not_releasing(state, member_id) do
    if Map.has_key?(state.releasing, member_id), do: {:error, "not_granted"}, else: :ok
  end

  defp fetch_session(state) do
    case Repo.get(Session, state.session_id) do
      %{status: status} = session when status in ["waiting", "active"] -> {:ok, session}
      _ -> {:error, "ended"}
    end
  end

  defp start_exec_server(state, exec, member, request, exec_owner) do
    DynamicSupervisor.start_child(
      @exec_supervisor,
      {ExecServer,
       %{
         exec: exec,
         member_name: member.name,
         owner_id: exec_owner,
         client: state.client,
         request: request,
         coordinator: self()
       }}
    )
  end

  # Runs in a task: cancels concurrently; each answers once its exit is
  # persisted.
  defp cancel_all(entries, status, error_reason, opts) do
    entries
    |> Enum.map(
      &Task.async(fn ->
        ExecServer.cancel(&1.pid, status, error_reason, opts, ExecServer.stop_timeout_ms())
      end)
    )
    |> Task.await_many(:infinity)
  end

  defp release_finished(state, member_id) do
    {%{waiters: waiters}, releasing} = Map.pop(state.releasing, member_id)
    state = %{state | releasing: releasing}

    reply = release_reply(state, member_id)
    Enum.each(waiters, &GenServer.reply(&1, reply))
    {:noreply, drop_member_reports(state, member_id)}
  end

  # The exec stop could not be confirmed: the member stays leased.
  defp release_reply(state, member_id) do
    result =
      safe_db(fn ->
        if Execs.running_on_member?(member_id),
          do: {:error, :owner_unavailable},
          else: Sessions.release_member_now(state.session_id, member_id)
      end)

    case result do
      {:error, %{__exception__: true} = error} ->
        log_db_error(state, error)
        {:error, :owner_unavailable}

      reply ->
        reply
    end
  end

  defp ended(%{ending: %{waiters: waiters}} = state) do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    {:stop, :normal, state}
  end

  ## Report helpers

  defp authorize_report(state, exec_id, name) do
    with {:ok, exec_id} <- Ecto.UUID.cast(exec_id),
         %Exec{session_id: session_id} = exec when session_id == state.session_id <-
           Repo.get(Exec, exec_id),
         %{"too_large" => false} <- Enum.find(Exec.report_files(exec), &(&1["name"] == name)),
         :ok <- current_report(exec) do
      {:ok, exec, Repo.get(Member, exec.member_id)}
    else
      {:error, :gone} -> {:error, :gone}
      _ -> {:error, :not_found}
    end
  end

  defp still_current?(exec_id) do
    case Repo.get(Exec, exec_id) do
      %Exec{} = exec -> current_report(exec) == :ok
      nil -> false
    end
  end

  defp current_report(%Exec{status: "running"}), do: {:error, :not_found}

  defp current_report(%Exec{} = exec) do
    member = exec.member_id && Repo.get(Member, exec.member_id)
    latest = exec.member_id && Execs.latest_on_member(exec.member_id)

    if same_lease?(member, exec) and not superseded?(latest, exec),
      do: :ok,
      else: {:error, :gone}
  end

  defp same_lease?(nil, _exec), do: false

  defp same_lease?(member, exec) do
    member.state == "leased" and member.session_id == exec.session_id and
      member.lease_generation == exec.lease_generation
  end

  defp superseded?(nil, _exec), do: false
  defp superseded?(latest, exec), do: latest.id != exec.id

  # The path is a spooled report under this node's spool dir (session UUID,
  # exec UUID, hashed report name); never user input.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_spooled(path, offset, length) do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      data = if length == 0, do: "", else: elem(:file.pread(file, offset, length), 1)
      File.close(file)
      {:ok, data}
    end
  end

  defp fetch_report(state, from, exec, member, name) do
    key = {exec.id, name}

    case Map.get(state.reports, key) do
      %{status: {:ready, path, size, sha}} ->
        {:reply, {:ok, %{size: size, sha256: sha, path: path}}, state}

      %{status: {:running, _task}, waiters: waiters} = entry ->
        {:noreply,
         %{state | reports: Map.put(state.reports, key, %{entry | waiters: [from | waiters]})}}

      # A failed download keeps its reservation (and any partial download,
      # which `Transfers` resumes), so a retry reuses both.
      %{status: :failed} = entry ->
        task = start_report_task(state, exec, member, name)
        entry = %{entry | status: {:running, task}, waiters: [from]}
        {:noreply, %{state | reports: Map.put(state.reports, key, entry)}}

      nil ->
        # The download is spooled to disk: reserve the report cap first.
        case Spool.reserve(state.account_id, Config.report_max_bytes(), self(), :report) do
          {:ok, reservation} ->
            task = start_report_task(state, exec, member, name)

            entry = %{
              status: {:running, task},
              waiters: [from],
              reservation: reservation,
              member_id: exec.member_id
            }

            {:noreply, %{state | reports: Map.put(state.reports, key, entry)}}

          {:error, :busy} ->
            {:reply, {:error, :busy}, state}
        end
    end
  end

  defp start_report_task(state, exec, member, name) do
    client = state.client
    dir = Path.join([Spool.session_dir(state.session_id), "reports", exec.id])
    deadline = session_deadline_ms(state.session_id)

    start_task(fn ->
      try do
        TransferSemaphore.with_permit(
          Config.report_fetch_timeout_ms(),
          fn -> Transfers.fetch_report(client, member, exec, name, dir, deadline) end,
          priority: :high
        )
      rescue
        _error -> {:error, :transfer_failed}
      catch
        _kind, _reason -> {:error, :transfer_failed}
      end
    end)
  end

  defp report_done(state, key, outcome) do
    %{waiters: waiters, reservation: reservation} = entry = Map.fetch!(state.reports, key)
    {exec_id, _name} = key

    {status, reply} =
      case outcome do
        {:ok, {:ok, spooled}} ->
          spooled_report(exec_id, spooled)

        {:ok, {:error, reason}} ->
          {:failed, {:error, reason}}

        {:exit, _reason} ->
          {:failed, {:error, :transfer_failed}}
      end

    Enum.each(waiters, &GenServer.reply(&1, reply))

    # A failed download stays tracked with its reservation: `Transfers`
    # keeps its partial files for resumption, and they must stay within the
    # spool budget until a retry finishes or `drop_member_reports/2` (or the
    # session's end) deletes them.
    case status do
      {:ready, _path, size, _sha} -> Spool.settle(reservation, size)
      :failed -> :ok
    end

    reports = Map.put(state.reports, key, %{entry | status: status, waiters: []})
    {:noreply, %{state | reports: reports}}
  end

  # Released or superseded while transferring: never served.
  defp spooled_report(exec_id, %{path: path, size: size, sha256: sha}) do
    case safe_db(fn -> still_current?(exec_id) end) do
      true -> {{:ready, path, size, sha}, {:ok, %{size: size, sha256: sha, path: path}}}
      false -> {:failed, {:error, :gone}}
      {:error, _error} -> {:failed, {:error, :transfer_failed}}
    end
  end

  # A new exec (or a release) invalidates every report of the member's
  # previous execs: running transfers stop, spooled copies go, and their
  # spool reservations are released. The removed dirs are the spool dir
  # joined with the session and exec UUIDs.
  # sobelow_skip ["Traversal.FileModule"]
  defp drop_member_reports(state, member_id) do
    {dropped, kept} =
      Map.split_with(state.reports, fn {_key, entry} -> entry.member_id == member_id end)

    for {{exec_id, _name}, entry} <- dropped do
      case entry do
        %{status: {:running, task}, waiters: waiters} ->
          kill_task(task)
          Enum.each(waiters, &GenServer.reply(&1, {:error, :gone}))

        _ready ->
          :ok
      end

      Spool.release(entry.reservation)
      File.rm_rf(Path.join([Spool.session_dir(state.session_id), "reports", exec_id]))
    end

    %{state | reports: kept}
  end

  ## Lease and database helpers

  defp renew(state) do
    Sessions.renew_owner_lease(state.session_id, state.owner_id)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp lease_lapsed?(state), do: now_ms() >= state.lease_deadline

  defp safe_db(fun) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, error}
  end

  defp log_db_error(state, error) do
    Logger.warning(
      "Pools: session coordinator #{state.session_id} database error: " <>
        Exception.message(error)
    )
  end

  # The session's hard expiry (creation + max lifetime) in unix ms: the
  # deadline of every transfer and permit wait on its behalf.
  defp session_deadline_ms(session_id) do
    created =
      case Repo.get(Session, session_id) do
        %Session{inserted_at: inserted_at} -> inserted_at
        nil -> DateTime.utc_now()
      end

    DateTime.to_unix(created, :millisecond) + Config.max_session_lifetime_ms()
  end

  defp remaining_ms(deadline), do: max(deadline - System.os_time(:millisecond), 0)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule_renewal,
    do: Process.send_after(self(), :renew, max(div(Config.disconnect_grace_ms(), 3), 1_000))
end
