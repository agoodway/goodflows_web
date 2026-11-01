defmodule GoodFlows.Spry.RunStep do
  @moduledoc """
  One action within a run: `create` or `destroy` of the VM, or an `exec` of
  an expanded step line. Output is the combined stdout/stderr tail, truncated
  to the configured limit (`output_truncated`).
  """
  use Ecto.Schema

  alias GoodFlows.Spry.Run

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "run_steps" do
    field :index, :integer
    field :kind, :string
    field :command, :string
    field :status, :string, default: "pending"
    field :exit_code, :integer
    field :reason, :string
    field :output, :string
    field :output_truncated, :boolean, default: false
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :run, Run

    timestamps(type: :utc_datetime_usec)
  end
end
