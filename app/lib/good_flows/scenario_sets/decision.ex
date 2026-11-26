defmodule GoodFlows.ScenarioSets.Decision do
  @moduledoc """
  One `approve` or `reject` decision on a scenario set digest of a change
  request, with the membership and key that made it, the `note` (null for
  approvals), the time and the `channel` (`cli` for every decision made
  through the API, `dashboard` for one made signed in). The integer id
  orders decisions. Intent digests take decisions through the approval
  routes, the dashboard's QA panel and `scenario_set_approval` answers; diff digests only through `diff_set_weakened` answers. The
  digest names the source, since `source` is part of the hashed bytes.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.ChangeRequest

  @type t :: %__MODULE__{}

  @foreign_key_type :binary_id

  schema "scenario_set_decisions" do
    field :digest, :string
    field :decision, :string
    field :note, :string
    field :channel, :string

    belongs_to :change_request, ChangeRequest
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
