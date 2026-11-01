defmodule GoodFlows.Accounts.ApiKey do
  @moduledoc """
  API key for programmatic access, owned by an account membership so it
  carries both the user and the account.

  Public keys (`pk_…`) are read-only; private keys (`sk_…`) can write. Only
  a SHA-256 hash and a 12-character lookup prefix of the token are stored.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.AccountUser

  @type t :: %__MODULE__{}

  @prefix_length 12

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field :name, :string
    field :type, Ecto.Enum, values: [:public, :private], default: :public
    field :token_prefix, :string
    field :token_hash, :string
    field :status, Ecto.Enum, values: [:active, :revoked], default: :active
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :account_user, AccountUser

    timestamps(type: :utc_datetime)
  end

  @doc "Returns whether the key may perform write operations."
  @spec can_write?(t()) :: boolean()
  def can_write?(%__MODULE__{type: :private}), do: true
  def can_write?(%__MODULE__{}), do: false

  @doc "Generates a new random token whose prefix encodes the key type."
  @spec generate_token(:public | :private) :: String.t()
  def generate_token(type) do
    prefix = if type == :private, do: "sk_", else: "pk_"
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
  Casts user-editable fields. `account_user_id`, `token_prefix`, and
  `token_hash` are set by `GoodFlows.Accounts.create_api_key/2`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:name, :type, :expires_at])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :type, :account_user_id])
    |> validate_length(:name, max: 100)
    |> validate_future(:expires_at)
    |> foreign_key_constraint(:account_user_id)
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
