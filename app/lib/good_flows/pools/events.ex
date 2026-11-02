defmodule GoodFlows.Pools.Events do
  @moduledoc """
  PubSub topics and broadcasts for pools (`GoodFlows.PubSub`).

    * `"pool_session:<id>"` - session events pushed to joined clients:
      `member_granted`, `member_ready`, `member_lost`, `session_ended`, and
      exec `exit`s that must precede `session_ended`
    * `"pool_exec:<id>"` - one exec's `output`, `exit` events
    * `"pools:reconcile"` - nudges for `GoodFlows.Pools.Reconciler`
  """

  @pubsub GoodFlows.PubSub
  @reconcile_topic "pools:reconcile"

  @doc "The session channel topic."
  @spec session_topic(Ecto.UUID.t()) :: String.t()
  def session_topic(session_id), do: "pool_session:#{session_id}"

  @doc "The exec output topic."
  @spec exec_topic(Ecto.UUID.t()) :: String.t()
  def exec_topic(exec_id), do: "pool_exec:#{exec_id}"

  @doc "The reconciler nudge topic."
  @spec reconcile_topic() :: String.t()
  def reconcile_topic, do: @reconcile_topic

  @doc "Broadcasts a session event `{:pool_session_event, event, payload}`."
  @spec session_event(Ecto.UUID.t(), String.t(), map()) :: :ok
  def session_event(session_id, event, payload) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      session_topic(session_id),
      {:pool_session_event, event, payload}
    )
  end

  @doc "Broadcasts an exec event `{:pool_exec_event, event, payload}`."
  @spec exec_event(Ecto.UUID.t(), String.t(), map()) :: :ok
  def exec_event(exec_id, event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, exec_topic(exec_id), {:pool_exec_event, event, payload})
  end

  @doc "Asks the reconciler to look at `pool_id` (or every pool) soon."
  @spec nudge(Ecto.UUID.t() | :all) :: :ok
  def nudge(pool_id \\ :all),
    do: Phoenix.PubSub.broadcast(@pubsub, @reconcile_topic, {:pools_nudge, pool_id})

  @doc "Subscribes the caller to `topic`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  @doc "Unsubscribes the caller from `topic`."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)
end
