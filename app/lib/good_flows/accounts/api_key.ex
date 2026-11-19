defmodule GoodFlows.Accounts.ApiKey do
  @moduledoc """
  API key for programmatic access, owned by an account membership so it
  carries both the user and the account.

  Public keys (`pk_…`) are read-only; private keys (`sk_…`) can write. Only
  a SHA-256 hash and a 12-character lookup prefix of the token are stored.

  Cache keys (`ck_…`, types `:cache_read` and `:cache_write`) are minted by
  a private key through the API (`GoodFlows.Caches.Keys`). Each belongs to
  one project and may be bound to one cache `scope`. They work only on cache
  routes (`GoodFlowsWeb.Plugs.ApiAuth` refuses them elsewhere), and
  `cache_access/4` decides what they may read and write there. The
  dashboard neither creates nor lists them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @prefix_length 12
  @cache_types [:cache_read, :cache_write]
  @dashboard_types [:public, :private]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field :name, :string

    field :type, Ecto.Enum,
      values: [:public, :private, :cache_read, :cache_write],
      default: :public

    field :scope, :string
    field :token_prefix, :string
    field :token_hash, :string
    field :status, Ecto.Enum, values: [:active, :revoked], default: :active
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :account_user, AccountUser
    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  @doc "Returns whether the key may perform write operations."
  @spec can_write?(t()) :: boolean()
  def can_write?(%__MODULE__{type: :private}), do: true
  def can_write?(%__MODULE__{}), do: false

  @doc "The cache key types (`ck_` tokens)."
  @spec cache_types() :: [atom()]
  def cache_types, do: @cache_types

  @doc "The key types the dashboard creates and lists (`pk_` and `sk_`)."
  @spec dashboard_types() :: [atom()]
  def dashboard_types, do: @dashboard_types

  @doc "Whether the key is a cache (`ck_`) key."
  @spec cache_key?(t()) :: boolean()
  def cache_key?(%__MODULE__{type: type}), do: type in @cache_types

  @doc """
  Decides whether `api_key` may read or write cache `scope` of `project`.

  `scope` is the request's scope, or `nil` for a read without one. Private
  keys may read and write any scope. Public keys get no cache access. A
  cache key gets access only to its own project: unbound, it may read any
  scope, and a `:cache_write` key may write any scope. Bound to scope `B`,
  it may read only with `B`, with the project's default branch, or without
  a scope, and a `:cache_write` key may write only `B`.
  """
  @spec cache_access(t(), Project.t(), String.t() | nil, :read | :write) ::
          :ok | {:error, :forbidden}
  def cache_access(%__MODULE__{type: :private}, %Project{}, _scope, _access), do: :ok

  def cache_access(
        %__MODULE__{type: type, project_id: project_id, scope: bound},
        %Project{id: project_id} = project,
        scope,
        access
      )
      when type in @cache_types do
    if allowed?(type, bound, project.default_branch, scope, access),
      do: :ok,
      else: {:error, :forbidden}
  end

  def cache_access(%__MODULE__{}, %Project{}, _scope, _access), do: {:error, :forbidden}

  @doc """
  The part of `cache_access/4` that needs no validated input, so a key that
  cannot satisfy the request gets `403` before its body or query is
  validated.

  `raw_scope` is the request's `scope` as sent, before validation. A bound
  key may only use its bound scope or the default branch, both valid
  scopes, so `cache_access/4` on the raw value is exact. An unbound cache
  key may read any scope and, with `:cache_write`, write any valid scope,
  so its scope is checked by `cache_access/4` after validation.
  """
  @spec precheck_cache_access(t(), Project.t(), term(), :read | :write) ::
          :ok | {:error, :forbidden}
  def precheck_cache_access(
        %__MODULE__{type: type, project_id: project_id, scope: nil},
        %Project{id: project_id},
        _raw_scope,
        access
      )
      when type in @cache_types do
    if access == :read or type == :cache_write, do: :ok, else: {:error, :forbidden}
  end

  def precheck_cache_access(api_key, project, raw_scope, access),
    do: cache_access(api_key, project, raw_scope, access)

  defp allowed?(_type, nil, _default, _scope, :read), do: true
  defp allowed?(_type, bound, default, scope, :read), do: scope in [nil, bound, default]
  defp allowed?(:cache_write, nil, _default, scope, :write), do: is_binary(scope)
  defp allowed?(:cache_write, bound, _default, scope, :write), do: scope == bound
  defp allowed?(_type, _bound, _default, _scope, _access), do: false

  @doc "Generates a new random token whose prefix encodes the key type."
  @spec generate_token(atom()) :: String.t()
  def generate_token(type) do
    prefix =
      case type do
        :private -> "sk_"
        type when type in @cache_types -> "ck_"
        _public -> "pk_"
      end

    prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  @doc "Returns the indexed lookup prefix of a token."
  @spec token_prefix(String.t()) :: String.t()
  def token_prefix(token), do: String.slice(token, 0, @prefix_length)

  @doc "Hashes a token for storage and lookup (SHA-256, base64)."
  @spec hash_token(String.t()) :: String.t()
  def hash_token(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode64()
  end

  @doc """
  Casts user-editable fields of a dashboard key (`:public` or `:private`).
  `account_user_id`, `token_prefix`, and `token_hash` are set by
  `GoodFlows.Accounts.create_api_key/2`. Cache keys are only minted through
  `cache_changeset/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :type, :expires_at])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :type, :account_user_id])
    |> validate_inclusion(:type, @dashboard_types)
    |> validate_length(:name, max: 100)
    |> validate_future(:expires_at)
    |> foreign_key_constraint(:account_user_id)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Builds a cache key from already validated values: `name`, `type` (a cache
  type), `scope` and `expires_at`. `account_user_id` and `project_id` are
  set on `api_key` by the caller.
  """
  @spec cache_changeset(t(), map()) :: Ecto.Changeset.t()
  def cache_changeset(api_key, attrs) do
    api_key
    |> change(Map.take(attrs, [:name, :type, :scope, :expires_at]))
    |> validate_required([:name, :type, :account_user_id, :project_id])
    |> validate_inclusion(:type, @cache_types)
    |> foreign_key_constraint(:account_user_id)
    |> foreign_key_constraint(:project_id)
    |> check_constraint(:project_id, name: :api_keys_cache_project_check)
    |> check_constraint(:scope, name: :api_keys_cache_scope_check)
    |> unique_constraint(:token_hash)
  end

  defp validate_future(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if DateTime.after?(value, DateTime.utc_now()),
        do: [],
        else: [{field, "must be in the future"}]
    end)
  end
end
