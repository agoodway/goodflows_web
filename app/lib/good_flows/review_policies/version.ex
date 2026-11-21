defmodule GoodFlows.ReviewPolicies.Version do
  @moduledoc """
  One immutable `review-policy/1` version of a project. `document` is the
  policy as written; `previous_version` the version it replaced; `note` an
  optional comment; and the membership and key that wrote it. Versions are
  numbered from 1 and deleted with their project.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "review_policy_versions" do
    field :version, :integer
    field :document, :map
    field :previous_version, :integer
    field :note, :string

    belongs_to :project, Project
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Builds an insert changeset; every value is kept as given."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(version, attrs) do
    version
    |> change(attrs)
    |> validate_required([:project_id, :version, :document, :previous_version])
    |> unique_constraint(:version, name: :review_policy_versions_project_id_version_index)
  end
end
