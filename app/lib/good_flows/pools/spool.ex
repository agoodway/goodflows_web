defmodule GoodFlows.Pools.Spool do
  @moduledoc """
  Node-local disk spools for pool sessions, and the node spool budget.

  Layout: `<spool_dir>/<node>/<boot_id>/<session_id>/` holds
  `workspace.tar.gz` (the uploaded workspace) and `reports/` (verified
  report downloads and their receive state). Only the session coordinator
  on this node writes a session's directory, and it deletes it when the
  session ends. Keying by node name first lets several nodes share one
  `spool_dir` (for example on one host) without touching each other's
  files.

  The budget (`GenServer`) admits spool writes against `spool_max_bytes`
  (node-wide) and `spool_account_max_bytes` (per account, so one account
  cannot starve the others), released by the holder or when the holder
  process exits:

    * an upload (`:upload`) reserves the full `workspace_max_bytes` and
      counts against the per-account concurrent upload cap (per node, not
      cluster-wide); once it finishes, `settle/2` shrinks the reservation
      to the archive's actual size and frees the upload slot, while the
      spooled archive stays for later grants
    * a report download (`:report`) reserves the 32 MiB report cap before
      it starts and is settled to the report's actual size once verified

  `janitor/0` (run at boot) deletes this node's spools of earlier boots;
  their sessions ended with the boot. `sweep/0` (every
  10 minutes) deletes this boot's session spools whose
  session ended, is unknown, or has no live coordinator here (one killed
  without running its cleanup).
  """
  use GenServer

  require Logger

  alias GoodFlows.Pools.{Config, Session}
  alias GoodFlows.Repo
  alias GoodFlows.Spry.Executions

  @sweep_interval_ms 10 * 60_000

  @doc false
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "This node's spool root (every boot of this node)."
  @spec node_dir() :: String.t()
  def node_dir,
    do:
      Path.join(Config.spool_dir(), String.replace(to_string(node()), ~r/[^A-Za-z0-9@._-]/, "_"))

  @doc "This boot's spool root."
  @spec boot_dir() :: String.t()
  def boot_dir, do: Path.join(node_dir(), Executions.boot_id())

  @doc "The spool directory of a session on this node."
  @spec session_dir(Ecto.UUID.t()) :: String.t()
  def session_dir(session_id), do: Path.join(boot_dir(), session_id)

  @doc "Deletes a session's spool directory."
  @spec delete_session(Ecto.UUID.t()) :: :ok
  # The dir is the configured spool root + boot id + session UUID; never user input.
  # sobelow_skip ["Traversal.FileModule"]
  def delete_session(session_id) do
    File.rm_rf(session_dir(session_id))
    :ok
  end

  @doc "Deletes every spool of this boot."
  @spec delete_all() :: :ok
  # The dir is the configured spool root + boot id; never user input.
  # sobelow_skip ["Traversal.FileModule"]
  def delete_all do
    File.rm_rf(boot_dir())
    :ok
  end

  @doc """
  Deletes spools left by earlier boots of this node (never another node's).
  Returns how many were removed.
  """
  @spec janitor() :: non_neg_integer()
  # Entries are listed from this node's spool root itself; never user input.
  # sobelow_skip ["Traversal.FileModule"]
  def janitor do
    root = node_dir()
    current = Executions.boot_id()

    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == current))
        |> Enum.count(fn entry -> match?({:ok, _}, File.rm_rf(Path.join(root, entry))) end)

      {:error, _reason} ->
        0
    end
  end

  @doc """
  Deletes this boot's session spools that no live local coordinator owns:
  the session is unknown or ended, or its `owner_id` is not registered on
  this node. Returns how many were removed.
  """
  @spec sweep() :: non_neg_integer()
  # Entries are listed from this boot's spool root itself; never user input.
  # sobelow_skip ["Traversal.FileModule"]
  def sweep do
    case File.ls(boot_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&owned_here?/1)
        |> Enum.count(fn entry -> match?({:ok, _}, File.rm_rf(Path.join(boot_dir(), entry))) end)

      {:error, _reason} ->
        0
    end
  end

  defp owned_here?(entry) do
    with {:ok, id} <- Ecto.UUID.cast(entry),
         %Session{status: status, owner_id: owner_id} when status in ["waiting", "active"] <-
           Repo.get(Session, id) do
      Executions.local_owner?(owner_id) and Executions.lookup(owner_id) != :error
    else
      _ -> false
    end
  end

  @doc """
  Reserves `bytes` of the node budget for `account_id`, held by `holder`
  (default the caller). `kind` is `:upload` (default; also takes one of the
  account's concurrent upload slots) or `:report`. `{:error, :busy}` when
  the node budget, the account's byte share, or its upload slots are
  exhausted.
  """
  @spec reserve(term(), pos_integer(), pid(), :upload | :report) ::
          {:ok, reference()} | {:error, :busy}
  def reserve(account_id, bytes, holder \\ self(), kind \\ :upload)
      when kind in [:upload, :report] do
    GenServer.call(
      __MODULE__,
      {:reserve, holder, account_id, bytes, kind,
       %{
         budget: Config.spool_max_bytes(),
         account_bytes: Config.spool_account_max_bytes(),
         account_uploads: Config.workspace_max_concurrent_uploads_per_account()
       }}
    )
  catch
    :exit, _reason -> {:error, :busy}
  end

  @doc """
  Marks a reservation as finished with `actual_bytes` on disk: its
  reservation shrinks (or grows) to that size, and an upload no longer
  counts against the account's concurrent upload cap. The spooled file
  stays until the reservation is released.
  """
  @spec settle(reference(), non_neg_integer()) :: :ok
  def settle(ref, actual_bytes) when is_integer(actual_bytes) and actual_bytes >= 0,
    do: GenServer.cast(__MODULE__, {:settle, ref, actual_bytes})

  @doc "Releases a reservation. Releasing twice is harmless."
  @spec release(reference()) :: :ok
  def release(ref), do: GenServer.cast(__MODULE__, {:release, ref})

  @doc "Bytes currently reserved on this node."
  @spec reserved_bytes() :: non_neg_integer()
  def reserved_bytes, do: GenServer.call(__MODULE__, :reserved_bytes)

  @doc "Bytes currently reserved on this node for `account_id`."
  @spec reserved_bytes(term()) :: non_neg_integer()
  def reserved_bytes(account_id), do: GenServer.call(__MODULE__, {:reserved_bytes, account_id})

  @impl GenServer
  def init(:ok) do
    janitor()
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:ok, %{holders: %{}, bytes: 0, accounts: %{}, uploads: %{}}}
  end

  @impl GenServer
  def handle_call({:reserve, pid, account, bytes, kind, limits}, _from, state) do
    uploading = kind == :upload

    if state.bytes + bytes > limits.budget or
         Map.get(state.accounts, account, 0) + bytes > limits.account_bytes or
         (uploading and Map.get(state.uploads, account, 0) >= limits.account_uploads) do
      {:reply, {:error, :busy}, state}
    else
      ref = Process.monitor(pid)
      holder = %{account: account, bytes: bytes, uploading: uploading}

      state = %{
        holders: Map.put(state.holders, ref, holder),
        bytes: state.bytes + bytes,
        accounts: Map.update(state.accounts, account, bytes, &(&1 + bytes)),
        uploads:
          if(uploading,
            do: Map.update(state.uploads, account, 1, &(&1 + 1)),
            else: state.uploads
          )
      }

      {:reply, {:ok, ref}, state}
    end
  end

  def handle_call(:reserved_bytes, _from, state), do: {:reply, state.bytes, state}

  def handle_call({:reserved_bytes, account}, _from, state),
    do: {:reply, Map.get(state.accounts, account, 0), state}

  @impl GenServer
  def handle_cast({:settle, ref, actual}, state) do
    case Map.fetch(state.holders, ref) do
      {:ok, holder} ->
        delta = actual - holder.bytes

        uploads =
          if holder.uploading, do: decrement(state.uploads, holder.account), else: state.uploads

        {:noreply,
         %{
           holders: Map.put(state.holders, ref, %{holder | bytes: actual, uploading: false}),
           bytes: state.bytes + delta,
           accounts: adjust(state.accounts, holder.account, delta),
           uploads: uploads
         }}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, drop(state, ref)}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state), do: {:noreply, drop(state, ref)}

  def handle_info(:sweep, state) do
    try do
      sweep()
    rescue
      error -> Logger.warning("Pools: spool sweep failed: #{Exception.message(error)}")
    end

    Process.send_after(self(), :sweep, @sweep_interval_ms)
    {:noreply, state}
  end

  defp drop(state, ref) do
    case Map.pop(state.holders, ref) do
      {nil, _holders} ->
        state

      {holder, holders} ->
        uploads =
          if holder.uploading, do: decrement(state.uploads, holder.account), else: state.uploads

        %{
          holders: holders,
          bytes: state.bytes - holder.bytes,
          accounts: adjust(state.accounts, holder.account, -holder.bytes),
          uploads: uploads
        }
    end
  end

  defp adjust(map, key, delta) do
    case Map.get(map, key, 0) + delta do
      total when total <= 0 -> Map.delete(map, key)
      total -> Map.put(map, key, total)
    end
  end

  defp decrement(map, key) do
    case Map.get(map, key, 0) do
      count when count <= 1 -> Map.delete(map, key)
      count -> Map.put(map, key, count - 1)
    end
  end
end
