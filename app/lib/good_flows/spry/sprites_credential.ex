defmodule GoodFlows.Spry.SpritesCredential do
  @moduledoc """
  An account's Sprites API token, encrypted at rest with `GoodFlows.Vault`.

  `last4` is kept in plaintext for display and is `nil` for tokens of four or
  fewer characters, so metadata never reveals a complete token.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.Account

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "sprites_credentials" do
    field :token, GoodFlows.Encrypted.Binary, redact: true
    field :last4, :string

    belongs_to :account, Account

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Validates a non-blank token and derives `last4`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:token])
    |> validate_token()
    |> validate_required([:token])
    |> put_last4()
  end

  defp validate_token(changeset) do
    validate_change(changeset, :token, fn :token, token ->
      if is_binary(token) and String.valid?(token), do: [], else: [token: "must be a string"]
    end)
  end

  defp put_last4(%Ecto.Changeset{valid?: true} = changeset) do
    token = get_change(changeset, :token)
    put_change(changeset, :last4, last4(token))
  end

  defp put_last4(changeset), do: changeset

  @doc "The token's last four characters, or `nil` when it has four or fewer."
  @spec last4(String.t()) :: String.t() | nil
  def last4(token) when is_binary(token) do
    if String.length(token) > 4, do: String.slice(token, -4, 4), else: nil
  end
end
