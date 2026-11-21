defmodule GoodFlows.ChangeRequests.Event do
  @moduledoc """
  One recorded state change of a change request: the previous and new
  state, and the membership and key that made it. Rows are inserted once
  and never updated.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.ChangeRequest

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_request_events" do
    field :from_state, :string
    field :to_state, :string

    belongs_to :change_request, ChangeRequest
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Builds an event changeset; every value is kept as given."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> change(attrs)
    |> validate_required([:change_request_id, :from_state, :to_state])
  end
end
