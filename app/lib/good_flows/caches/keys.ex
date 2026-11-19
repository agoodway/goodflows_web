defmodule GoodFlows.Caches.Keys do
  @moduledoc """
  Cache (`ck_`) keys: minted, listed and revoked by private keys through
  `/api/v1/projects/:project/cache-keys`. Minting is the only way to create
  one. A project holds at most `:cache_max_keys_per_project` (default
  1,000) active cache keys.

  A key belongs to one project and the minting key's account membership,
  has `read` (`:cache_read`) or `read_write` (`:cache_write`) access, and
  may be bound to one scope. Lifetimes depend on access:

  | `access` | `ttl_seconds` omitted | allowed | `null` |
  |---|---|---|---|
  | `read_write` | 21,600 | 60..86,400 | refused |
  | `read` | 21,600 | 60..31,536,000 | no expiry; `name` required |
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.Caches
  alias GoodFlows.Caches.{Cursor, Rules}
  alias GoodFlows.{ChangesetErrors, KeysetCursor}
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo

  @default_ttl_seconds 21_600
  @min_ttl_seconds 60
  @max_ttl_seconds %{"read_write" => 86_400, "read" => 31_536_000}
  @types %{"read" => :cache_read, "read_write" => :cache_write}
  @max_name_length 100
  @default_name "cache key"
  @default_page_size 50
  @max_page_size 200
  @mint_fields ~w(access scope ttl_seconds name)

  @doc "The wire `access` of a cache key type."
  @spec access(atom()) :: String.t()
  def access(:cache_read), do: "read"
  def access(:cache_write), do: "read_write"

  @doc """
  Mints a cache key of `project` for `account_user` from `attrs` (`access`,
  `scope`, `ttl_seconds`, `name`; any other key is an error). Returns the key and its token, which is
  never shown again. `{:unprocessable, _}` when the project already has
  `:cache_max_keys_per_project` active (neither revoked nor expired) cache
  keys; mints of one project are serialized by a lock on its row.
  """
  @spec mint(AccountUser.t(), Project.t(), map()) ::
          {:ok, {ApiKey.t(), String.t()}}
          | {:error, Changeset.t() | :not_found | {:unprocessable, String.t()}}
  def mint(
        %AccountUser{account_id: account_id} = account_user,
        %Project{account_id: account_id} = project,
        attrs
      )
      when is_map(attrs) do
    with {:ok, params} <- mint_params(attrs) do
      Repo.transaction(fn ->
        lock_project!(project.id)
        check_key_cap!(project.id)
        insert_key!(account_user, project, params)
      end)
    end
  end

  def mint(%AccountUser{}, %Project{}, _attrs), do: {:error, :not_found}

  # Serializes mints of one project so concurrent ones cannot pass the cap.
  defp lock_project!(project_id) do
    Project |> where([p], p.id == ^project_id) |> lock("FOR NO KEY UPDATE") |> Repo.one!()
  end

  defp check_key_cap!(project_id) do
    max = Caches.setting(:cache_max_keys_per_project)

    if project_id |> active_keys(DateTime.utc_now(:second)) |> Repo.aggregate(:count) >= max do
      Repo.rollback(
        {:unprocessable,
         "The project has #{max} active cache keys, the most allowed; revoke one first"}
      )
    end
  end

  defp insert_key!(account_user, project, params) do
    type = Map.fetch!(@types, params.access)
    token = ApiKey.generate_token(type)

    %ApiKey{account_user_id: account_user.id, project_id: project.id}
    |> ApiKey.cache_changeset(%{
      name: params.name || @default_name,
      type: type,
      scope: params.scope,
      expires_at: params.expires_at
    })
    |> Changeset.put_change(:token_prefix, ApiKey.token_prefix(token))
    |> Changeset.put_change(:token_hash, ApiKey.hash_token(token))
    |> Repo.insert()
    |> case do
      {:ok, api_key} -> {api_key, token}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp active_keys(project_id, now) do
    ApiKey
    |> where([k], k.project_id == ^project_id and k.type in ^ApiKey.cache_types())
    |> where([k], k.status == :active and (is_nil(k.expires_at) or k.expires_at > ^now))
  end

  defp mint_params(attrs) do
    types = %{access: :string, scope: :string, name: :string, expires_at: :utc_datetime}
    unknown = ChangesetErrors.unknown_keys(attrs, @mint_fields, "is not allowed")

    {%{scope: nil, name: nil, expires_at: nil}, types}
    |> Changeset.cast(attrs, [:access, :scope, :name], empty_values: [])
    |> Changeset.validate_required([:access])
    |> Changeset.validate_inclusion(:access, Map.keys(@types))
    |> Rules.validate([:scope])
    |> Changeset.update_change(:name, &String.trim/1)
    |> Changeset.validate_length(:name, min: 1, max: @max_name_length)
    |> put_expiry(attrs)
    |> ChangesetErrors.prepend(unknown)
    |> Changeset.apply_action(:mint)
  end

  defp put_expiry(changeset, attrs) do
    access = Changeset.get_field(changeset, :access)

    case {access, Map.fetch(attrs, "ttl_seconds")} do
      {access, _ttl} when not is_map_key(@max_ttl_seconds, access) ->
        changeset

      {_access, :error} ->
        put_ttl(changeset, @default_ttl_seconds)

      {"read", {:ok, nil}} ->
        if Changeset.get_field(changeset, :name),
          do: Changeset.put_change(changeset, :expires_at, nil),
          else: Changeset.add_error(changeset, :name, "is required for a key without expiry")

      {"read_write", {:ok, nil}} ->
        Changeset.add_error(changeset, :ttl_seconds, "is required for read_write keys")

      {access, {:ok, ttl}} ->
        max = Map.fetch!(@max_ttl_seconds, access)

        if is_integer(ttl) and ttl in @min_ttl_seconds..max,
          do: put_ttl(changeset, ttl),
          else:
            Changeset.add_error(
              changeset,
              :ttl_seconds,
              "must be an integer from #{@min_ttl_seconds} through #{max}"
            )
    end
  end

  defp put_ttl(changeset, ttl) do
    expires_at = DateTime.utc_now(:second) |> DateTime.add(ttl, :second)
    Changeset.put_change(changeset, :expires_at, expires_at)
  end

  @doc """
  Lists the project's cache keys that are neither revoked nor expired,
  newest first, keyset-paged by `limit` (1 to 200, default 50) and
  `cursor`.
  """
  @spec list(Project.t(), map()) ::
          {:ok, %{keys: [ApiKey.t()], next_cursor: String.t() | nil}} | {:error, Changeset.t()}
  def list(%Project{id: project_id}, params) do
    with {:ok, filters} <- list_params(params) do
      now = DateTime.utc_now(:second)

      keys =
        project_id
        |> active_keys(now)
        |> after_cursor(filters.cursor)
        |> order_by([k], desc: k.inserted_at, desc: k.id)
        |> limit(^(filters.limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(keys, filters.limit)

      next_cursor =
        if rest != [] do
          last = List.last(page)
          Cursor.encode(last.inserted_at, last.id)
        end

      {:ok, %{keys: page, next_cursor: next_cursor}}
    end
  end

  defp list_params(params) do
    types = %{limit: :integer, cursor: :string}

    {%{limit: @default_page_size, cursor: nil}, types}
    |> Changeset.cast(params, Map.keys(types))
    |> Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_page_size
    )
    |> KeysetCursor.put_cursor(&Cursor.decode/1)
    |> Changeset.apply_action(:list)
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {at, id}) do
    at = DateTime.truncate(at, :second)
    where(query, [k], k.inserted_at < ^at or (k.inserted_at == ^at and k.id < ^id))
  end

  @doc """
  Revokes cache key `id` of `project`. Revoking a revoked key is `:ok`.
  Another project's key, a non-cache key, or an id that is not a UUID is
  `:not_found`.
  """
  @spec revoke(Project.t(), term()) :: :ok | {:error, :not_found}
  def revoke(%Project{id: project_id}, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %ApiKey{} = api_key <-
           ApiKey
           |> where([k], k.id == ^uuid and k.project_id == ^project_id)
           |> where([k], k.type in ^ApiKey.cache_types())
           |> Repo.one() do
      if api_key.status != :revoked do
        api_key |> Changeset.change(status: :revoked) |> Repo.update!()
      end

      :ok
    else
      _other -> {:error, :not_found}
    end
  end
end
