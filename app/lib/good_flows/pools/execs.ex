defmodule GoodFlows.Pools.Execs do
  @moduledoc """
  Exec requests, admission, and fenced finalization.

  `validate_request/1` checks an `exec` channel payload without touching
  the database. `admit/4` runs on the session coordinator's node: in one
  transaction it locks the pool, session, and member rows (the lock order
  of grants and releases), requires the member to
  be leased to the session and ready, and inserts the `running` exec row.
  The partial unique index on `pool_execs (member_id) WHERE status =
  'running'` turns a concurrent second admission into `member_busy`.

  The request's `command`, `argv`, and `env` are never stored or logged:
  only ids, labels, status, timings, byte counts, and the bounded terminal
  exit payload are kept.
  """
  import Ecto.Query

  alias GoodFlows.Pools.{Config, Events, Exec, Member, Members, Session, Sessions}
  alias GoodFlows.Repo

  @label_max 255
  # Bounds on one request, so a client cannot make the server hold or
  # forward an unbounded command line or environment.
  @argv_max_items 4_096
  @env_max_entries 1_024
  @request_max_bytes 262_144

  @typedoc "A validated exec request."
  @type request :: %{
          member_id: Ecto.UUID.t(),
          argv: [String.t()],
          cwd: String.t(),
          env: [{String.t(), String.t()}],
          timeout_ms: pos_integer(),
          collect_reports: boolean(),
          job: String.t() | nil,
          step: String.t() | nil
        }

  @doc """
  Validates an `exec` payload. `command` runs as `sh -c command`; `argv` is
  run directly. Returns `{:error, %{reason: "invalid_request", fields: [...]}}`
  naming the offending fields.
  """
  @spec validate_request(map()) :: {:ok, request()} | {:error, map()}
  def validate_request(params) when is_map(params) do
    checks = [
      member_id: &member_id/1,
      argv: &argv/1,
      cwd: &cwd/1,
      env: &env/1,
      timeout_ms: &timeout/1,
      collect_reports: &collect_reports/1,
      job: &label(&1, "job"),
      step: &label(&1, "step")
    ]

    {values, errors} =
      Enum.reduce(checks, {%{}, []}, fn {key, check}, {values, errors} ->
        case check.(params) do
          {:ok, value} -> {Map.put(values, key, value), errors}
          {:error, fields} -> {values, errors ++ List.wrap(fields)}
        end
      end)

    errors = if errors == [], do: size_errors(params, values), else: errors

    if errors == [],
      do: {:ok, values},
      else: {:error, %{reason: "invalid_request", fields: Enum.uniq(errors)}}
  end

  def validate_request(_params), do: {:error, %{reason: "invalid_request", fields: []}}

  @doc "Most argv items in one exec request (#{@argv_max_items})."
  @spec argv_max_items() :: pos_integer()
  def argv_max_items, do: @argv_max_items

  @doc "Most env entries in one exec request (#{@env_max_entries})."
  @spec env_max_entries() :: pos_integer()
  def env_max_entries, do: @env_max_entries

  @doc """
  Most bytes of `command` (or every `argv` item) plus every env name and
  value in one exec request (#{@request_max_bytes}).
  """
  @spec request_max_bytes() :: pos_integer()
  def request_max_bytes, do: @request_max_bytes

  # The command line and environment together stay within the byte cap;
  # over it, the offending fields are `command` or `argv`, and `env` when
  # one was given.
  defp size_errors(params, %{argv: argv, env: env}) do
    {field, command_bytes} =
      case params do
        %{"command" => command} -> {"command", byte_size(command)}
        _argv -> {"argv", Enum.reduce(argv, 0, &(byte_size(&1) + &2))}
      end

    bytes =
      Enum.reduce(env, command_bytes, fn {name, value}, acc ->
        acc + byte_size(name) + byte_size(value)
      end)

    if bytes > @request_max_bytes do
      if env == [], do: [field], else: [field, "env"]
    else
      []
    end
  end

  defp member_id(%{"member_id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "member_id"}
    end
  end

  defp member_id(_params), do: {:error, "member_id"}

  defp argv(%{"command" => _, "argv" => _}), do: {:error, ["command", "argv"]}

  defp argv(%{"command" => command}) when is_binary(command) and command != "",
    do: {:ok, ["sh", "-c", command]}

  defp argv(%{"command" => _}), do: {:error, "command"}

  defp argv(%{"argv" => [_ | _] = argv}) do
    if length(argv) <= @argv_max_items and Enum.all?(argv, &is_binary/1),
      do: {:ok, argv},
      else: {:error, "argv"}
  end

  defp argv(%{"argv" => _}), do: {:error, "argv"}
  defp argv(_params), do: {:error, ["command", "argv"]}

  # Lexical only: `/workspace` plus relative segments without `..`. A
  # symlink inside the workspace is followed by the member's shell; the
  # member holds only this session's workspace and is reset before reuse.
  defp cwd(params) do
    case Map.get(params, "cwd", ".") do
      cwd when is_binary(cwd) ->
        segments = String.split(cwd, "/", trim: true)

        cond do
          String.starts_with?(cwd, "/") -> {:error, "cwd"}
          ".." in segments -> {:error, "cwd"}
          String.contains?(cwd, <<0>>) -> {:error, "cwd"}
          true -> {:ok, Path.join(["/workspace" | Enum.reject(segments, &(&1 == "."))])}
        end

      _other ->
        {:error, "cwd"}
    end
  end

  defp env(params) do
    case Map.get(params, "env", %{}) do
      env when is_map(env) and map_size(env) <= @env_max_entries ->
        if valid_env?(env), do: {:ok, Enum.sort(env)}, else: {:error, "env"}

      _other ->
        {:error, "env"}
    end
  end

  defp valid_env?(env), do: Enum.all?(env, fn {k, v} -> valid_env_name?(k) and is_binary(v) end)

  defp valid_env_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name)

  defp timeout(params) do
    case Map.get(params, "timeout_ms") do
      nil -> {:ok, Config.exec_max_ms()}
      ms when is_integer(ms) and ms >= 1 -> {:ok, min(ms, Config.exec_max_ms())}
      _other -> {:error, "timeout_ms"}
    end
  end

  defp collect_reports(params) do
    case Map.get(params, "collect_reports", false) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, "collect_reports"}
    end
  end

  defp label(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) <= @label_max -> {:ok, value}
      _other -> {:error, key}
    end
  end

  @doc """
  Admits an exec: locks the pool, session, and member, requires the session open,
  the member leased to it and ready, and inserts the `running` row owned by
  `owner_id` with its hard deadline.
  """
  @spec admit(Session.t(), request(), String.t(), DateTime.t()) ::
          {:ok, Exec.t(), Member.t()} | {:error, String.t()}
  def admit(%Session{id: session_id}, request, owner_id, deadline) do
    Repo.transact(fn ->
      with {:ok, session} <- lock_open_session(session_id),
           {:ok, member} <- lock_granted_member(session, request.member_id),
           :ok <- ready(member) do
        insert_running(session, member, request, owner_id, deadline)
      end
    end)
    |> case do
      {:ok, {exec, member}} -> {:ok, exec, member}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_running(session, member, request, owner_id, deadline) do
    %Exec{
      account_id: session.account_id,
      session_id: session.id,
      member_id: member.id,
      member_name: member.name,
      lease_generation: member.lease_generation,
      job: request.job,
      step: request.step,
      collect_reports: request.collect_reports,
      status: "running",
      owner_id: owner_id,
      operation_deadline_at: deadline,
      started_at: DateTime.utc_now()
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:member_id,
      name: :pool_execs_one_running_per_member_index
    )
    |> Repo.insert()
    |> case do
      {:ok, exec} -> {:ok, {exec, member}}
      {:error, _changeset} -> {:error, "member_busy"}
    end
  end

  # Lock order: pool, session, member (as grants and releases take them).
  defp lock_open_session(session_id) do
    with %Session{pool_id: pool_id} <- Repo.get(Session, session_id),
         do: Members.lock_pool(pool_id)

    case Session |> where(id: ^session_id) |> lock("FOR UPDATE") |> Repo.one() do
      %Session{status: status} = session when status in ["waiting", "active"] -> {:ok, session}
      _ended -> {:error, "ended"}
    end
  end

  defp lock_granted_member(session, member_id) do
    member =
      Member
      |> where([m], m.id == ^member_id and m.session_id == ^session.id and m.state == "leased")
      |> lock("FOR UPDATE")
      |> Repo.one()

    if member, do: {:ok, member}, else: {:error, "not_granted"}
  end

  defp ready(member) do
    cond do
      not Member.ready?(member) -> {:error, "member_not_ready"}
      running?(member.id) -> {:error, "member_busy"}
      true -> :ok
    end
  end

  defp running?(member_id), do: running_on_member?(member_id)

  @doc "Whether the member has a `running` exec."
  @spec running_on_member?(Ecto.UUID.t()) :: boolean()
  def running_on_member?(member_id),
    do: Repo.exists?(where(Exec, [e], e.member_id == ^member_id and e.status == "running"))

  @doc """
  Finalizes a `running` exec owned by `owner_id` (`:any` skips the owner
  fence, for owner-loss recovery). Returns the updated row, or `:stale`
  when it was already finalized.
  """
  @spec finalize(Ecto.UUID.t(), String.t() | :any, map()) :: {:ok, Exec.t()} | :stale
  def finalize(exec_id, owner_id, attrs) do
    now = DateTime.utc_now()
    query = where(Exec, [e], e.id == ^exec_id and e.status == "running")
    query = if owner_id == :any, do: query, else: where(query, [e], e.owner_id == ^owner_id)

    set =
      attrs
      |> Map.take([
        :status,
        :exit_code,
        :outputs,
        :outputs_truncated,
        :reports,
        :reports_truncated,
        :collect_failed,
        :final_output_seq,
        :error_reason,
        :duration_ms,
        :bytes_stdout,
        :bytes_stderr
      ])
      |> Map.put(:ended_at, now)
      |> Map.put(:updated_at, now)
      |> Map.to_list()

    case query |> select([e], e) |> Repo.update_all(set: set) do
      {1, [exec]} -> {:ok, exec}
      {0, _} -> :stale
    end
  end

  @doc """
  Recovers an exec whose owner is confirmed lost (or past its hard
  deadline): finalizes it as `error`/`owner_lost` (if still running),
  pushes its `exit`, and releases its member for reset, announced as
  `member_lost` so the session is offered a replacement.
  """
  @spec recover_lost(Ecto.UUID.t()) :: :ok
  def recover_lost(exec_id) do
    with %Exec{status: "running", started_at: started} <- Repo.get(Exec, exec_id),
         duration = DateTime.diff(DateTime.utc_now(), started, :millisecond),
         {:ok, exec} <-
           finalize(exec_id, :any, %{
             status: "error",
             error_reason: "owner_lost",
             duration_ms: duration
           }) do
      Events.exec_event(exec.id, "exit", Exec.exit_event(exec))

      if exec.member_id do
        Sessions.member_lost(
          exec.member_id,
          exec.session_id,
          exec.lease_generation,
          :reset,
          "exec owner lost"
        )
      end
    end

    :ok
  end

  @doc "Running execs whose hard deadline has passed or whose owner is confirmed lost."
  @spec lost_running(DateTime.t(), (String.t() -> boolean())) :: [Exec.t()]
  def lost_running(now, lost_owner?) do
    Exec
    |> where([e], e.status == "running")
    |> Repo.all()
    |> Enum.filter(fn exec ->
      (exec.operation_deadline_at != nil and
         DateTime.compare(now, exec.operation_deadline_at) == :gt) or
        lost_owner?.(exec.owner_id)
    end)
  end

  @doc "Fetches an exec of the account."
  @spec get(Ecto.UUID.t(), term()) :: {:ok, Exec.t()} | {:error, :not_found}
  def get(account_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Exec{} = exec <- Repo.get_by(Exec, id: id, account_id: account_id) do
      {:ok, exec}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Running execs of a session."
  @spec running(Ecto.UUID.t()) :: [Exec.t()]
  def running(session_id) do
    Exec
    |> where([e], e.session_id == ^session_id and e.status == "running")
    |> order_by([e], asc: e.started_at)
    |> Repo.all()
  end

  @doc "The latest exec started on a member, or nil."
  @spec latest_on_member(Ecto.UUID.t()) :: Exec.t() | nil
  def latest_on_member(member_id) do
    Exec
    |> where([e], e.member_id == ^member_id)
    |> order_by([e], desc: e.started_at, desc: e.id)
    |> limit(1)
    |> Repo.one()
  end
end
