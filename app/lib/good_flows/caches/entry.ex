defmodule GoodFlows.Caches.Entry do
  @moduledoc """
  A cache reservation or committed cache entry (`cache_entries`).

  `id` is also the reservation's `upload_id`. A row starts `reserved` with
  an `expires_at`, and commit makes it `committed` with `committed_at` and
  `last_accessed_at` and no `expires_at` (a check constraint enforces the
  pairing). `(project_id, scope, key)` is unique, so a reservation holds its
  slot. `object_key` (`caches/<project_id>/<id>`) is chosen by the server.

  `upload_expires_at` is when the presigned upload URL expires; the URL
  never outlives it.

  Rows are written only by `GoodFlows.Caches`; there is no user changeset.
  Deleting a row queues its object in `cache_object_deletions` (database
  trigger), to be deleted no earlier than `upload_expires_at`, so no new
  PUT can start after the object is deleted.
  """
  use Ecto.Schema

  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.Projects.Project

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "cache_entries" do
    field :scope, :string
    field :key, :string
    field :partial, :string
    field :name, :string
    field :size, :integer
    field :sha256, :string
    field :object_key, :string
    field :state, Ecto.Enum, values: [:reserved, :committed]
    field :expires_at, :utc_datetime_usec
    field :upload_expires_at, :utc_datetime_usec
    field :committed_at, :utc_datetime_usec
    field :last_accessed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :account, Account
    belongs_to :project, Project
    belongs_to :reserved_by_api_key, ApiKey
  end

  @doc "The object key of upload `id` in `project_id`."
  @spec object_key(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def object_key(project_id, id), do: "caches/#{project_id}/#{id}"
end
