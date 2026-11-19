defmodule GoodFlows.CacheFixtures do
  @moduledoc "Cache keys, entries and reservations for tests."

  alias GoodFlows.Accounts
  alias GoodFlows.Caches.{Entry, Keys}
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.Repo

  @doc "A 64-character lowercase hex string derived from `seed`."
  def hex(seed), do: :sha256 |> :crypto.hash(inspect(seed)) |> Base.encode16(case: :lower)

  @doc "The account membership of `account`'s owner (the first member)."
  def owner_account_user(account) do
    import Ecto.Query

    Accounts.AccountUser
    |> where(account_id: ^account.id)
    |> order_by(asc: :inserted_at)
    |> limit(1)
    |> Repo.one!()
  end

  @doc "Mints a cache key of `project`; returns `{api_key, token}`."
  def cache_key_fixture(account, project, attrs \\ %{}) do
    attrs = Map.merge(%{"access" => "read_write"}, attrs)
    {:ok, {api_key, token}} = Keys.mint(owner_account_user(account), project, attrs)
    {api_key, token}
  end

  @doc """
  Inserts a committed entry directly and stores its object in the fake.
  Options: `:scope` (default the project's default branch), `:key`,
  `:partial`, `:name`, `:size`, `:sha256`, `:committed_at`,
  `:last_accessed_at`, `:upload_expires_at` (default 15 minutes
  before `committed_at`: the upload URL expired beyond the sweep's
  clock-skew margin).
  """
  def entry_fixture(project, opts \\ []) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    committed_at = Keyword.get(opts, :committed_at, now)
    size = Keyword.get(opts, :size, 100)
    sha256 = Keyword.get(opts, :sha256, hex({:sha, id}))

    entry =
      Repo.insert!(%Entry{
        id: id,
        account_id: project.account_id,
        project_id: project.id,
        scope: Keyword.get(opts, :scope, project.default_branch),
        key: Keyword.get(opts, :key, hex({:key, id})),
        partial: Keyword.get(opts, :partial, hex(:partial)),
        name: Keyword.get(opts, :name, "deps"),
        size: size,
        sha256: sha256,
        object_key: Entry.object_key(project.id, id),
        state: :committed,
        committed_at: committed_at,
        last_accessed_at: Keyword.get(opts, :last_accessed_at, committed_at),
        upload_expires_at:
          Keyword.get(opts, :upload_expires_at, DateTime.add(committed_at, -900, :second)),
        inserted_at: committed_at
      })

    checksum = sha256 |> Base.decode16!(case: :lower) |> Base.encode64()
    Fake.put_object(entry.object_key, size, checksum)
    entry
  end

  @doc """
  Inserts a reservation directly. Options: `:scope`, `:key`, `:size`,
  `:expires_at` (default two hours from now), `:upload_expires_at` (default
  15 minutes ago: the upload URL expired beyond the sweep's clock-skew
  margin), `:api_key_id`.
  """
  def reservation_fixture(project, opts \\ []) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.insert!(%Entry{
      id: id,
      account_id: project.account_id,
      project_id: project.id,
      scope: Keyword.get(opts, :scope, project.default_branch),
      key: Keyword.get(opts, :key, hex({:key, id})),
      partial: Keyword.get(opts, :partial, hex(:partial)),
      name: Keyword.get(opts, :name, "deps"),
      size: Keyword.get(opts, :size, 100),
      sha256: Keyword.get(opts, :sha256, hex({:sha, id})),
      object_key: Entry.object_key(project.id, id),
      state: :reserved,
      reserved_by_api_key_id: Keyword.get(opts, :api_key_id),
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(now, 7_200, :second)),
      upload_expires_at: Keyword.get(opts, :upload_expires_at, DateTime.add(now, -900, :second)),
      inserted_at: now
    })
  end

  @doc "A valid reservation body for an archive `body`."
  def reservation_body(body, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "deps",
        "partial" => hex(:partial),
        "scope" => "main",
        "size" => byte_size(body),
        "sha256" => :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
      },
      overrides
    )
  end
end
