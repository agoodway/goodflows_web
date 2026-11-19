defmodule GoodFlows.Caches do
  @moduledoc """
  Remote job caches: immutable, branch-scoped entries whose archive bytes
  live in object storage (`GoodFlows.Caches.ObjectStore`).

  A client reserves a key in one scope (`reserve/5`), PUTs the archive to
  the presigned upload URL, and commits (`commit/3`), which checks the
  stored object's size and SHA-256 before the entry becomes visible. Keys
  are unique per project and scope; a reservation holds its slot until it
  expires.

  Lookups (`lookup_key/4`, `lookup_partial/4`) read the requested scope and
  then the project's default-branch scope, never any other scope. A hit
  renews the entry's last-access time when it is more than an hour old.

  Committed entries and unexpired reservations count toward the project's
  byte quota and entry cap. A reservation that does not fit evicts
  committed entries, least recently accessed first, and is refused with
  `:quota_exceeded` when unexpired reservations alone fill the quota.

  Deleting a row by any means queues its object for deletion (database
  trigger); `GoodFlows.Caches.Sweep` deletes queued objects once the row's
  upload URL has expired. Presigned URLs
  are credentials and are never logged.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias GoodFlows.Accounts.{Account, ApiKey}
  alias GoodFlows.Caches.{Cursor, Entry, ObjectStore, Rules}
  alias GoodFlows.{ChangesetErrors, KeysetCursor}
  alias GoodFlows.Projects.Project
  alias GoodFlows.Repo
  alias GoodFlows.WorkflowRuns.Validator

  @touch_after_seconds 3_600
  @default_page_size 50
  @max_page_size 200
  @reservation_fields ~w(name partial scope size sha256)

  @typedoc "A presigned download URL and when it expires."
  @type download :: %{url: String.t(), expires_at: DateTime.t()}

  @typedoc "A reservation and its presigned upload."
  @type reservation :: %{
          entry: Entry.t(),
          upload_url: String.t(),
          upload_headers: ObjectStore.upload_headers(),
          upload_url_expires_at: DateTime.t()
        }

  @typedoc "Errors a cache operation reports to the API."
  @type error ::
          :not_found
          | :forbidden
          | :cache_conflict
          | :entry_too_large
          | :quota_exceeded
          | :object_store_unavailable
          | Changeset.t()
          | {:unprocessable, String.t()}

  ## Settings

  @doc "Reads a cache setting such as `:cache_max_entry_bytes`."
  @spec setting(atom()) :: pos_integer()
  def setting(key), do: Application.fetch_env!(:good_flows, key)

  ## Lookups

  @doc """
  The scopes a lookup reads, in order: `scope` then the project's default
  branch, or only the default branch when `scope` is `nil`.
  """
  @spec lookup_scopes(Project.t(), String.t() | nil) :: [String.t()]
  def lookup_scopes(%Project{default_branch: default}, nil), do: [default]
  def lookup_scopes(%Project{default_branch: default}, scope), do: Enum.uniq([scope, default])

  @doc """
  Finds committed entry `key` in the first scope of the lookup order that
  has it. Reservations are never returned.
  """
  @spec lookup_key(Account.t(), Project.t(), String.t(), String.t() | nil) ::
          {:ok, Entry.t()} | {:error, :not_found}
  def lookup_key(%Account{id: account_id}, %Project{account_id: account_id} = project, key, scope) do
    project
    |> lookup_scopes(scope)
    |> find_first(fn lookup_scope ->
      project.id |> committed(lookup_scope) |> where([e], e.key == ^key)
    end)
  end

  def lookup_key(%Account{}, %Project{}, _key, _scope), do: {:error, :not_found}

  @doc """
  Finds the newest committed entry with `partial` (`committed_at`, then
  `id`, descending) in the first scope of the lookup order that has one. A
  newer entry in a later scope never wins over the first scope's entry.
  """
  @spec lookup_partial(Account.t(), Project.t(), String.t(), String.t() | nil) ::
          {:ok, Entry.t()} | {:error, :not_found}
  def lookup_partial(
        %Account{id: account_id},
        %Project{account_id: account_id} = project,
        partial,
        scope
      ) do
    project
    |> lookup_scopes(scope)
    |> find_first(fn lookup_scope ->
      project.id
      |> committed(lookup_scope)
      |> where([e], e.partial == ^partial)
      |> order_by([e], desc: e.committed_at, desc: e.id)
    end)
  end

  def lookup_partial(%Account{}, %Project{}, _partial, _scope), do: {:error, :not_found}

  @doc "Presigns a download of a committed entry's object."
  @spec download(Entry.t()) :: download()
  def download(%Entry{object_key: object_key}) do
    ttl = setting(:cache_download_url_ttl_seconds)
    %{url: ObjectStore.presign_get(object_key, %{expires_in: ttl}), expires_at: expires_at(ttl)}
  end

  defp committed(project_id, scope) do
    where(Entry, [e], e.project_id == ^project_id and e.scope == ^scope and e.state == :committed)
  end

  defp find_first(scopes, query_for) do
    Enum.find_value(scopes, {:error, :not_found}, fn scope ->
      case scope |> query_for.() |> limit(1) |> Repo.one() do
        nil -> nil
        entry -> {:ok, touch(entry)}
      end
    end)
  end

  # Renews the last-access time only when the stored one is more than an
  # hour old, so a hot cache does not write a row on every restore.
  defp touch(%Entry{} = entry) do
    now = DateTime.utc_now()
    threshold = DateTime.add(now, -@touch_after_seconds, :second)

    if DateTime.before?(entry.last_accessed_at, threshold) do
      {count, _rows} =
        Entry
        |> where([e], e.id == ^entry.id and e.last_accessed_at < ^threshold)
        |> Repo.update_all(set: [last_accessed_at: now])

      if count == 1, do: %{entry | last_accessed_at: now}, else: entry
    else
      entry
    end
  end

  ## Reserve

  @doc """
  Reserves `key` in the body's `scope` for `api_key` and presigns its upload.

  `attrs` is the decoded JSON body: `name`, `partial`, `scope`, `size` and
  `sha256`, all required, and no other key. Errors, in order:
  `:forbidden` when the key cannot write at all or is bound to another
  scope than the one sent, `:not_found` for a malformed `key`, an invalid
  body (changeset), `:forbidden` when
  the key may not write the validated scope,
  `:entry_too_large` above the entry cap, `:cache_conflict` when the key is
  committed or reserved and unexpired in that scope, and `:quota_exceeded`
  when unexpired reservations leave no room. An expired reservation in the
  slot is replaced. Reservations of one project are serialized by a
  `FOR NO KEY UPDATE` lock on the project row.
  """
  @spec reserve(Account.t(), Project.t(), ApiKey.t(), String.t(), map()) ::
          {:ok, reservation()} | {:error, error()}
  def reserve(
        %Account{id: account_id},
        %Project{account_id: account_id} = project,
        %ApiKey{} = api_key,
        key,
        attrs
      )
      when is_map(attrs) do
    with :ok <- ApiKey.precheck_cache_access(api_key, project, attrs["scope"], :write),
         true <- Rules.valid_hex64?(key) || {:error, :not_found},
         {:ok, params} <- reservation_params(attrs),
         :ok <- ApiKey.cache_access(api_key, project, params.scope, :write),
         :ok <- check_size(params.size),
         upload = presign_upload(project, params),
         {:ok, entry} <- insert_reservation(project, api_key, key, params, upload) do
      {:ok,
       %{
         entry: entry,
         upload_url: upload.url,
         upload_headers: upload.headers,
         upload_url_expires_at: DateTime.truncate(upload.expires_at, :second)
       }}
    end
  end

  def reserve(%Account{}, %Project{}, _api_key, _key, _attrs), do: {:error, :not_found}

  defp reservation_params(attrs) do
    types = %{name: :string, partial: :string, scope: :string, size: :integer, sha256: :string}
    unknown = ChangesetErrors.unknown_keys(attrs, @reservation_fields, "is not allowed")

    {%{}, types}
    |> Changeset.cast(attrs, Map.keys(types), empty_values: [])
    |> Changeset.validate_required(Map.keys(types))
    |> validate_integer(attrs, "size", :size)
    |> Changeset.validate_number(:size, greater_than_or_equal_to: 1)
    |> Rules.validate([:name, :partial, :scope, :sha256])
    |> ChangesetErrors.prepend(unknown)
    |> Changeset.apply_action(:reserve)
  end

  # Ecto casts `"100"` to an integer; the wire contract wants a JSON integer.
  defp validate_integer(changeset, attrs, key, field) do
    case Map.fetch(attrs, key) do
      {:ok, value} when not is_integer(value) and not is_nil(value) ->
        changeset
        |> Changeset.delete_change(field)
        |> Changeset.add_error(field, "must be an integer")

      _other ->
        changeset
    end
  end

  defp check_size(size) do
    if size > setting(:cache_max_entry_bytes), do: {:error, :entry_too_large}, else: :ok
  end

  # Signs the upload of a new object before its row exists, so the row can
  # record an `upload_expires_at` no earlier than the URL's expiry: the time
  # is taken after signing.
  defp presign_upload(project, params) do
    id = Ecto.UUID.generate()
    object_key = Entry.object_key(project.id, id)
    ttl = setting(:cache_upload_url_ttl_seconds)

    {url, headers} =
      ObjectStore.presign_put(object_key, %{
        size: params.size,
        sha256: params.sha256,
        expires_in: ttl
      })

    %{
      id: id,
      object_key: object_key,
      url: url,
      headers: headers,
      expires_at: DateTime.add(DateTime.utc_now(), ttl, :second)
    }
  end

  defp insert_reservation(project, api_key, key, params, upload) do
    Repo.transaction(fn ->
      lock_project!(project.id)
      now = DateTime.utc_now()

      Entry
      |> where([e], e.project_id == ^project.id and e.scope == ^params.scope and e.key == ^key)
      |> where([e], e.state == :reserved and e.expires_at <= ^now)
      |> Repo.delete_all()

      if slot_taken?(project.id, params.scope, key), do: Repo.rollback(:cache_conflict)

      make_room!(project.id, params.size, now)
      insert_entry!(project, api_key, key, params, upload, now)
    end)
  end

  defp lock_project!(project_id) do
    # NO KEY UPDATE serializes reserves without blocking the `FOR KEY SHARE`
    # locks that inserts into the project's child tables take.
    Project |> where([p], p.id == ^project_id) |> lock("FOR NO KEY UPDATE") |> Repo.one!()
  end

  defp slot_taken?(project_id, scope, key) do
    Entry
    |> where([e], e.project_id == ^project_id and e.scope == ^scope and e.key == ^key)
    |> Repo.exists?()
  end

  # Evicts committed entries, least recently accessed first, until a new
  # reservation of `size` bytes fits both limits; rolls back with
  # `:quota_exceeded` (evicting nothing) when even evicting every committed
  # entry is not enough.
  defp make_room!(project_id, size, now) do
    quota = setting(:cache_project_quota_bytes)
    max_entries = setting(:cache_project_max_entries)
    %{bytes: bytes, entries: entries} = usage_counts(project_id, now)

    if bytes + size > quota or entries + 1 > max_entries do
      candidates =
        Entry
        |> where([e], e.project_id == ^project_id and e.state == :committed)
        |> order_by([e], asc: e.last_accessed_at, asc: e.id)
        |> select([e], {e.id, e.size})
        |> Repo.all()

      case pick_evictions(candidates, bytes + size - quota, entries + 1 - max_entries) do
        {:ok, ids} -> Entry |> where([e], e.id in ^ids) |> Repo.delete_all()
        :error -> Repo.rollback(:quota_exceeded)
      end
    end

    :ok
  end

  defp pick_evictions(candidates, excess_bytes, excess_entries) do
    Enum.reduce_while(candidates, {[], excess_bytes, excess_entries}, fn
      _candidate, {ids, bytes, count} when bytes <= 0 and count <= 0 ->
        {:halt, {ids, bytes, count}}

      {id, size}, {ids, bytes, count} ->
        {:cont, {[id | ids], bytes - size, count - 1}}
    end)
    |> case do
      {ids, bytes, count} when bytes <= 0 and count <= 0 -> {:ok, ids}
      _not_enough -> :error
    end
  end

  defp insert_entry!(project, api_key, key, params, upload, now) do
    %Entry{
      id: upload.id,
      account_id: project.account_id,
      project_id: project.id,
      scope: params.scope,
      key: key,
      partial: params.partial,
      name: params.name,
      size: params.size,
      sha256: params.sha256,
      object_key: upload.object_key,
      state: :reserved,
      reserved_by_api_key_id: api_key.id,
      expires_at: DateTime.add(now, setting(:cache_reservation_ttl_seconds), :second),
      upload_expires_at: upload.expires_at,
      inserted_at: now
    }
    |> Changeset.change()
    |> Changeset.unique_constraint([:project_id, :scope, :key],
      name: :cache_entries_project_id_scope_key_index
    )
    |> Repo.insert()
    |> case do
      {:ok, entry} -> entry
      {:error, _changeset} -> Repo.rollback(:cache_conflict)
    end
  end

  ## Commit

  @doc """
  Commits upload `upload_id` reserved by `api_key`.

  `:not_found` when the upload is not in the project, has expired, was
  reserved by another key, or `upload_id` is not a lowercase UUID. An
  upload this key already committed is returned again. Otherwise the
  object's length and recorded SHA-256 must match the reservation; when
  they do not, or the object is missing or has no SHA-256, the reservation
  is deleted (queueing its object) and the error is `422` on `upload`.
  """
  @spec commit(Project.t(), ApiKey.t(), term()) :: {:ok, Entry.t()} | {:error, error()}
  def commit(%Project{} = project, %ApiKey{id: api_key_id}, upload_id) do
    with {:ok, entry} <- fetch_upload(project, api_key_id, upload_id) do
      case entry.state do
        :committed -> {:ok, entry}
        :reserved -> verify_and_commit(entry, api_key_id)
      end
    end
  end

  defp fetch_upload(project, api_key_id, upload_id) do
    with true <- Validator.canonical_uuid?(upload_id),
         %Entry{reserved_by_api_key_id: ^api_key_id} = entry <-
           Repo.get_by(Entry, project_id: project.id, id: upload_id),
         true <-
           entry.state == :committed or DateTime.after?(entry.expires_at, DateTime.utc_now()) do
      {:ok, entry}
    else
      _other -> {:error, :not_found}
    end
  end

  defp verify_and_commit(entry, api_key_id) do
    with :ok <- verify_object(entry) do
      now = DateTime.utc_now()

      {count, _rows} =
        Entry
        |> where([e], e.id == ^entry.id and e.state == :reserved and e.expires_at > ^now)
        |> Repo.update_all(
          set: [state: :committed, committed_at: now, last_accessed_at: now, expires_at: nil]
        )

      committed = %{
        entry
        | state: :committed,
          committed_at: now,
          last_accessed_at: now,
          expires_at: nil
      }

      if count == 1, do: {:ok, committed}, else: reload_committed(entry.id, api_key_id)
    end
  end

  # The update matched nothing: a concurrent commit by the same key won, or
  # the reservation expired meanwhile.
  defp reload_committed(id, api_key_id) do
    case Repo.get(Entry, id) do
      %Entry{state: :committed, reserved_by_api_key_id: ^api_key_id} = entry -> {:ok, entry}
      _other -> {:error, :not_found}
    end
  end

  defp verify_object(entry) do
    expected = entry.sha256 |> Base.decode16!(case: :lower) |> Base.encode64()
    size = entry.size

    case ObjectStore.head(entry.object_key) do
      {:ok, %{size: ^size, checksum_sha256: ^expected}} -> :ok
      {:ok, %{size: ^size}} -> reject_upload(entry, "has the wrong checksum")
      {:ok, _info} -> reject_upload(entry, "has the wrong size")
      {:error, :not_found} -> reject_upload(entry, "is missing")
      {:error, _reason} -> {:error, :object_store_unavailable}
    end
  end

  defp reject_upload(entry, message) do
    Entry |> where([e], e.id == ^entry.id and e.state == :reserved) |> Repo.delete_all()

    changeset =
      {%{}, %{upload: :string}}
      |> Changeset.change()
      |> Changeset.add_error(:upload, message)

    {:error, changeset}
  end

  ## List and usage

  @doc """
  Lists committed entries newest first (`committed_at`, then `id`,
  descending), filtered by exact `name` and `scope`, keyset-paged by
  `limit` (1 to 200, default 50) and `cursor`, with the project's usage.
  """
  @spec list(Account.t(), Project.t(), map()) ::
          {:ok, %{entries: [Entry.t()], next_cursor: String.t() | nil, usage: map()}}
          | {:error, Changeset.t() | :not_found}
  def list(%Account{id: account_id}, %Project{account_id: account_id} = project, params) do
    with {:ok, filters} <- list_params(params) do
      entries =
        Entry
        |> where([e], e.project_id == ^project.id and e.state == :committed)
        |> filter(:name, filters.name)
        |> filter(:scope, filters.scope)
        |> after_cursor(filters.cursor)
        |> order_by([e], desc: e.committed_at, desc: e.id)
        |> limit(^(filters.limit + 1))
        |> Repo.all()

      {page, rest} = Enum.split(entries, filters.limit)

      next_cursor =
        if rest != [] do
          last = List.last(page)
          Cursor.encode(last.committed_at, last.id)
        end

      {:ok, %{entries: page, next_cursor: next_cursor, usage: usage(project)}}
    end
  end

  def list(%Account{}, %Project{}, _params), do: {:error, :not_found}

  @doc """
  The project's usage: `bytes` and `entries` of committed entries and
  unexpired reservations, plus the configured `quota_bytes` and
  `max_entries`.
  """
  @spec usage(Project.t()) :: map()
  def usage(%Project{id: project_id}) do
    project_id
    |> usage_counts(DateTime.utc_now())
    |> Map.merge(%{
      quota_bytes: setting(:cache_project_quota_bytes),
      max_entries: setting(:cache_project_max_entries)
    })
  end

  defp usage_counts(project_id, now) do
    Entry
    |> where([e], e.project_id == ^project_id)
    |> where([e], e.state == :committed or e.expires_at > ^now)
    |> select([e], %{
      bytes: fragment("COALESCE(SUM(?), 0)::bigint", e.size),
      entries: count(e.id)
    })
    |> Repo.one!()
  end

  defp list_params(params) do
    types = %{limit: :integer, cursor: :string, name: :string, scope: :string}

    {%{limit: @default_page_size, cursor: nil, name: nil, scope: nil}, types}
    |> Changeset.cast(params, Map.keys(types), empty_values: [])
    |> Changeset.validate_number(:limit,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_page_size
    )
    |> KeysetCursor.put_cursor(&Cursor.decode/1)
    |> Rules.validate([:name, :scope])
    |> Changeset.apply_action(:list)
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {at, id}) do
    where(query, [e], e.committed_at < ^at or (e.committed_at == ^at and e.id < ^id))
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, field, value), do: where(query, [e], field(e, ^field) == ^value)

  ## Purge

  @doc """
  Deletes the entry or reservation of `key` in `params["scope"]` (required)
  and returns how many rows were deleted (`0` or `1`).
  """
  @spec delete(Project.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, Changeset.t() | :not_found}
  def delete(%Project{id: project_id}, key, params) do
    with true <- Rules.valid_hex64?(key) || {:error, :not_found},
         {:ok, %{scope: scope}} <- validate_query(params, [:scope], [:scope]) do
      {count, _rows} =
        Entry
        |> where([e], e.project_id == ^project_id and e.scope == ^scope and e.key == ^key)
        |> Repo.delete_all()

      {:ok, count}
    end
  end

  @doc """
  Deletes every entry and reservation matching all of the given `name`,
  `scope` and `partial` filters and returns the count. At least one filter
  is required.
  """
  @spec delete_matching(Project.t(), map()) ::
          {:ok, non_neg_integer()} | {:error, Changeset.t() | {:unprocessable, String.t()}}
  def delete_matching(%Project{id: project_id}, params) do
    with {:ok, filters} <- validate_query(params, [:name, :scope, :partial], []),
         true <-
           Enum.any?(filters, fn {_field, value} -> value != nil end) ||
             {:error, {:unprocessable, "Give at least one of name, scope or partial"}} do
      {count, _rows} =
        Entry
        |> where([e], e.project_id == ^project_id)
        |> filter(:name, filters.name)
        |> filter(:scope, filters.scope)
        |> filter(:partial, filters.partial)
        |> Repo.delete_all()

      {:ok, count}
    end
  end

  @doc """
  Validates the string query `fields` of `params` (the scope, name and
  partial rules), requiring `required`. A field not sent is `nil`.
  """
  @spec validate_query(map(), [atom()], [atom()]) ::
          {:ok, %{atom() => String.t() | nil}} | {:error, Changeset.t()}
  def validate_query(params, fields, required) do
    types = Map.new(fields, &{&1, :string})

    {Map.new(fields, &{&1, nil}), types}
    |> Changeset.cast(params, fields, empty_values: [])
    |> Changeset.validate_required(required)
    |> Rules.validate(fields)
    |> Changeset.apply_action(:validate)
  end

  defp expires_at(ttl_seconds),
    do: DateTime.utc_now(:second) |> DateTime.add(ttl_seconds, :second)
end
