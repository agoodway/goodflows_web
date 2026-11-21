defmodule GoodFlows.FeatureIndex.Version do
  @moduledoc """
  One immutable synced feature index of a project: `features` as sent
  (`id`, `title`, `paths`), its canonical JSON `digest`, and the
  membership and key that synced it.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "feature_index_versions" do
    field :version, :integer
    field :features, GoodFlows.JsonValue
    field :digest, :binary

    belongs_to :project, Project
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
