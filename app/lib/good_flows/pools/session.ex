defmodule GoodFlows.Pools.Session do
  @moduledoc """
  One client invocation's lease on members of a pool.

  Statuses: `waiting` (no member yet), `active` (has held a member),
  `released`, and `expired`. `end_reason` is set only for `expired`
  (`no_member_available`, `client_disconnected`, `lifetime_exceeded`,
  `key_revoked`, or `session_owner_lost`).

  `wanted` is the desired total of held members (initially `max_members`);
  `wanting_since` orders sessions for fairness (`GoodFlows.Pools.Grants`).
  `owner_id` names the session coordinator (`GoodFlows.Pools.SessionCoordinator`)
  that holds the captured Sprites credential in memory and the workspace
  spool; `credential_fingerprint` is the internal HMAC of that credential.
  `pool_slug` and `project_slug` are copied at creation so the record
  survives pool deletion.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.ChangesetErrors
  alias GoodFlows.Pools.{Exec, Member, Pool}

  @type t :: %__MODULE__{}

  @statuses ~w(waiting active released expired)
  @end_reasons ~w(no_member_available client_disconnected lifetime_exceeded key_revoked session_owner_lost)
  @allowed_keys ~w(max_members acquire_timeout_ms label)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @derive {Inspect, except: [:credential_fingerprint]}
  schema "pool_sessions" do
    field :pool_slug, :string
    field :project_slug, :string
    field :credential_fingerprint, :binary, redact: true
    field :owner_id, :string
    field :owner_lease_expires_at, :utc_datetime_usec
    field :status, :string, default: "waiting"
    field :end_reason, :string
    field :max_members, :integer
    field :wanted, :integer
    field :granted_count, :integer, default: 0
    field :wanting_since, :utc_datetime_usec
    field :label, :string
    field :acquire_deadline_at, :utc_datetime_usec
    field :first_granted_at, :utc_datetime_usec
    field :workspace_uploaded_at, :utc_datetime_usec
    field :workspace_bytes, :integer
    field :workspace_sha256, :binary
    field :last_seen_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :acquire_timeout_ms, :integer, virtual: true

    field :account_id, :binary_id
    field :api_key_id, :binary_id
    belongs_to :pool, Pool
    has_many :members, Member
    has_many :execs, Exec

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every session status."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses of a session that has not ended."
  @spec open_statuses() :: [String.t()]
  def open_statuses, do: ~w(waiting active)

  @doc "Every expiry reason."
  @spec end_reasons() :: [String.t()]
  def end_reasons, do: @end_reasons

  @doc "Whether the session has ended."
  @spec ended?(t()) :: boolean()
  def ended?(%__MODULE__{status: status}), do: status in ~w(released expired)

  @doc """
  Validates a create body: only `max_members` (1 to the pool's
  `max_members`), `acquire_timeout_ms` (1,000 to `max_acquire_ms`), and an
  optional `label` (at most 255 characters, no control characters).
  """
  @spec create_changeset(t(), map(), pos_integer(), pos_integer()) :: Ecto.Changeset.t()
  def create_changeset(session, attrs, pool_max, max_acquire_ms) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    session
    |> cast(Map.take(attrs, @allowed_keys), [:max_members, :acquire_timeout_ms, :label])
    |> validate_required([:max_members, :acquire_timeout_ms])
    |> validate_number(:max_members, greater_than_or_equal_to: 1, less_than_or_equal_to: pool_max)
    |> validate_number(:acquire_timeout_ms,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: max_acquire_ms
    )
    |> validate_length(:label, max: 255)
    |> validate_format(:label, ~r/\A[^\p{Cc}]*\z/u,
      message: "must not contain control characters"
    )
    |> ChangesetErrors.prepend(
      ChangesetErrors.unknown_keys(attrs, @allowed_keys, "is not allowed in a session body")
    )
  end
end
