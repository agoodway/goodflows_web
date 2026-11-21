defmodule GoodFlows.MergeLeases.Lease do
  @moduledoc """
  A merge slot lease: the right of one change request to merge onto its
  project's `target_branch` until `expires_at`.

  It stores the change request, the `head` and `base` (the target branch
  commit the client merges onto, 40 or 64 lowercase hex characters each),
  the holder's membership and key, `ttl_seconds`, `state` (`active`,
  `released` or `expired`), the `release_reason` of a released lease
  (`released`, `merged` or `closed`), `acquired_at` and `expires_at`. An
  `active` lease whose `expires_at` has passed holds no slot.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.ChangeRequest
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @sha ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @states ~w(active released expired)
  @release_reasons ~w(released merged closed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "merge_leases" do
    field :target_branch, :string
    field :head, :string
    field :base, :string
    field :ttl_seconds, :integer
    field :state, :string, default: "active"
    field :release_reason, :string
    field :acquired_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :project, Project
    belongs_to :change_request, ChangeRequest
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey
  end

  @doc "The lease states."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The release reasons."
  @spec release_reasons() :: [String.t()]
  def release_reasons, do: @release_reasons

  @doc """
  Builds the insert changeset of a new `active` lease. `head` and `base`
  must be 40 or 64 lowercase hex characters; the owner, change request,
  holder and times are set on the struct by the caller.
  """
  @spec acquire_changeset(t(), map()) :: Ecto.Changeset.t()
  def acquire_changeset(lease, attrs) do
    lease
    |> cast(attrs, [:head, :base])
    |> validate_required([
      :project_id,
      :change_request_id,
      :target_branch,
      :head,
      :base,
      :ttl_seconds,
      :acquired_at,
      :expires_at
    ])
    |> validate_format(:head, @sha, message: "must be 40 or 64 lowercase hex characters")
    |> validate_format(:base, @sha, message: "must be 40 or 64 lowercase hex characters")
    |> validate_inclusion(:state, @states)
    |> unique_constraint(:target_branch, name: :merge_leases_active_slot_index)
  end
end
