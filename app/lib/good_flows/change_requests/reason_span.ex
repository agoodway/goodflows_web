defmodule GoodFlows.ChangeRequests.ReasonSpan do
  @moduledoc """
  One permanent row per time a reason, keyed by `rule`, `subject` and
  `outcome`, is in a change request's verdict. It opens at the recompute
  where the reason appears (`opened_head`, `opened_policy_version`,
  `opened_at`; `inherited` when the reason was already in a verdict stored
  before spans existed, so `opened_at` is a lower bound) and closes once:
  at the recompute where it disappears (`close_cause` `head`, `policy` or
  `inputs`, with `close_head_kind` for `head`), at the merge (`merged`) or
  at a close (`closed`). Written by `GoodFlows.ChangeRequests` only and
  deleted only with the change request.
  """
  use Ecto.Schema

  alias GoodFlows.ChangeRequests.ChangeRequest

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_request_reason_spans" do
    field :rule, :string
    field :subject, {:array, :string}
    field :outcome, :string
    field :opened_head, :string
    field :opened_policy_version, :integer
    field :opened_at, :utc_datetime_usec
    field :inherited, :boolean, default: false
    field :closed_head, :string
    field :closed_at, :utc_datetime_usec
    field :close_cause, :string
    field :close_head_kind, :string

    belongs_to :change_request, ChangeRequest
  end
end
