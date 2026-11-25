defmodule GoodFlows.ChangeRequests.GitFacts do
  @moduledoc """
  One immutable `git-facts/1` report of a change request, identified by
  `head` and `target_branch`. `document` is the validated JSON as sent and
  `digest` the SHA-256 of its canonical JSON
  (`GoodFlows.JsonDocument.digest/1`). `previous_head` is the change
  request's head before the report (null for the first) and `head_kind`
  how the head moved from it (`first`, `fast_forward`, `target_merged`,
  `rebase`, `rewrite` or `retarget`); both are fixed when the row is stored
  and null for rows stored before they existed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.{AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.ChangeRequest

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_request_git_facts" do
    field :head, :string
    field :target_branch, :string
    field :document, :map
    field :digest, :binary
    field :previous_head, :string
    field :head_kind, :string

    belongs_to :change_request, ChangeRequest
    belongs_to :account_user, AccountUser
    belongs_to :api_key, ApiKey

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Builds an insert changeset; every value is kept as given."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(git_facts, attrs) do
    git_facts
    |> change(attrs)
    |> validate_required([:change_request_id, :head, :target_branch, :document, :digest])
  end
end
