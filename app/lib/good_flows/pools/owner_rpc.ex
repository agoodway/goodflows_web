defmodule GoodFlows.Pools.OwnerRPC do
  @moduledoc """
  Bounded calls to a session coordinator (or exec server) by its owner id.

  Owner ids are `"<node>|<boot_id>|<uuid>"` (`GoodFlows.Spry.Executions`).
  A call on the owner's node goes straight to the registered process; a
  call from another node goes through `:erpc` with a deadline, and the
  remote side checks the boot id, so a restarted node never answers for
  its previous incarnation. The captured Sprites credential never leaves
  the owner's node: requests carry data, never clients.

  `status/1` distinguishes a confirmed loss (`:lost`: the owner id is
  malformed, or its node answered that the owner is not registered there
  or belongs to an earlier boot) from an unreachable owner (`:unknown`),
  which is never proof of death. An owner on a node this VM has never seen
  (no atom exists for its name yet, as on a freshly booted node that has
  not joined the cluster) is unreachable, not lost.
  """

  alias GoodFlows.Pools.Config
  alias GoodFlows.Spry.Executions

  @type error :: {:error, :owner_lost | :owner_unavailable}

  @doc "Calls the owner with `request`. Never raises."
  @spec call(String.t() | nil, term(), timeout()) :: term() | error()
  def call(owner_id, request, timeout \\ Config.owner_rpc_timeout_ms()) do
    case Executions.owner_location(owner_id) do
      # Malformed: no node can ever own it.
      {nil, nil} ->
        {:error, :owner_lost}

      # A node this VM has never heard of: unreachable, not dead.
      {nil, _boot} ->
        {:error, :owner_unavailable}

      {node, _boot} when node == node() ->
        local_call(owner_id, request, timeout)

      {node, _boot} ->
        remote().(node, __MODULE__, :local_call, [owner_id, request, timeout], timeout + 1_000)
    end
  catch
    :exit, _reason -> {:error, :owner_unavailable}
    :error, _reason -> {:error, :owner_unavailable}
  end

  @doc "Sends `message` to the owner without waiting. Best effort."
  @spec cast(String.t() | nil, term()) :: :ok
  def cast(owner_id, message) do
    _ = call(owner_id, {:__cast__, message}, Config.owner_rpc_timeout_ms())
    :ok
  end

  @doc """
  Delivers `request` to the owner registered on this node, after checking
  that `owner_id` belongs to this node's current boot. Runs on the owner's
  node: `call/3` invokes it remotely through `:erpc`, so it must stay
  public. `{:__cast__, message}` is cast; anything else is called with
  `timeout`.
  """
  @spec local_call(String.t(), term(), timeout()) :: term() | error()
  def local_call(owner_id, request, timeout) do
    with true <- Executions.local_owner?(owner_id),
         {:ok, pid} <- Executions.lookup(owner_id) do
      case request do
        {:__cast__, message} ->
          GenServer.cast(pid, message)
          :ok

        request ->
          GenServer.call(pid, request, timeout)
      end
    else
      _ -> {:error, :owner_lost}
    end
  catch
    :exit, {:noproc, _} -> {:error, :owner_lost}
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @doc """
  `:alive`, `:lost` (confirmed), or `:unknown` (unreachable: not proof of
  death).
  """
  @spec status(String.t() | nil) :: :alive | :lost | :unknown
  def status(owner_id) do
    case call(owner_id, :ping) do
      :pong -> :alive
      {:error, :owner_lost} -> :lost
      _other -> :unknown
    end
  end

  @doc """
  Like `status/1` but only checks the owner's registration on its node,
  without messaging the owner process (for job workers, which are not
  servers).
  """
  @spec probe(String.t() | nil) :: :alive | :lost | :unknown
  def probe(owner_id) do
    owner_id
    |> registered_on_owner_node?()
    |> liveness()
  catch
    _kind, _reason -> :unknown
  end

  defp registered_on_owner_node?(owner_id) do
    case Executions.owner_location(owner_id) do
      {nil, nil} ->
        false

      # A node this VM has never heard of: unreachable, not dead.
      {nil, _boot} ->
        :unreachable

      {node, _boot} when node == node() ->
        registered?(owner_id)

      {node, _boot} ->
        remote().(node, __MODULE__, :registered?, [owner_id], Config.owner_rpc_timeout_ms())
    end
  end

  defp liveness(true), do: :alive
  defp liveness(false), do: :lost
  # Unreachable, or a non-boolean answer: not proof of death.
  defp liveness(_other), do: :unknown

  @doc """
  Whether `owner_id` belongs to this node's current boot and is registered
  here. Runs on the owner's node: `probe/1` invokes it remotely through
  `:erpc`, so it must stay public.
  """
  @spec registered?(String.t()) :: boolean()
  def registered?(owner_id),
    do: Executions.local_owner?(owner_id) and Executions.lookup(owner_id) != :error

  # `:erpc.call/5`; replaceable in tests to exercise cross-node routing.
  defp remote, do: Application.get_env(:good_flows, :pools_remote_call, &:erpc.call/5)
end
