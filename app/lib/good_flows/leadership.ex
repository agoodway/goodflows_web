defmodule GoodFlows.Leadership do
  @moduledoc """
  Cluster-wide single-leader election through `:global`, shared by the
  periodic schedulers (`GoodFlows.Spry.ReaperScheduler` and
  `GoodFlows.Pools.Reconciler`).

  A leader registers `name` with `:global.random_notify_name/3`: after a
  healed netsplit, `:global` keeps the name for one contender (chosen at
  random) and unregisters the other, which receives
  `{:global_name_conflict, name}`; its next claim finds the name taken.
  """

  @doc """
  Whether the calling process leads `name`: true when it is already
  registered under `name`, or when the name is free and registering it
  succeeds; false when another process holds it.
  """
  @spec claim(term()) :: boolean()
  def claim(name) do
    case :global.whereis_name(name) do
      pid when pid == self() ->
        true

      :undefined ->
        :global.register_name(name, self(), &:global.random_notify_name/3) == :yes

      _other ->
        false
    end
  end

  @doc "Gives up `name` if the calling process holds it."
  @spec release(term()) :: :ok
  def release(name) do
    if :global.whereis_name(name) == self(), do: :global.unregister_name(name)
    :ok
  end
end
