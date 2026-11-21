defmodule GoodFlows.ChangeRequests.ChangeRequest do
  @moduledoc """
  A change request: the record that replaces a pull request.

  It belongs to an account and one of its projects and has a per-project
  `number`. `state` is `draft`, `open`, `merged` or `closed`;
  `closed_from_state` remembers the state a closed change request returns
  to on reopen. `head` is the last reported Git facts head, or nil. The
  opener's membership and key are kept, and the `merged_*` fields hold the
  merge report and the verdict at the merged head, written once.

  Rows are written by `GoodFlows.ChangeRequests` only. `create_changeset/2`
  and the other changesets set values as given and never rewrite them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias GoodFlows.Accounts.{Account, AccountUser, ApiKey}
  alias GoodFlows.ChangeRequests.{Event, Verdict}
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @states ~w(draft open merged closed)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "change_requests" do
    field :number, :integer
    field :title, :string
    field :source_branch, :string
    field :target_branch, :string
    field :openspec_change, :string
    field :links, :map
    field :link_tickets, {:array, :string}, default: []
    field :link_threads, {:array, :string}, default: []
    field :state, :string, default: "draft"
    field :closed_from_state, :string
    field :head, :string

    field :merged_commit, :string
    field :merged_target_branch, :string
    field :merged_at, :utc_datetime_usec
    field :merged_head, :string
    field :merged_verdict_state, :string
    field :merged_policy_version, :integer
    field :merged_reasons, GoodFlows.JsonValue
    field :merged_without_mergeable_verdict, :boolean

    belongs_to :account, Account
    belongs_to :project, Project
    belongs_to :opened_by_account_user, AccountUser
    belongs_to :opened_by_api_key, ApiKey

    has_many :events, Event
    has_one :verdict, Verdict

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The four change request states."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc """
  Builds the insert changeset from validated create `attrs` (atom keys:
  `title`, `source_branch`, `target_branch`, `openspec_change`, `links`).
  `number`, the owner and the opener are set on the struct by the caller.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(change_request, attrs) do
    links = Map.get(attrs, :links)

    change_request
    |> change(Map.take(attrs, [:title, :source_branch, :target_branch, :openspec_change]))
    |> put_change(:links, links)
    |> put_change(:link_tickets, link_list(links, "tickets", &String.downcase(&1, :ascii)))
    |> put_change(:link_threads, link_list(links, "threads", & &1))
    |> validate_required([:number, :title, :source_branch, :target_branch, :state])
    |> unique_constraint(:number, name: :change_requests_project_id_number_index)
  end

  defp link_list(%{} = links, key, fun), do: links |> Map.get(key, []) |> Enum.map(fun)
  defp link_list(nil, _key, _fun), do: []

  @doc "Changes `state` (and `closed_from_state` when closing)."
  @spec state_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def state_changeset(%__MODULE__{state: from} = change_request, "closed") do
    change(change_request, state: "closed", closed_from_state: from)
  end

  def state_changeset(change_request, to) when to in @states do
    change(change_request, state: to, closed_from_state: nil)
  end

  @doc "Makes `head` the change request's current head."
  @spec head_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def head_changeset(change_request, head), do: change(change_request, head: head)

  @doc """
  Records the merge: `merge` holds `merged_commit`, `target_branch`,
  `merged_at`, `head`, `verdict_state`, `policy_version`, `reasons` and
  `merged_without_mergeable_verdict`.
  """
  @spec merge_changeset(t(), map()) :: Ecto.Changeset.t()
  def merge_changeset(change_request, merge) do
    change(change_request,
      state: "merged",
      closed_from_state: nil,
      merged_commit: merge.merged_commit,
      merged_target_branch: merge.target_branch,
      merged_at: merge.merged_at,
      merged_head: merge.head,
      merged_verdict_state: merge.verdict_state,
      merged_policy_version: merge.policy_version,
      merged_reasons: merge.reasons,
      merged_without_mergeable_verdict: merge.merged_without_mergeable_verdict
    )
  end
end
