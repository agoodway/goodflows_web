defmodule GoodFlows.Caches.Entry do
  @moduledoc """
  A cache reservation or committed cache entry (`cache_entries`).

  `id` is also the reservation's `upload_id`. A row starts `reserved` with
  an `expires_at`, and commit makes it `committed` with `committed_at` and
  `last_accessed_at` and no `expires_at` (a check constraint enforces the
  pairing). `(project_id, scope, key)` is unique, so a reservation holds its
  slot. `object_key` (`caches/<project_id>/<id>`) is chosen by the server.

  `upload_expires_at` is when the presigned upload URL (or every part URL)
  expires; the URLs never outlive it.

  A reservation made with `parts` records its S3 multipart upload in
  `multipart_upload_id`, `part_size` and `part_md5s` (the declared base64
  MD5s in part order); the three are all set or all null (check
  constraint) and stay after commit.

  Rows are written only by `GoodFlows.Caches`; there is no user changeset.
  Deleting a row queues its object in `cache_object_deletions` (database
  trigger). A single-PUT object is deleted no earlier than
  `upload_expires_at`, so no new PUT can start after the object is
  deleted. A multipart row is queued with its upload id for immediate
  abort: part PUTs never create an object.
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
    field :multipart_upload_id, :string
    field :part_size, :integer
    field :part_md5s, {:array, :string}

    belongs_to :account, Account
    belongs_to :project, Project
    belongs_to :reserved_by_api_key, ApiKey
  end

  @doc "The object key of upload `id` in `project_id`."
  @spec object_key(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def object_key(project_id, id), do: "caches/#{project_id}/#{id}"

  @doc "Whether the entry was reserved with `parts` (an S3 multipart upload)."
  @spec multipart?(t()) :: boolean()
  def multipart?(%__MODULE__{multipart_upload_id: upload_id}), do: upload_id != nil
end
