defmodule GoodFlows.VerifyRuns.Run do
  @moduledoc """
  A stored `verify-run/1` document of a project. `status` is `uploading`
  until every declared artifact is committed, then `final`. `document` is
  the normalized body and `digest` its canonical JSON digest; the other
  fields are copied out of it for counting runs. `api_key_id` is the
  uploading key.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{Account, AccountUser, ApiKey}
  alias GoodFlows.Projects.Project
  alias GoodFlows.VerifyRuns.Artifact

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "verify_runs" do
    field :run_id, Ecto.UUID
    field :status, :string
    field :document, :map
    field :digest, :binary
    field :source_commit, :string
    field :dirty, :boolean
    field :scenario_set_digest, :string
    field :scenario_set_source, :string
    field :merge_result, :boolean
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :finalized_at, :utc_datetime_usec

    belongs_to :account, Account
    belongs_to :project, Project
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey
    has_many :artifacts, Artifact, foreign_key: :verify_run_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
