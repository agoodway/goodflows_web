defmodule GoodFlows.ChangeRequests.Claims do
  @moduledoc """
  One immutable `change-claims/2` file of a change request for one `head`.
  `document` is the raw Markdown file byte for byte, `front_matter` its
  parsed YAML front matter, and `digest` the SHA-256 of the raw bytes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.ChangeRequest

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_request_claims" do
    field :head, :string
    field :document, :string
    field :front_matter, :map
    field :digest, :binary

    belongs_to :change_request, ChangeRequest
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Builds an insert changeset; every value is kept as given."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(claims, attrs) do
    claims
    |> change(attrs)
    |> validate_required([:change_request_id, :head, :document, :front_matter, :digest])
  end
end
