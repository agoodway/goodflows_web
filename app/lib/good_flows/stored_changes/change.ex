defmodule GoodFlows.StoredChanges.Change do
  @moduledoc """
  A goodflows change stored for a project, keyed by its `change_id`. It
  holds the latest version's number, `status`, listing fields and push
  time, so the change list reads one row per change.
  """
  use Ecto.Schema

  alias GoodFlows.Projects.Project
  alias GoodFlows.StoredChanges.Version

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "stored_changes" do
    field :change_id, :string
    field :latest_version, :integer
    field :status, :string
    field :size, :string
    field :door, :string
    field :capabilities, {:array, :string}
    field :depends_on, {:array, :string}
    field :last_pushed_at, :utc_datetime_usec

    belongs_to :project, Project
    has_many :versions, Version, foreign_key: :stored_change_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
