defmodule GoodFlows.Review.Task do
  @moduledoc """
  The work a `request_change` or `reject` answer asks of the author agent:
  the item `id` and `kind`, the `answer`, its `note` and `head`, and a
  `state`: `open`, `stale` (a new head was reported, or the answer was
  replaced) or `done`, with who created and completed it.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.Review.Answer

  @type t :: %__MODULE__{}

  @states ~w(open stale done)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "review_tasks" do
    field :item_id, :string
    field :kind, :string
    field :answer, :string
    field :note, :string
    field :head, :string
    field :state, :string
    field :done_at, :utc_datetime_usec

    belongs_to :change_request, ChangeRequest
    belongs_to :review_answer, Answer, foreign_key: :answer_id
    belongs_to :created_by_account_user, AccountUser
    belongs_to :done_by_account_user, AccountUser

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The task states."
  @spec states() :: [String.t()]
  def states, do: @states
end
