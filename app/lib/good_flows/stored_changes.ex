defmodule GoodFlows.StoredChanges do
  @moduledoc """
  Goodflows changes stored per project (the `stored-changes` capability):
  a mirror of each `goodflows/changes/<id>/` directory the CLI pushes,
  with every pushed version kept until the change is deleted.

  `push/3` validates a body (`GoodFlows.StoredChanges.Push`) and stores
  the change's next version, or answers `:duplicate` when the paths and
  every file's bytes equal the latest version's. A change whose latest
  version is `archived` takes no other push. A push that stores a version
  records a `change_pushed` project event, and a delete a
  `change_deleted` event.

  Pushes and deletes of an id take the change request lock of that
  (project, change id) (`GoodFlows.ChangeRequests.lock_change_id/2`), so
  concurrent pushes get consecutive versions and a delete sees every
  change request linking the id that committed before it. A delete is
  refused while any change request of the project links the id.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.ChangeRequests
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.DocumentErrors
  alias GoodFlows.KeysetCursor
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.Review
  alias GoodFlows.StoredChanges.{Change, Push, Version}

  @default_page_size 50
  @max_page_size 200
  @cursor ~r/\Av1:([0-9]{1,19}):([a-z0-9][a-z0-9-]{0,63})\z/

  @typedoc "A change request linking a stored change."
  @type link :: %{number: pos_integer(), state: String.t()}

  @doc """
  Stores a push from a normalized body. Returns `{:ok, :created, version,
  replaced}` with `replaced` the previous latest version number (nil for
  a new change), `{:ok, :duplicate, latest, latest_number}`, or an error:
  `{:invalid_body, errors}`, `{:stored_change_archived, change_id}` or
  `:not_found` (the project was deleted).
  """
  @spec push(Project.t(), ApiKey.t(), term()) ::
          {:ok, :created | :duplicate, Version.t(), pos_integer() | nil}
          | {:error,
             :not_found
             | {:invalid_body, DocumentErrors.errors()}
             | {:stored_change_archived, String.t()}}
  def push(%Project{} = project, %ApiKey{} = api_key, body) do
    with {:ok, push} <- Push.validate(body) do
      Repo.transaction(fn -> push_locked(project, api_key, push) end)
      |> case do
        {:ok, {status, version, replaced}} -> {:ok, status, version, replaced}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp push_locked(project, api_key, push) do
    ChangeRequests.lock_change_id(project.id, push.change_id)
    lock_project(project)

    case Repo.get_by(Change, project_id: project.id, change_id: push.change_id) do
      nil ->
        change = %Change{project_id: project.id, change_id: push.change_id, latest_version: 0}
        {:created, insert_version(change, api_key, push), nil}

      %Change{} = change ->
        latest =
          Repo.get_by!(Version, stored_change_id: change.id, version: change.latest_version)

        cond do
          latest.digest == push.digest ->
            {:duplicate, preload(%{latest | stored_change: change}), latest.version}

          change.status == "archived" ->
            Repo.rollback({:stored_change_archived, change.change_id})

          true ->
            {:created, insert_version(change, api_key, push), latest.version}
        end
    end
  end

  defp lock_project(project) do
    query = from p in Project, where: p.id == ^project.id, lock: "FOR KEY SHARE", select: p.id
    if Repo.one(query) == nil, do: Repo.rollback(:not_found)
  end

  defp insert_version(change, api_key, push) do
    now = DateTime.utc_now()
    number = change.latest_version + 1

    listed = %{
      latest_version: number,
      status: push.status,
      size: push.size,
      door: push.door,
      capabilities: push.capabilities,
      depends_on: push.depends_on,
      last_pushed_at: now
    }

    change =
      if change.id,
        do: change |> Ecto.Changeset.change(listed) |> Repo.update!(),
        else: change |> struct(listed) |> Map.put(:inserted_at, now) |> Repo.insert!()

    version =
      Repo.insert!(
        %Version{
          stored_change_id: change.id,
          version: number,
          status: push.status,
          size: push.size,
          door: push.door,
          capabilities: push.capabilities,
          depends_on: push.depends_on,
          files: push.files,
          digest: push.digest,
          commit: push.source.commit,
          branch: push.source.branch,
          dirty: push.source.dirty,
          account_user_id: api_key.account_user_id,
          api_key_id: api_key.id,
          inserted_at: now
        },
        log: false
      )

    ProjectEvents.record(
      change.project_id,
      nil,
      "change_pushed",
      %{"change_id" => change.change_id, "version" => number},
      Review.cli_actor(api_key)
    )

    preload(%{version | stored_change: change})
  end

  defp preload(version), do: Repo.preload(version, :account_user)

  @doc """
  One page of the project's stored changes, newest latest push first and
  then by id. Params: `"limit"` (1 to #{@max_page_size}, default
  #{@default_page_size}), `"cursor"` and `"status"` (matched against the
  latest version). `change_requests` maps each listed id to its linked
  change requests, by number; an id with none is absent.
  """
  @spec list(Project.t(), map()) ::
          {:ok,
           %{
             changes: [Change.t()],
             change_requests: %{String.t() => [%{number: pos_integer(), state: String.t()}]},
             next_cursor: String.t() | nil
           }}
          | {:error, Ecto.Changeset.t()}
  def list(%Project{id: project_id}, params) do
    with {:ok, params} <- list_params(params) do
      changes =
        Change
        |> where(project_id: ^project_id)
        |> then(&if params.status, do: where(&1, status: ^params.status), else: &1)
        |> after_cursor(params.cursor)
        |> order_by([c], desc: c.last_pushed_at, asc: c.change_id)
        |> limit(^(params.limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(changes, params.limit)
      next = if rest != [], do: encode_cursor(List.last(page))
      {:ok, %{changes: page, change_requests: page_links(project_id, page), next_cursor: next}}
    end
  end

  defp list_params(params) do
    types = %{limit: :integer, cursor: :string, status: :string}

    {%{limit: @default_page_size, cursor: nil, status: nil}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types), empty_values: [])
    |> Ecto.Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_page_size
    )
    |> Ecto.Changeset.validate_inclusion(:status, Push.statuses())
    |> KeysetCursor.put_cursor(&decode_cursor/1)
    |> Ecto.Changeset.apply_action(:list)
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {at, change_id}) do
    where(
      query,
      [c],
      c.last_pushed_at < ^at or (c.last_pushed_at == ^at and c.change_id > ^change_id)
    )
  end

  defp encode_cursor(%Change{last_pushed_at: at, change_id: change_id}),
    do: Base.url_encode64("v1:#{DateTime.to_unix(at, :microsecond)}:#{change_id}", padding: false)

  defp decode_cursor(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [_all, micros, change_id] <- Regex.run(@cursor, decoded),
         {:ok, at} <- DateTime.from_unix(String.to_integer(micros), :microsecond) do
      {:ok, {at, change_id}}
    else
      _other -> :error
    end
  end

  @doc """
  The stored change `change_id` with its latest version and the change
  requests of the project linking it, or `:not_found`.
  """
  @spec get(Project.t(), String.t()) ::
          {:ok, %{version: Version.t(), change_requests: [link()]}} | {:error, :not_found}
  def get(%Project{} = project, change_id) do
    with {:ok, change} <- fetch(project, change_id) do
      version =
        Version
        |> Repo.get_by!(stored_change_id: change.id, version: change.latest_version)
        |> Map.put(:stored_change, change)
        |> preload()

      {:ok, %{version: version, change_requests: links(project.id, change_id)}}
    end
  end

  @doc """
  Version `number` of the stored change `change_id`: `:not_found` when
  there is no such change, `:version_not_found` when it has no such version.
  """
  @spec get_version(Project.t(), String.t(), pos_integer()) ::
          {:ok, Version.t()} | {:error, :not_found | :version_not_found}
  def get_version(%Project{} = project, change_id, number) do
    with {:ok, change} <- fetch(project, change_id) do
      case Repo.get_by(Version, stored_change_id: change.id, version: number) do
        nil -> {:error, :version_not_found}
        version -> {:ok, preload(%{version | stored_change: change})}
      end
    end
  end

  @doc """
  One page of the stored change's versions, newest first, each with its
  `stored_change`. Params: `"limit"` (1 to #{@max_page_size}, default
  #{@default_page_size}) and `"cursor"`.
  """
  @spec list_versions(Project.t(), String.t(), map()) ::
          {:ok, %{versions: [Version.t()], next_cursor: String.t() | nil}}
          | {:error, :not_found | Ecto.Changeset.t()}
  def list_versions(%Project{} = project, change_id, params) do
    with {:ok, change} <- fetch(project, change_id),
         {:ok, %{limit: limit, cursor: cursor}} <-
           KeysetCursor.integer_page_params(params, @default_page_size, @max_page_size) do
      versions =
        Version
        |> where(stored_change_id: ^change.id)
        |> then(&if cursor, do: where(&1, [v], v.version < ^cursor), else: &1)
        |> order_by(desc: :version)
        |> limit(^(limit + 1))
        |> preload(:account_user)
        |> Repo.all()
        |> Enum.map(&%{&1 | stored_change: change})

      {page, rest} = Enum.split(versions, limit)
      next = if rest != [], do: KeysetCursor.encode_integer(List.last(page).version)
      {:ok, %{versions: page, next_cursor: next}}
    end
  end

  @doc """
  Deletes the stored change `change_id` and every version. Returns `:ok`,
  `{:error, :not_found}`, or `{:error, {:stored_change_linked, links}}`
  while any change request of the project, in any state, links the id.
  """
  @spec delete(Project.t(), ApiKey.t(), String.t()) ::
          :ok | {:error, :not_found | {:stored_change_linked, [link()]}}
  def delete(%Project{} = project, %ApiKey{} = api_key, change_id) do
    Repo.transaction(fn ->
      ChangeRequests.lock_change_id(project.id, change_id)

      with {:ok, change} <- fetch(project, change_id),
           [] <- links(project.id, change_id) do
        Repo.delete!(change)

        ProjectEvents.record(
          project.id,
          nil,
          "change_deleted",
          %{"change_id" => change_id},
          Review.cli_actor(api_key)
        )
      else
        {:error, :not_found} -> Repo.rollback(:not_found)
        links -> Repo.rollback({:stored_change_linked, links})
      end
    end)
    |> case do
      {:ok, _event} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(%Project{id: project_id}, change_id) when is_binary(change_id) do
    case Repo.get_by(Change, project_id: project_id, change_id: change_id) do
      nil -> {:error, :not_found}
      change -> {:ok, change}
    end
  end

  # One query for the whole page: change id => [%{number, state}] by number.
  defp page_links(_project_id, []), do: %{}

  defp page_links(project_id, changes) do
    ids = Enum.map(changes, & &1.change_id)

    Repo.all(
      from c in ChangeRequest,
        where: c.project_id == ^project_id and c.change_id in ^ids,
        order_by: [c.change_id, c.number],
        select: {c.change_id, %{number: c.number, state: c.state}}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp links(project_id, change_id) do
    Repo.all(
      from c in ChangeRequest,
        where: c.project_id == ^project_id and c.change_id == ^change_id,
        order_by: c.number,
        select: %{number: c.number, state: c.state}
    )
  end
end
