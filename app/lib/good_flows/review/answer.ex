defmodule GoodFlows.Review.Answer do
  @moduledoc """
  One answer to a review packet item of a change request: the item `id`,
  `kind` and `rule`, the `head` it was given at (nil before any
  `git-facts` report), `answer` (`approve`, `reject`, `request_change` or
  `choose`), `option` (for `choose`), `note`, the membership, key and
  `channel` (`cli`), and `superseded_at`, set when a later answer to the
  same item at the same head replaced it.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.ChangeRequest

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "review_answers" do
    field :item_id, :string
    field :kind, :string
    field :rule, :string
    field :head, :string
    field :answer, :string
    field :option, :string
    field :note, :string
    field :channel, :string
    field :superseded_at, :utc_datetime_usec

    belongs_to :change_request, ChangeRequest
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec)
  end
end
