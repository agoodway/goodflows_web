defmodule GoodFlows.ScenarioSets.Version do
  @moduledoc """
  One immutable version of a change request's `qa-scenarios/2` intent or
  diff set. `content` is the uploaded file byte for byte, `digest` the
  lowercase hex SHA-256 of it, `front_matter` the parsed YAML front matter
  with every scenario ID in string form, and `sections` the
  `{id, sha256}` section digests the client sent (IDs as strings).
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @sources ~w(intent diff)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scenario_set_versions" do
    field :source, :string
    field :version, :integer
    field :content, :string
    field :digest, :string
    field :front_matter, :map
    field :sections, GoodFlows.JsonValue

    belongs_to :change_request, ChangeRequest
    belongs_to :project, Project
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The two set sources."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "The `{id, priority}` of each scenario, in front matter order."
  @spec scenarios(t()) :: [%{id: String.t(), priority: String.t()}]
  def scenarios(%__MODULE__{front_matter: front_matter}) do
    Enum.map(front_matter["scenarios"], &%{id: &1["id"], priority: &1["priority"]})
  end
end
