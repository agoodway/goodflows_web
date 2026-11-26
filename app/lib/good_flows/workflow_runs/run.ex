defmodule GoodFlows.WorkflowRuns.Run do
  @moduledoc """
  One immutable uploaded workflow run, stored in `workflow_runs`.

  The row belongs to an account and one of its projects (the project in the
  upload path) and optionally records the API key that submitted it. The
  identity `(account_id, project_id, run_id)` is unique. `payload` is the
  validated run-history document as JSONB. It never contains a project slug.
  The extracted columns duplicate fields the list filters and summaries
  need, including `host`, `source_branch` and `ci`, so a list never reads
  `payload`. `link_tickets` (ASCII-lowercased) and `link_threads` (as
  sent) copy `links` for the link filters and are empty when the document
  has none. They are not part of a summary. `failed_jobs` (the names of
  the `failed` and `timed_out` results, in result order) is part of a
  summary; `parent_run_id` (the calling run) is not, and is used only to
  fold called runs under their parent in the dashboard.
  `payload_digest` is the SHA-256 of the payload's canonical JSON
  (`GoodFlows.JsonDocument.digest/1`), used to compare retries. Rows are
  inserted once and never updated.

  Rows are written only by `GoodFlows.WorkflowRuns.ingest/4` through
  `Repo.insert_all/3`; there is no changeset.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_runs" do
    field :run_id, Ecto.UUID
    field :workflow, :string
    field :environment, :string
    field :outcome, :string
    field :started_at, :utc_datetime
    field :duration_ms, :integer
    field :parallelism, :integer
    field :max_in_flight, :integer
    field :graph_sha256, :string
    field :source_commit, :string
    field :source_dirty, :boolean
    field :source_branch, :string
    field :ci, :map
    field :host, :map
    field :link_tickets, {:array, :string}, default: []
    field :link_threads, {:array, :string}, default: []
    field :failed_jobs, {:array, :string}, default: []
    field :parent_run_id, Ecto.UUID
    field :payload, :map
    field :payload_digest, :binary

    belongs_to :account, Account
    belongs_to :project, Project
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
