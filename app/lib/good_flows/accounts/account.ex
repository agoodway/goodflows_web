defmodule GoodFlows.Accounts.Account do
  @moduledoc """
  A tenant. Users reach an account's data only through an `AccountUser`
  membership; the slug is derived from the name when not given.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.AccountUser

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "accounts" do
    field :name, :string
    field :slug, :string
    field :status, Ecto.Enum, values: [:active, :suspended], default: :active

    has_many :account_users, AccountUser
    has_many :users, through: [:account_users, :user]

    timestamps(type: :utc_datetime)
  end

  @doc "Validates name and slug, generating the slug from the name when blank."
  def changeset(account, attrs) do
    account
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name])
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/,
      message: "must be lowercase letters, numbers, and dashes"
    )
    |> unique_constraint(:slug)
  end

  defp maybe_generate_slug(changeset) do
    name = get_field(changeset, :name)

    if is_nil(get_field(changeset, :slug)) and is_binary(name) do
      put_change(changeset, :slug, slugify(name))
    else
      changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
