defmodule GoodFlows.Pools do
  @moduledoc """
  Project-scoped pools of pre-built Sprite VMs.

  Every function takes the owning account and the URL's project; a pool of
  another project or account, or one being deleted, is `:not_found`. Pools
  are addressed by slug.

  Creating or replacing a pool validates the body first, then requires the
  account's Sprites credential. A replacement that changes `setup` bumps
  `setup_version` (members built from an older version become stale) and
  clears the provisioning failure streak; changing only `min_ready` or
  `max_members` does not.

  Deleting a pool takes the same row lock as session creation and grants:
  with any `waiting` or `active` session it is refused (`:pool_in_use`);
  otherwise it is marked `deleting_at`, becomes invisible, and
  `GoodFlows.Pools.Reconciler` destroys its members before removing the row.

  Member lifecycle, sessions, and execs live in `GoodFlows.Pools.Members`,
  `GoodFlows.Pools.Sessions`, and `GoodFlows.Pools.Execs`.
  """
  import Ecto.Query

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Pools.{Config, Credentials, Events, Member, Pool, Session}
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo

  @doc "Lists the project's pools, ordered by slug, with member counts and status."
  @spec list_pools(Account.t(), Project.t()) :: [Pool.t()]
  def list_pools(%Account{id: account_id}, %Project{id: project_id} = project) do
    Pool
    |> where([p], p.account_id == ^account_id and p.project_id == ^project_id)
    |> where([p], is_nil(p.deleting_at))
    |> order_by([p], asc: p.slug)
    |> Repo.all()
    |> with_stats(project)
  end

  @doc "Fetches one of the project's pools by slug, with member counts and status."
  @spec get_pool(Account.t(), Project.t(), term()) :: {:ok, Pool.t()} | {:error, :not_found}
  def get_pool(%Account{} = account, %Project{} = project, slug) do
    case fetch_pool(account, project, slug) do
      {:ok, pool} -> {:ok, pool |> List.wrap() |> with_stats(project) |> hd()}
      error -> error
    end
  end

  @doc "Fetches a visible pool by slug without stats (`lock: true` locks the row)."
  @spec fetch_pool(Account.t(), Project.t(), term(), keyword()) ::
          {:ok, Pool.t()} | {:error, :not_found}
  def fetch_pool(%Account{id: account_id}, %Project{id: project_id}, slug, opts \\ []) do
    query =
      Pool
      |> where([p], p.account_id == ^account_id and p.project_id == ^project_id)
      |> where([p], p.slug == ^to_string(slug) and is_nil(p.deleting_at))

    query = if opts[:lock], do: lock(query, "FOR UPDATE"), else: query

    case is_binary(slug) && Repo.one(query) do
      %Pool{} = pool -> {:ok, pool}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Creates a pool. The body is validated before the credential check, so an
  invalid body reports its own errors even without a credential.
  """
  @spec create_pool(Account.t(), Project.t(), map()) ::
          {:ok, Pool.t()}
          | {:error, Ecto.Changeset.t() | {:unprocessable, String.t()} | :not_found}
  def create_pool(
        %Account{id: account_id} = account,
        %Project{account_id: account_id} = project,
        attrs
      ) do
    changeset = Pool.changeset(%Pool{account_id: account_id, project_id: project.id}, attrs)

    with :ok <- valid_or_error(changeset),
         :ok <- require_credential(account_id),
         {:ok, pool} <- Repo.insert(changeset) do
      Events.nudge(pool.id)
      get_pool(account, project, pool.slug)
    end
  end

  def create_pool(%Account{}, %Project{}, _attrs), do: {:error, :not_found}

  @doc """
  Replaces a pool wholesale. The body's `slug` must equal `slug` (pools are
  never renamed). Holds the pool row lock so a provisioning admission sees
  either the old or the new setup.
  """
  @spec replace_pool(Account.t(), Project.t(), term(), map()) ::
          {:ok, Pool.t()}
          | {:error, Ecto.Changeset.t() | {:unprocessable, String.t()} | :not_found}
  def replace_pool(%Account{} = account, %Project{} = project, slug, attrs) do
    Repo.transact(fn ->
      with {:ok, pool} <- fetch_pool(account, project, slug, lock: true),
           changeset = pool |> Pool.changeset(attrs) |> validate_same_slug(pool.slug),
           :ok <- valid_or_error(changeset),
           :ok <- require_credential(account.id) do
        changeset
        |> bump_setup_version(pool)
        |> Repo.update()
      end
    end)
    |> case do
      {:ok, pool} ->
        Events.nudge(pool.id)
        get_pool(account, project, pool.slug)

      error ->
        error
    end
  end

  defp validate_same_slug(changeset, slug) do
    if Ecto.Changeset.get_field(changeset, :slug) == slug,
      do: changeset,
      else:
        Ecto.Changeset.add_error(
          changeset,
          :slug,
          "must equal the pool slug in the URL; pools cannot be renamed"
        )
  end

  defp bump_setup_version(changeset, %Pool{setup: old_setup, setup_version: version}) do
    if Ecto.Changeset.get_field(changeset, :setup) == old_setup do
      changeset
    else
      Ecto.Changeset.change(changeset,
        setup_version: version + 1,
        provision_failures: 0,
        next_provision_at: nil,
        last_provision_error: nil
      )
    end
  end

  defp valid_or_error(%Ecto.Changeset{valid?: true}), do: :ok
  defp valid_or_error(changeset), do: {:error, %{changeset | action: :validate}}

  defp require_credential(account_id) do
    if Credentials.configured?(account_id),
      do: :ok,
      else:
        {:error, {:unprocessable, Credentials.missing_message("creating or replacing a pool")}}
  end

  @doc """
  Marks a pool for deletion unless it has a `waiting` or `active` session.
  Its members are destroyed and its row removed in the background.
  """
  @spec delete_pool(Account.t(), Project.t(), term()) :: :ok | {:error, :not_found | :pool_in_use}
  def delete_pool(%Account{} = account, %Project{} = project, slug) do
    Repo.transact(fn ->
      with {:ok, pool} <- fetch_pool(account, project, slug, lock: true),
           :ok <- ensure_no_open_session(pool) do
        pool
        |> Ecto.Changeset.change(deleting_at: DateTime.utc_now())
        |> Repo.update()
      end
    end)
    |> case do
      {:ok, pool} ->
        Events.nudge(pool.id)
        :ok

      error ->
        error
    end
  end

  defp ensure_no_open_session(%Pool{id: pool_id}) do
    open? =
      Session
      |> where([s], s.pool_id == ^pool_id and s.status in ^Session.open_statuses())
      |> Repo.exists?()

    if open?, do: {:error, :pool_in_use}, else: :ok
  end

  @doc "Lists the members of one of the project's pools, oldest first."
  @spec list_members(Account.t(), Project.t(), term()) ::
          {:ok, Pool.t(), [Member.t()]} | {:error, :not_found}
  def list_members(%Account{} = account, %Project{} = project, slug) do
    with {:ok, pool} <- fetch_pool(account, project, slug) do
      members =
        Member
        |> where([m], m.pool_id == ^pool.id)
        |> order_by([m], asc: m.inserted_at, asc: m.id)
        |> Repo.all()

      {:ok, pool, members}
    end
  end

  @doc """
  Whether `member` is stale: built from an older `setup_version` than the
  pool's, or with an older transfer helper than this node's packaged one
  (`GoodFlows.Pools.Config.helper_stale?/1`; a newer helper is not stale).
  A stale member is never granted and is destroyed once released.
  """
  @spec stale?(Member.t(), Pool.t()) :: boolean()
  def stale?(%Member{} = member, %Pool{} = pool) do
    member.setup_version < pool.setup_version or
      (member.state not in ["provisioning"] and Config.helper_stale?(member.helper_version))
  end

  @doc """
  Whether this node may grant `member`: not stale, and built with a helper
  whose protocol this node speaks.
  """
  @spec grantable?(Member.t(), Pool.t()) :: boolean()
  def grantable?(%Member{} = member, %Pool{} = pool),
    do: not stale?(member, pool) and Config.helper_compatible?(member.helper_version)

  @doc "`active`, or `credential_missing` when the account has no Sprites credential."
  @spec pool_status(Pool.t()) :: String.t()
  def pool_status(%Pool{account_id: account_id}) do
    if Credentials.configured?(account_id), do: "active", else: "credential_missing"
  end

  defp with_stats([], _project), do: []

  defp with_stats(pools, project) do
    ids = Enum.map(pools, & &1.id)

    counts =
      Member
      |> where([m], m.pool_id in ^ids)
      |> group_by([m], [m.pool_id, m.state])
      |> select([m], {m.pool_id, m.state, count(m.id)})
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), fn {_pool, state, count} -> {state, count} end)

    status = pool_status(hd(pools))

    Enum.map(pools, fn pool ->
      by_state = Map.new(Member.states(), &{&1, 0})
      by_state = Enum.into(Map.get(counts, pool.id, []), by_state)
      %{pool | member_counts: by_state, status: status, project: project}
    end)
  end
end
