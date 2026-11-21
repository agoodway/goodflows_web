defmodule GoodFlows.VerifyRuns.Artifact do
  @moduledoc """
  One declared artifact of a verify run: its `artifact_id`, the
  server-named `object_key`, the declared `size`, `sha256` and
  `content_type`, whether retention deleted its object (`expired`), and
  when its last presigned upload URL expires.
  """
  use Ecto.Schema

  alias GoodFlows.VerifyRuns.Run

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "verify_run_artifacts" do
    field :artifact_id, :string
    field :object_key, :string
    field :size, :integer
    field :sha256, :string
    field :content_type, :string
    field :expired, :boolean, default: false
    field :upload_expires_at, :utc_datetime_usec

    belongs_to :verify_run, Run
  end

  @doc "The object key of an artifact of run `run_id` in `project_id`."
  @spec object_key(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def object_key(project_id, run_id, artifact_row_id),
    do: "verify-runs/#{project_id}/#{run_id}/#{artifact_row_id}"
end
