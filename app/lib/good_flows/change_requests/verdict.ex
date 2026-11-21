defmodule GoodFlows.ChangeRequests.Verdict do
  @moduledoc """
  The stored verdict of a change request (one row each): `state`, the
  `head` it was computed for (or nil), the `policy_version`, the `reasons`
  (a JSON array of `rule`, `outcome`, `subject` and `message`), the
  `inputs` digests and `computed_at`. It is replaced by every recompute.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.ChangeRequests.ChangeRequest

  @type t :: %__MODULE__{}

  @states ~w(pending blocked needs_review mergeable)

  @primary_key false
  @foreign_key_type :binary_id

  schema "change_request_verdicts" do
    belongs_to :change_request, ChangeRequest, primary_key: true
    field :state, :string
    field :head, :string
    field :policy_version, :integer
    field :reasons, GoodFlows.JsonValue
    field :inputs, :map
    field :computed_at, :utc_datetime_usec
  end

  @doc "The verdict states, highest precedence first."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Builds an upsert changeset; every value is kept as given."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(verdict, attrs) do
    verdict
    |> change(attrs)
    |> validate_required([:change_request_id, :state, :policy_version, :reasons, :inputs])
    |> validate_inclusion(:state, @states)
  end
end
