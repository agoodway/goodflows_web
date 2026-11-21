defmodule GoodFlows.ProjectEvents.Event do
  @moduledoc """
  One row of a project's event feed: the bigint `id` (the feed cursor),
  the change request `number` it concerns (or nil), the `type`, the type's
  own `data`, the membership and key that caused it (nil for server-made
  events) and the time. Rows are inserted once and never updated.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @foreign_key_type :binary_id

  schema "project_events" do
    field :change_request_number, :integer
    field :type, :string
    field :data, :map
    field :inserted_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :actor_membership, AccountUser
    belongs_to :actor_key, ApiKey
  end
end
