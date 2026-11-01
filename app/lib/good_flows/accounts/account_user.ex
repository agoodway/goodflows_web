defmodule GoodFlows.Accounts.AccountUser do
  @moduledoc """
  Membership of a user in an account, carrying the user's role there.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.{Account, ApiKey, User}

  @type role :: :owner | :admin | :member
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "account_users" do
    field :role, Ecto.Enum, values: [:owner, :admin, :member], default: :member

    belongs_to :user, User
    belongs_to :account, Account
    has_many :api_keys, ApiKey

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts the role only; `user_id` and `account_id` must be set on the struct
  by the caller so they can never come from user input.
  """
  def changeset(account_user, attrs) do
    account_user
    |> cast(attrs, [:role])
    |> validate_required([:role, :user_id, :account_id])
    |> unique_constraint([:user_id, :account_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:account_id)
  end

  @doc "Returns whether the membership has admin-level access (owner or admin)."
  @spec admin?(t()) :: boolean()
  def admin?(%__MODULE__{role: role}), do: role in [:owner, :admin]

  @doc "Returns whether the membership is the account owner."
  @spec owner?(t()) :: boolean()
  def owner?(%__MODULE__{role: role}), do: role == :owner
end
