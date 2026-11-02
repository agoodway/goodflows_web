defmodule GoodFlows.Spry.Run do
  @moduledoc """
  One execution of a recipe phase against a sprite.

  `plan` is the expanded snapshot taken at admission (`sprite_name` and the
  phase's `commands`), so later recipe edits never change what runs. At most
  one `queued` or `running` run may exist per account and sprite name
  (partial unique index `runs_one_active_per_sprite_index`).

  `owner_id` identifies the worker execution that claimed the run; every
  worker write is conditional on it and on `status = 'running'`.
  `reaper_checked_at` records when the reaper last investigated the run
  without finalizing it, so retained runs rotate behind fresh candidates.
  `started_by_api_key_id` is the API key that started the run (nilified if
  the key is deleted).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.Account
  alias GoodFlows.Spry.{Recipe, RunStep}

  @type t :: %__MODULE__{}

  @statuses ~w(queued running succeeded failed)
  @active_statuses ~w(queued running)
  @phases ~w(setup start stop teardown)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runs" do
    field :phase, :string
    field :sprite_name, :string
    field :inputs, :map, default: %{}
    field :no_create, :boolean, default: false
    field :no_destroy, :boolean, default: false
    field :plan, :map
    field :status, :string, default: "queued"
    field :error, :string
    field :owner_id, :string
    field :pgflow_run_id, :binary_id
    field :started_at, :utc_datetime_usec
    field :action_started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :reaper_checked_at, :utc_datetime_usec
    field :started_by_api_key_id, :binary_id

    belongs_to :account, Account
    belongs_to :recipe, Recipe
    has_many :steps, RunStep, preload_order: [asc: :index]

    timestamps(type: :utc_datetime_usec)
  end

  @doc "All run statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Statuses that hold the one-active-run guard."
  @spec active_statuses() :: [String.t()]
  def active_statuses, do: @active_statuses

  @doc "Changeset for admitting a new queued run."
  @spec admission_changeset(t(), map()) :: Ecto.Changeset.t()
  def admission_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :phase,
      :sprite_name,
      :inputs,
      :no_create,
      :no_destroy,
      :plan
    ])
    |> validate_required([:phase, :sprite_name, :plan])
    |> validate_inclusion(:phase, @phases)
    |> put_change(:status, "queued")
    |> unique_constraint(:sprite_name,
      name: :runs_one_active_per_sprite_index,
      message: "already has an active run"
    )
  end
end
