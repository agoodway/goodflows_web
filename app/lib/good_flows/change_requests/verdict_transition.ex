defmodule GoodFlows.ChangeRequests.VerdictTransition do
  @moduledoc """
  One permanent row per recompute of a `draft` or `open` change request
  that stored its first verdict or changed the verdict's state, head or
  policy version. `from_*` are null for the first verdict. `cause` is
  `created`, `head`, `policy` or `inputs`; `head_kind` is the kind of the
  Git facts report that moved the head (`cause` `head`), else null.
  Rows are written once by `GoodFlows.ChangeRequests` and deleted only
  with their change request.
  """
  use Ecto.Schema

  alias GoodFlows.ChangeRequests.ChangeRequest

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_request_verdict_transitions" do
    field :from_state, :string
    field :to_state, :string
    field :from_head, :string
    field :to_head, :string
    field :policy_version, :integer
    field :cause, :string
    field :head_kind, :string

    belongs_to :change_request, ChangeRequest

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
