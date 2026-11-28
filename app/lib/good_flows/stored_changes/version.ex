defmodule GoodFlows.StoredChanges.Version do
  @moduledoc """
  One immutable pushed version of a stored change: `files` (path to text)
  as sent, their `digest`, the fields read from `change.md`, the push
  `source` (`commit`, `branch`, `dirty`) and the membership and key that
  pushed it. `inserted_at` is the push time.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.StoredChanges.Change

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stored_change_versions" do
    field :version, :integer
    field :status, :string
    field :size, :string
    field :door, :string
    field :capabilities, {:array, :string}
    field :depends_on, {:array, :string}
    field :files, :map
    field :digest, :binary
    field :commit, :string
    field :branch, :string
    field :dirty, :boolean

    belongs_to :stored_change, Change
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
