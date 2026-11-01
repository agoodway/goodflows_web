defmodule GoodFlows.TestReports.Report do
  @moduledoc """
  One immutable uploaded test report, stored in `test_reports`.

  The row belongs to an account and one of its projects (the project in the
  upload path) and optionally records the API key that submitted it. The
  identity `(account_id, project_id, workflow_run_id, job, report_id)` is
  unique. `payload` is the validated request body as JSONB, including every
  record and the source context; it never contains a project slug. The
  extracted columns duplicate envelope fields for later queries, and
  `status` is the derived per-report completion (`complete` or
  `incomplete`). `payload_digest` is the SHA-256 of the payload's canonical
  JSON (`GoodFlows.TestReports.Document.digest/1`), used to compare
  retries. Rows are inserted once and never updated.

  Rows are written only by `GoodFlows.TestReports.ingest/4` through
  `Repo.insert_all/3`; there is no changeset.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "test_reports" do
    field :workflow_run_id, Ecto.UUID
    field :workflow, :string
    field :environment, :string
    field :job, :string
    field :job_status, :string
    field :suite_id, :string
    field :report_id, :string
    field :partition, :string
    field :partition_count, :integer
    field :status, :string
    field :payload, :map
    field :payload_digest, :binary

    belongs_to :account, Account
    belongs_to :project, Project
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
