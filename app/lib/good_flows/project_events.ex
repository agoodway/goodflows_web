defmodule GoodFlows.ProjectEvents do
  @moduledoc """
  The per-project event feed (the `project-events` capability): an
  append-only log of change request activity with a keyset cursor and an
  optional long-poll.

  `record/5` inserts an event inside the caller's transaction, so a change
  that rolls back leaves no event. It first takes a per-project
  transaction-level advisory lock, held until commit, so event `id`s of a
  project are handed out in commit order: once a reader has seen an event,
  every event committed later has a higher `id` and `after` never skips
  one. It then sends `pg_notify`, which Postgres delivers only on commit;
  `GoodFlows.ProjectEvents.Listener` turns it into a local PubSub
  broadcast on `topic/1`.

  `read/3` returns the events after a cursor and, when there are none and
  `wait` is positive, subscribes to the project's topic and waits (holding
  no database connection) until an event commits or `wait` seconds pass,
  then reads again. Each node allows at most
  `config :good_flows, :project_events_max_waiters_per_account` (default
  20) waiting reads per account; a read over the limit is answered as
  if `wait` were 0.

  `sweep/1` deletes events older than 90 days and records the highest
  deleted `id` per project in `projects.events_deleted_through`; a read
  whose `after` is below it is `{:error, {:gone, latest_cursor}}`.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.ProjectEvents.{Event, Listener}
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo

  @types ~w(cr_state_changed verdict_changed scenario_set_uploaded scenario_set_approved
            scenario_set_rejected answer_recorded task_created policy_version_created)
  @default_limit 100
  @max_limit 200
  @max_wait 30
  @default_max_waiters 20
  @retention_days 90
  @waiters GoodFlows.ProjectEvents.Waiters

  @typedoc "One page of events."
  @type page :: %{events: [Event.t()], next_cursor: non_neg_integer() | nil}

  @doc "The event types."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The PubSub topic of a project's committed events."
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(project_id), do: "project_events:" <> project_id

  @doc "The registry of waiting reads (a child of the application)."
  @spec waiters() :: atom()
  def waiters, do: @waiters

  @doc """
  Inserts an event of `type` for the project inside the caller's
  transaction. `number` is the change request number or nil; `api_key`
  (with its membership) is the actor, or nil for a server-made event.

  Lock order: call it after the transaction's change request row locks.
  It takes the per-project event advisory lock, held until commit, so a
  caller that locks change requests after it can deadlock with another
  writer. The insert's foreign key check also takes `FOR KEY SHARE` on
  the project row, so a transaction that locks the project row and then
  change request rows must use `FOR NO KEY UPDATE`, never `FOR UPDATE`.
  """
  @spec record(Ecto.UUID.t(), pos_integer() | nil, String.t(), map(), ApiKey.t() | nil) ::
          Event.t()
  def record(project_id, number, type, data, api_key) when type in @types do
    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('project_events:' || $1, 0))",
      [project_id],
      log: false
    )

    event =
      Repo.insert!(
        %Event{
          project_id: project_id,
          change_request_number: number,
          type: type,
          data: data,
          actor_membership_id: api_key && api_key.account_user_id,
          actor_key_id: api_key && api_key.id,
          inserted_at: DateTime.utc_now()
        },
        log: false
      )

    Repo.query!("SELECT pg_notify($1, $2)", [Listener.channel(), project_id], log: false)
    event
  end

  @doc """
  Reads one page of the project's events, oldest first. Params: `"after"`
  (an event `id`), `"limit"` (1 to #{@max_limit}, default
  #{@default_limit}) and `"wait"` (0 to #{@max_wait} seconds, default 0).
  `account_id` is counted against the waiter limit. Returns a changeset
  for bad params and `{:error, {:gone, latest_cursor}}` when events after
  `after` were deleted by retention.
  """
  @spec read(Project.t(), Ecto.UUID.t(), map()) ::
          {:ok, page()}
          | {:error, Ecto.Changeset.t() | {:gone, non_neg_integer() | nil}}
  def read(%Project{id: project_id}, account_id, params) do
    with {:ok, params} <- read_params(params),
         :ok <- check_retention(project_id, params.cursor) do
      case fetch(project_id, params) do
        %{events: []} when params.wait > 0 -> {:ok, wait(project_id, account_id, params)}
        page -> {:ok, page}
      end
    end
  end

  defp read_params(params) do
    types = %{after: :integer, limit: :integer, wait: :integer}

    {%{after: nil, limit: @default_limit, wait: 0}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types), empty_values: [])
    |> Ecto.Changeset.validate_number(:after, greater_than_or_equal_to: 0)
    |> Ecto.Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_limit
    )
    |> Ecto.Changeset.validate_number(:wait,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @max_wait
    )
    |> Ecto.Changeset.apply_action(:read)
    |> case do
      {:ok, params} ->
        {:ok, %{cursor: Map.fetch!(params, :after), limit: params.limit, wait: params.wait}}

      error ->
        error
    end
  end

  defp check_retention(_project_id, nil), do: :ok

  defp check_retention(project_id, cursor) do
    deleted =
      Repo.one(from p in Project, where: p.id == ^project_id, select: p.events_deleted_through)

    if deleted != nil and cursor < deleted,
      do: {:error, {:gone, latest_cursor(project_id)}},
      else: :ok
  end

  defp latest_cursor(project_id),
    do: Repo.one(from e in Event, where: e.project_id == ^project_id, select: max(e.id))

  defp fetch(project_id, params) do
    events =
      Event
      |> where(project_id: ^project_id)
      |> then(&if params.cursor, do: where(&1, [e], e.id > ^params.cursor), else: &1)
      |> order_by(asc: :id)
      |> limit(^params.limit)
      |> preload(:actor_membership)
      |> Repo.all()

    next = if events == [], do: params.cursor, else: List.last(events).id
    %{events: events, next_cursor: next}
  end

  # Subscribes before registering as a waiter and reading again, so an
  # event committed after the first read is never missed.
  defp wait(project_id, account_id, params) do
    Phoenix.PubSub.subscribe(GoodFlows.PubSub, topic(project_id))
    waiter? = acquire_waiter(account_id)

    try do
      case fetch(project_id, params) do
        %{events: []} when waiter? ->
          receive do
            {:project_event, ^project_id} -> :ok
          after
            params.wait * 1_000 -> :ok
          end

          fetch(project_id, params)

        page ->
          page
      end
    after
      Phoenix.PubSub.unsubscribe(GoodFlows.PubSub, topic(project_id))
      if waiter?, do: Registry.unregister(@waiters, account_id)
      flush(project_id)
    end
  end

  # A keep-alive connection reuses its process for the next request.
  defp flush(project_id) do
    receive do
      {:project_event, ^project_id} -> flush(project_id)
    after
      0 -> :ok
    end
  end

  defp acquire_waiter(account_id) do
    limit =
      Application.get_env(
        :good_flows,
        :project_events_max_waiters_per_account,
        @default_max_waiters
      )

    {:ok, _owner} = Registry.register(@waiters, account_id, nil)

    if Registry.count_match(@waiters, account_id, :_) > limit do
      Registry.unregister(@waiters, account_id)
      false
    else
      true
    end
  end

  @doc """
  Deletes events inserted more than #{@retention_days} days before `now`
  and raises each affected project's `events_deleted_through` to the
  highest deleted `id`. Returns the number deleted.
  """
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days, :day)

    %{rows: [[count]]} =
      Repo.query!(
        """
        WITH deleted AS (
          DELETE FROM project_events WHERE inserted_at < $1 RETURNING project_id, id
        ), per_project AS (
          SELECT project_id, max(id) AS through FROM deleted GROUP BY project_id
        ), updated AS (
          UPDATE projects p
          SET events_deleted_through = GREATEST(COALESCE(p.events_deleted_through, 0), pp.through)
          FROM per_project pp WHERE p.id = pp.project_id
          RETURNING p.id
        )
        SELECT count(*) FROM deleted
        """,
        [cutoff],
        log: false
      )

    count
  end
end
