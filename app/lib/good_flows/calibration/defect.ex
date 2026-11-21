defmodule GoodFlows.Calibration.Defect do
  @moduledoc """
  A defect found after a change request merged: the change request it is
  attributed to (or nil), the `commit` it names (or nil), its
  `attribution` (`change_request`, `commit` or `unattributed`), an
  optional `severity` and `ticket`, the membership and key that recorded
  it and `recorded_at`. Attribution is fixed when the row is written, and
  rows are never updated.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @severities ~w(low medium high critical)
  @attributions ~w(change_request commit unattributed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "defects" do
    field :commit, :string
    field :attribution, :string
    field :severity, :string
    field :ticket, :string
    field :recorded_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :change_request, ChangeRequest
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey
  end

  @doc "The severity values."
  @spec severities() :: [String.t()]
  def severities, do: @severities

  @doc "The attribution values."
  @spec attributions() :: [String.t()]
  def attributions, do: @attributions
end
