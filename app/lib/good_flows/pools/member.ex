defmodule GoodFlows.Pools.Member do
  @moduledoc """
  One Sprite VM of a pool.

  States: `provisioning → idle → leased → resetting → idle`, with `broken`
  and `destroying` as exits, and `abandoned` for a member whose sprite
  could not be destroyed after repeated authorization failures (its
  creation credential was revoked): it is no longer retried, it is shown
  by the API, and pool deletion forgets it (logging its name) instead of
  waiting forever. `idle_since` records when the member last became idle
  (for a pool's opt-in `idle_ttl_ms`). Transitions are conditional updates fenced on
  the current state (and `owner_id` for job-owned states), so a slow or
  zombie worker cannot overwrite a newer state. `stale` is derived, not
  stored: see `GoodFlows.Pools.stale?/2`.

  `name` is chosen by the server (`gfp-` plus 16 lowercase base32
  characters) and unique across all accounts. `credential_snapshot` is the
  Sprites token the member was created with, encrypted at rest and never
  serialized; it is used only to reset and destroy this member.
  `credential_fingerprint` is an HMAC of that token
  (`GoodFlows.Pools.Credentials`) that decides which sessions may lease the
  member. `workspace_ready_generation` equals `lease_generation` once the
  current lease's workspace is extracted.
  """
  use Ecto.Schema

  alias GoodFlows.Pools.{Pool, Session}

  @type t :: %__MODULE__{}

  @states ~w(provisioning idle leased resetting broken destroying abandoned)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {Inspect, except: [:credential_snapshot]}
  schema "pool_members" do
    field :name, :string
    field :state, :string
    field :setup_version, :integer
    field :helper_version, :string
    field :arch, :string
    field :golden_checkpoint_id, :string
    field :credential_fingerprint, :binary
    field :credential_snapshot, GoodFlows.Encrypted.Binary, redact: true
    field :lease_generation, :integer, default: 0
    field :workspace_ready_generation, :integer
    field :owner_id, :string
    field :operation_deadline_at, :utc_datetime_usec
    field :last_error, :string
    field :failures, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :leased_at, :utc_datetime_usec
    field :idle_since, :utc_datetime_usec

    field :account_id, :binary_id
    belongs_to :pool, Pool
    belongs_to :session, Session

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every member state."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "Whether the member's workspace for its current lease is extracted."
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{state: "leased"} = member),
    do: member.workspace_ready_generation == member.lease_generation

  def ready?(%__MODULE__{}), do: false

  @doc "A fresh member name: `gfp-` plus 16 random lowercase base32 characters."
  @spec generate_name() :: String.t()
  def generate_name do
    "gfp-" <> (10 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false))
  end
end
