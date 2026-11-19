defmodule GoodFlows.CachesTest do
  use GoodFlows.DataCase, async: true

  import Ecto.Query
  import GoodFlows.AccountsFixtures
  import GoodFlows.CacheFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Accounts
  alias GoodFlows.Caches
  alias GoodFlows.Caches.{Entry, ObjectStore, Sweep}
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.Repo

  @gib 1_073_741_824

  setup do
    user = user_fixture()
    {:ok, account} = Accounts.create_account(user, %{name: "Caches #{System.unique_integer()}"})
    account_user = Accounts.get_account_user(user, account)
    {sk_key, _token} = api_key_fixture(account_user, %{type: :private})
    project = project_fixture(account)
    %{account: account, account_user: account_user, sk_key: sk_key, project: project}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp reserve(ctx, key, body_or_attrs, api_key \\ nil)

  defp reserve(ctx, key, body, api_key) when is_binary(body),
    do: reserve(ctx, key, reservation_body(body), api_key)

  defp reserve(ctx, key, attrs, api_key),
    do: Caches.reserve(ctx.account, ctx.project, api_key || ctx.sk_key, key, attrs)

  defp queued?(object_key) do
    Repo.exists?(from d in "cache_object_deletions", where: d.object_key == ^object_key)
  end

  # The row is gone and its object queued: sweeps leave the object alone
  # until the upload URL has expired and the sweep's 60-second clock-skew
  # margin has passed, then delete it.
  defp assert_deleted_after_upload_url(reservation) do
    %{entry: entry, upload_url_expires_at: url_expires_at} = reservation
    object_key = entry.object_key
    refute Repo.get(Entry, entry.id)
    assert DateTime.diff(entry.upload_expires_at, DateTime.utc_now()) in 890..900
    assert DateTime.compare(url_expires_at, entry.upload_expires_at) != :gt

    delete_after =
      Repo.one!(
        from d in "cache_object_deletions",
          where: d.object_key == ^object_key,
          select: d.delete_after
      )

    assert DateTime.compare(
             DateTime.from_naive!(delete_after, "Etc/UTC"),
             entry.upload_expires_at
           ) ==
             :eq

    Sweep.run()
    assert Fake.exists?(object_key)
    assert queued?(object_key)

    # The upload URL expired 30 seconds ago: still within the margin.
    set_delete_after(object_key, ago(30))
    Sweep.run()
    assert Fake.exists?(object_key)
    assert queued?(object_key)

    # Past the margin.
    set_delete_after(object_key, ago(61))
    Sweep.run()
    refute Fake.exists?(object_key)
    refute queued?(object_key)
  end

  defp set_delete_after(object_key, at) do
    Repo.update_all(from(d in "cache_object_deletions", where: d.object_key == ^object_key),
      set: [delete_after: DateTime.to_naive(at)]
    )
  end

  defp queue_count(object_key) do
    Repo.aggregate(
      from(d in "cache_object_deletions", where: d.object_key == ^object_key),
      :count
    )
  end

  describe "deletion queue (4.1)" do
    test "deleting an entry queues its object once", ctx do
      entry = entry_fixture(ctx.project)
      Repo.delete!(entry)
      assert queue_count(entry.object_key) == 1
    end

    test "deleting a project queues its entries' objects and deletes its cache keys", ctx do
      entry = entry_fixture(ctx.project)
      reservation = reservation_fixture(ctx.project)
      {cache_key, _token} = cache_key_fixture(ctx.account, ctx.project)

      assert :ok = GoodFlows.Projects.delete_project(ctx.account, ctx.project)
      assert queue_count(entry.object_key) == 1
      assert queue_count(reservation.object_key) == 1
      refute Repo.get(GoodFlows.Accounts.ApiKey, cache_key.id)
    end

    test "a multipart row is queued with its upload id at once; a single-PUT row waits", ctx do
      future = DateTime.add(DateTime.utc_now(), 900, :second)
      md5 = Base.encode64(:crypto.hash(:md5, "p"))

      multipart =
        reservation_fixture(ctx.project,
          upload_expires_at: future,
          multipart: {"up+load/id=", 5_242_880, [md5]}
        )

      single = reservation_fixture(ctx.project, upload_expires_at: future)
      before = DateTime.utc_now()
      Repo.delete!(multipart)
      Repo.delete!(single)

      rows =
        Repo.all(
          from d in "cache_object_deletions",
            select: {d.object_key, {d.multipart_upload_id, d.delete_after}}
        )
        |> Map.new()

      {"up+load/id=", multipart_after} = rows[multipart.object_key]
      multipart_after = DateTime.from_naive!(multipart_after, "Etc/UTC")
      assert DateTime.diff(multipart_after, before, :second) in -1..1

      {nil, single_after} = rows[single.object_key]
      assert DateTime.compare(DateTime.from_naive!(single_after, "Etc/UTC"), future) == :eq
    end

    test "the multipart columns are all set or all null", ctx do
      assert_raise Ecto.ConstraintError, ~r/cache_entries_multipart_check/, fn ->
        reservation_fixture(ctx.project, multipart: {"id", nil, nil})
      end
    end

    test "deleting an account queues its entries' objects once", ctx do
      entry = entry_fixture(ctx.project)
      Repo.delete!(ctx.account)
      assert queue_count(entry.object_key) == 1
      refute Repo.get(Entry, entry.id)
    end
  end

  describe "lookups (4.2)" do
    test "an exact hit in the requested scope wins over the default branch", ctx do
      key = hex(:k)
      feature = entry_fixture(ctx.project, key: key, scope: "feature/login")
      entry_fixture(ctx.project, key: key, scope: "main")

      assert {:ok, %{id: id, scope: "feature/login"}} =
               Caches.lookup_key(ctx.account, ctx.project, key, "feature/login")

      assert id == feature.id
    end

    test "an exact lookup falls back to the default branch", ctx do
      key = hex(:k)
      entry_fixture(ctx.project, key: key, scope: "main")

      assert {:ok, %{scope: "main"}} =
               Caches.lookup_key(ctx.account, ctx.project, key, "feature/login")
    end

    test "another branch is never read, and no scope reads only the default", ctx do
      key = hex(:k)
      entry_fixture(ctx.project, key: key, scope: "feature/other")
      entry_fixture(ctx.project, key: hex(:k2), scope: "feature/login")

      assert {:error, :not_found} =
               Caches.lookup_key(ctx.account, ctx.project, key, "feature/login")

      assert {:error, :not_found} = Caches.lookup_key(ctx.account, ctx.project, hex(:k2), nil)
    end

    test "a reservation is invisible", ctx do
      reservation = reservation_fixture(ctx.project, scope: "main")

      assert {:error, :not_found} =
               Caches.lookup_key(ctx.account, ctx.project, reservation.key, "main")

      assert {:error, :not_found} =
               Caches.lookup_partial(ctx.account, ctx.project, reservation.partial, "main")
    end

    test "the default branch follows the project", ctx do
      key = hex(:k)
      entry_fixture(ctx.project, key: key, scope: "trunk")

      {:ok, project} =
        GoodFlows.Projects.update_project(ctx.account, ctx.project, %{"default_branch" => "trunk"})

      assert {:ok, %{scope: "trunk"}} = Caches.lookup_key(ctx.account, project, key, "feature/x")
    end

    test "a partial lookup returns the newest of one scope", ctx do
      p = hex(:p)
      entry_fixture(ctx.project, partial: p, committed_at: ago(7200))
      newer = entry_fixture(ctx.project, partial: p, committed_at: ago(3600))

      assert {:ok, %{id: id}} = Caches.lookup_partial(ctx.account, ctx.project, p, "main")
      assert id == newer.id
    end

    test "a newer default-branch entry does not beat the requested scope", ctx do
      p = hex(:p)

      feature =
        entry_fixture(ctx.project, partial: p, scope: "feature/login", committed_at: ago(7200))

      entry_fixture(ctx.project, partial: p, scope: "main", committed_at: ago(60))

      assert {:ok, %{id: id}} =
               Caches.lookup_partial(ctx.account, ctx.project, p, "feature/login")

      assert id == feature.id
    end

    test "equal committed_at is ordered by id", ctx do
      p = hex(:p)
      at = ago(100)
      entries = for _ <- 1..3, do: entry_fixture(ctx.project, partial: p, committed_at: at)
      expected = entries |> Enum.map(& &1.id) |> Enum.max()

      assert {:ok, %{id: ^expected}} = Caches.lookup_partial(ctx.account, ctx.project, p, nil)
    end

    test "a hit renews last access only when it is more than an hour old", ctx do
      fresh = entry_fixture(ctx.project, key: hex(:fresh), last_accessed_at: ago(3_540))
      stale = entry_fixture(ctx.project, key: hex(:stale), last_accessed_at: ago(3_660))

      {:ok, _} = Caches.lookup_key(ctx.account, ctx.project, fresh.key, "main")
      {:ok, hit} = Caches.lookup_key(ctx.account, ctx.project, stale.key, "main")

      assert DateTime.compare(Repo.get!(Entry, fresh.id).last_accessed_at, fresh.last_accessed_at) ==
               :eq

      renewed = Repo.get!(Entry, stale.id).last_accessed_at
      assert DateTime.diff(DateTime.utc_now(), renewed) < 5
      assert hit.last_accessed_at == renewed
    end

    test "a restore of an entry last read six days ago keeps it through the sweep", ctx do
      entry = entry_fixture(ctx.project, last_accessed_at: ago(6 * 86_400))
      {:ok, _} = Caches.lookup_key(ctx.account, ctx.project, entry.key, "main")

      Sweep.run()
      assert Repo.get(Entry, entry.id)
    end
  end

  describe "reserve (4.3)" do
    test "reserves a key and presigns its upload with the signed headers", ctx do
      body = :crypto.strong_rand_bytes(64)
      assert {:ok, r} = reserve(ctx, hex(:k), body)

      assert r.entry.state == :reserved
      assert r.entry.object_key == "caches/#{ctx.project.id}/#{r.entry.id}"
      assert r.upload_headers["content-length"] == "64"
      assert r.upload_headers["content-type"] == "application/gzip"

      assert r.upload_headers["x-amz-checksum-sha256"] ==
               :sha256 |> :crypto.hash(body) |> Base.encode64()

      assert DateTime.diff(r.entry.expires_at, DateTime.utc_now()) in 7_190..7_200
      assert DateTime.diff(r.upload_url_expires_at, DateTime.utc_now()) in 890..900
    end

    test "a committed or unexpired key in the same scope is 409; another scope is fine", ctx do
      key = hex(:k)
      committed = entry_fixture(ctx.project, key: key, scope: "main")

      assert {:error, :cache_conflict} = reserve(ctx, key, "x")
      assert Repo.get!(Entry, committed.id).state == :committed

      assert {:ok, _} = reserve(ctx, key, reservation_body("x", %{"scope" => "feature/login"}))

      assert {:error, :cache_conflict} =
               reserve(ctx, key, reservation_body("y", %{"scope" => "feature/login"}))
    end

    test "an expired reservation is replaced and its upload can no longer commit", ctx do
      key = hex(:k)

      old =
        reservation_fixture(ctx.project, key: key, expires_at: ago(1), api_key_id: ctx.sk_key.id)

      assert {:ok, r} = reserve(ctx, key, "x")
      refute r.entry.id == old.id
      refute Repo.get(Entry, old.id)
      assert queued?(old.object_key)
      assert {:error, :not_found} = Caches.commit(ctx.project, ctx.sk_key, old.id)
    end

    test "an entry at the cap fits; one byte more is 413", ctx do
      attrs = reservation_body("x", %{"size" => 5_000_000_000})
      assert {:ok, _} = reserve(ctx, hex(:at_cap), attrs)

      attrs = reservation_body("x", %{"size" => 5_000_000_001})
      assert {:error, :entry_too_large} = reserve(ctx, hex(:over), attrs)
      refute Repo.exists?(from e in Entry, where: e.key == ^hex(:over))
    end

    test "invalid bodies are refused and reserve nothing", ctx do
      base = reservation_body("x")

      cases = [
        {Map.delete(base, "name"), :name},
        {Map.put(base, "size", 0), :size},
        {Map.put(base, "size", 1.5), :size},
        {Map.put(base, "size", "10"), :size},
        {Map.put(base, "partial", String.duplicate("a", 63)), :partial},
        {Map.put(base, "sha256", String.duplicate("A", 64)), :sha256},
        {Map.put(base, "scope", "main\n"), :scope},
        {Map.put(base, "scope", String.duplicate("s", 257)), :scope},
        {Map.put(base, "name", "   "), :name},
        {Map.put(base, "project", "x"), "project"}
      ]

      for {attrs, field} <- cases do
        assert {:error, %Ecto.Changeset{} = cs} = reserve(ctx, hex(:k), attrs)

        assert List.keymember?(cs.errors, field, 0),
               "#{inspect(attrs)} should fail on #{field}"
      end

      assert Repo.aggregate(Entry, :count) == 0
    end

    test "a scope that is not a Git ref is accepted", ctx do
      assert {:ok, %{entry: %{scope: "pr 42..head"}}} =
               reserve(ctx, hex(:k), reservation_body("x", %{"scope" => "pr 42..head"}))
    end

    test "a full project evicts the least recently used entries, across scopes", ctx do
      a =
        entry_fixture(ctx.project,
          scope: "feature/a",
          size: 25 * @gib,
          last_accessed_at: ago(86_400)
        )

      b = entry_fixture(ctx.project, scope: "main", size: 25 * @gib, last_accessed_at: ago(60))

      assert {:ok, _} = reserve(ctx, hex(:new), reservation_body("x", %{"size" => 4_000_000_000}))
      refute Repo.get(Entry, a.id)
      assert Repo.get(Entry, b.id)
      assert queued?(a.object_key)
    end

    test "superseded rolling entries go before an older entry restored recently", ctx do
      p = hex(:rolling)
      r1 = entry_fixture(ctx.project, partial: p, size: 20 * @gib, committed_at: ago(86_400))
      r2 = entry_fixture(ctx.project, partial: p, size: 10 * @gib, committed_at: ago(3_600))

      c =
        entry_fixture(ctx.project,
          size: 20 * @gib,
          committed_at: ago(7 * 86_400),
          last_accessed_at: ago(3_600)
        )

      # r2 was just restored by the partial lookup.
      {:ok, _} = Caches.lookup_partial(ctx.account, ctx.project, p, "main")

      assert {:ok, _} = reserve(ctx, hex(:new), reservation_body("x", %{"size" => 4_000_000_000}))
      refute Repo.get(Entry, r1.id)
      assert Repo.get(Entry, r2.id)
      assert Repo.get(Entry, c.id)
    end

    test "507 when unexpired reservations fill the quota, and nothing is evicted", ctx do
      committed = entry_fixture(ctx.project, size: 2 * @gib, last_accessed_at: ago(86_400))
      reservation_fixture(ctx.project, size: 48 * @gib)

      assert {:error, :quota_exceeded} =
               reserve(ctx, hex(:new), reservation_body("x", %{"size" => 4_000_000_000}))

      assert Repo.get(Entry, committed.id)
      refute Repo.exists?(from e in Entry, where: e.key == ^hex(:new))
    end

    test "an expired reservation does not count toward the quota", ctx do
      reservation_fixture(ctx.project, size: 50 * @gib, expires_at: ago(1))
      assert {:ok, _} = reserve(ctx, hex(:new), reservation_body("x", %{"size" => 4 * @gib}))
    end

    test "at the entry cap the least recently accessed entry is evicted", ctx do
      now = DateTime.utc_now()

      rows =
        for i <- 1..10_000 do
          id = Ecto.UUID.generate()
          at = DateTime.add(now, -i, :second)

          %{
            id: Ecto.UUID.dump!(id),
            account_id: Ecto.UUID.dump!(ctx.account.id),
            project_id: Ecto.UUID.dump!(ctx.project.id),
            scope: "main",
            key: hex({:cap, i}),
            partial: hex(:p),
            name: "deps",
            size: 1,
            sha256: hex(:s),
            object_key: "caches/#{ctx.project.id}/#{id}",
            state: "committed",
            committed_at: at,
            last_accessed_at: at,
            upload_expires_at: at,
            inserted_at: at
          }
        end

      rows |> Enum.chunk_every(2_000) |> Enum.each(&Repo.insert_all("cache_entries", &1))

      assert {:ok, _} = reserve(ctx, hex(:new), "x")
      refute Repo.exists?(from e in Entry, where: e.key == ^hex({:cap, 10_000}))
      assert Repo.exists?(from e in Entry, where: e.key == ^hex({:cap, 9_999}))

      assert Repo.aggregate(from(e in Entry, where: e.project_id == ^ctx.project.id), :count) ==
               10_000
    end
  end

  describe "multipart reserve (3.1, 3.2)" do
    @mib16 16_777_216

    defp md5_of(seed), do: Base.encode64(:crypto.hash(:md5, inspect(seed)))

    defp parts_body(size, part_size, count, overrides \\ %{}) do
      md5s = for n <- 1..count, do: md5_of({:part, n})

      reservation_body("x", %{"size" => size})
      |> Map.put("parts", %{"size" => part_size, "md5" => md5s})
      |> Map.merge(overrides)
    end

    defp prefix(ctx), do: "caches/#{ctx.project.id}/"

    defp deletion_row(object_key) do
      Repo.one(
        from d in "cache_object_deletions",
          where: d.object_key == ^object_key,
          select: {d.multipart_upload_id, d.delete_after}
      )
    end

    defp assert_parts_error(ctx, attrs) do
      assert {:error, %Ecto.Changeset{} = cs} = reserve(ctx, hex(:k), attrs)
      assert List.keymember?(cs.errors, :parts, 0), "#{inspect(attrs)} should fail on parts"
      refute Repo.exists?(from e in Entry, where: e.project_id == ^ctx.project.id)
      assert Fake.uploads(prefix(ctx)) == []
    end

    test "valid parts reserve with part URLs and no single upload URL", ctx do
      attrs = parts_body(52_428_800, @mib16, 4)
      assert {:ok, r} = reserve(ctx, hex(:k), attrs)
      refute Map.has_key?(r, :upload_url)
      refute Map.has_key?(r, :upload_headers)
      assert Enum.map(r.upload_parts, & &1.number) == [1, 2, 3, 4]
      assert r.entry.part_size == @mib16
      assert r.entry.part_md5s == attrs["parts"]["md5"]
      assert Entry.multipart?(r.entry)
      assert [{upload_id, _key, :open}] = Fake.uploads(prefix(ctx))
      assert r.entry.multipart_upload_id == upload_id
    end

    test "the three-part scenario signs each part's length and MD5 for the reservation TTL",
         ctx do
      attrs = parts_body(40_000_000, @mib16, 3)
      assert {:ok, r} = reserve(ctx, hex(:k), attrs)

      assert Enum.map(r.upload_parts, & &1.headers) == [
               %{"content-length" => "16777216", "content-md5" => md5_of({:part, 1})},
               %{"content-length" => "16777216", "content-md5" => md5_of({:part, 2})},
               %{"content-length" => "6445568", "content-md5" => md5_of({:part, 3})}
             ]

      for part <- r.upload_parts do
        query = part.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
        assert query["partNumber"] == Integer.to_string(part.number)
        assert query["uploadId"] == r.entry.multipart_upload_id
        assert query["X-Amz-Expires"] == "7200"
      end

      assert DateTime.diff(r.upload_url_expires_at, DateTime.utc_now()) in 7_190..7_200
      assert DateTime.compare(r.upload_url_expires_at, r.entry.expires_at) != :gt
      assert DateTime.compare(r.entry.upload_expires_at, r.entry.expires_at) != :gt
    end

    test "a reservation smaller than parts.size is one part", ctx do
      attrs = parts_body(1_000, @mib16, 1)

      assert {:ok, %{upload_parts: [%{number: 1, headers: headers}]}} =
               reserve(ctx, hex(:k), attrs)

      assert headers["content-length"] == "1000"
    end

    test "\"parts\": null is a single-PUT reservation", ctx do
      attrs = Map.put(reservation_body("x"), "parts", nil)
      assert {:ok, r} = reserve(ctx, hex(:k), attrs)

      assert Map.keys(r) |> Enum.sort() ==
               [:entry, :upload_headers, :upload_url, :upload_url_expires_at]

      refute Entry.multipart?(r.entry)
      assert Fake.uploads(prefix(ctx)) == []
    end

    test "a reservation without parts is unchanged", ctx do
      assert {:ok, r} = reserve(ctx, hex(:k), "x")

      assert Map.keys(r) |> Enum.sort() ==
               [:entry, :upload_headers, :upload_url, :upload_url_expires_at]

      assert %{multipart_upload_id: nil, part_size: nil, part_md5s: nil} = r.entry
      assert DateTime.diff(r.upload_url_expires_at, DateTime.utc_now()) in 890..900
    end

    test "invalid parts are 422 on parts and reserve nothing", ctx do
      good = parts_body(52_428_800, @mib16, 4)
      md5s = good["parts"]["md5"]
      put = fn parts -> Map.put(good, "parts", parts) end

      for attrs <- [
            parts_body(52_428_800, @mib16, 3),
            parts_body(52_428_800, @mib16, 5),
            parts_body(52_428_800, 5_242_879, 11),
            parts_body(10_000_000, 5_368_709_121, 1),
            put.(%{"size" => @mib16, "md5" => [Base.encode64(:binary.copy("a", 20)) | tl(md5s)]}),
            put.(%{"size" => @mib16, "md5" => ["not base64 at all!!!!!!!" | tl(md5s)]}),
            put.(%{"size" => @mib16, "md5" => [String.trim_trailing(hd(md5s), "=") | tl(md5s)]}),
            put.(%{"size" => @mib16, "md5" => [1 | tl(md5s)]}),
            put.(%{"size" => @mib16, "md5" => md5s, "etags" => md5s}),
            put.(%{"size" => @mib16}),
            put.(%{"size" => "16777216", "md5" => md5s}),
            put.(%{"size" => 16_777_216.0, "md5" => md5s}),
            put.(%{"size" => @mib16, "md5" => "x"}),
            put.([1, 2]),
            put.("parts"),
            parts_body(60_000_000_000, 5_242_880, 1)
          ] do
        assert_parts_error(ctx, attrs)
      end
    end

    test "the part limit and the count rule name themselves", ctx do
      assert {:error, cs} = reserve(ctx, hex(:k), parts_body(60_000_000_000, 5_242_880, 1))
      assert {"must have at most 10000 parts", _} = cs.errors[:parts]

      assert {:error, cs} = reserve(ctx, hex(:k), parts_body(52_428_800, @mib16, 3))
      assert {"md5 must have 4 entries", _} = cs.errors[:parts]

      assert {:error, cs} = reserve(ctx, hex(:k), parts_body(52_428_800, 5_242_879, 11))
      assert {"part size must be from 5242880 through 5368709120", _} = cs.errors[:parts]
    end

    test "parts without sha256 is 422 on sha256", ctx do
      attrs = 52_428_800 |> parts_body(@mib16, 4) |> Map.delete("sha256")
      assert {:error, cs} = reserve(ctx, hex(:k), attrs)
      assert List.keymember?(cs.errors, :sha256, 0)
      assert Fake.uploads(prefix(ctx)) == []
    end

    test "a store that cannot create the upload is unavailable and reserves nothing", ctx do
      Fake.fail(:create_multipart, prefix(ctx))

      assert {:error, :object_store_unavailable} =
               reserve(ctx, hex(:k), parts_body(52_428_800, @mib16, 4))

      refute Repo.exists?(from e in Entry, where: e.project_id == ^ctx.project.id)

      refute Repo.exists?(
               from d in "cache_object_deletions", where: like(d.object_key, ^"#{prefix(ctx)}%")
             )

      Fake.heal(:create_multipart, prefix(ctx))
      assert {:ok, _} = reserve(ctx, hex(:k), parts_body(52_428_800, @mib16, 4))
    end

    test "409 aborts the upload it started and queues it", ctx do
      key = hex(:k)
      entry_fixture(ctx.project, key: key, scope: "main")
      before = DateTime.utc_now()

      assert {:error, :cache_conflict} = reserve(ctx, key, parts_body(52_428_800, @mib16, 4))
      assert [{upload_id, object_key, :aborted}] = Fake.uploads(prefix(ctx))
      assert {^upload_id, delete_after} = deletion_row(object_key)
      assert NaiveDateTime.diff(delete_after, DateTime.to_naive(before)) in 0..2
    end

    test "507 aborts the upload it started and queues it, evicting nothing", ctx do
      committed = entry_fixture(ctx.project, size: 2 * @gib, last_accessed_at: ago(86_400))
      reservation_fixture(ctx.project, size: 48 * @gib)

      assert {:error, :quota_exceeded} =
               reserve(ctx, hex(:new), parts_body(4_000_000_000, 64 * @mib16, 4))

      assert Repo.get(Entry, committed.id)
      assert [{upload_id, object_key, :aborted}] = Fake.uploads(prefix(ctx))
      assert {^upload_id, _delete_after} = deletion_row(object_key)
    end

    test "a failed immediate abort stays queued for the sweep", ctx do
      key = hex(:k)
      entry_fixture(ctx.project, key: key, scope: "main")
      Fake.fail(:abort_multipart, prefix(ctx))

      assert {:error, :cache_conflict} = reserve(ctx, key, parts_body(52_428_800, @mib16, 4))
      assert [{upload_id, object_key, :open}] = Fake.uploads(prefix(ctx))
      assert {^upload_id, _delete_after} = deletion_row(object_key)
    end

    test "quota eviction counts the declared size, as without parts", ctx do
      a = entry_fixture(ctx.project, size: 25 * @gib, last_accessed_at: ago(86_400))
      b = entry_fixture(ctx.project, size: 25 * @gib, last_accessed_at: ago(60))

      assert {:ok, r} = reserve(ctx, hex(:new), parts_body(4_000_000_000, 64 * @mib16, 4))
      assert r.entry.size == 4_000_000_000
      refute Repo.get(Entry, a.id)
      assert Repo.get(Entry, b.id)
      assert Caches.usage(ctx.project).bytes == 25 * @gib + 4_000_000_000
    end
  end

  describe "commit (4.4)" do
    setup ctx do
      body = :crypto.strong_rand_bytes(256)
      {:ok, r} = reserve(ctx, hex(:k), body)
      Map.merge(ctx, %{body: body, reservation: r})
    end

    test "commits after a valid upload; a retry returns the same entry", ctx do
      r = ctx.reservation
      assert :ok = Fake.put(r.upload_url, r.upload_headers, ctx.body)

      assert {:ok, entry} = Caches.commit(ctx.project, ctx.sk_key, r.entry.id)
      assert entry.state == :committed
      assert entry.expires_at == nil
      assert entry.committed_at && entry.last_accessed_at

      assert {:ok, again} = Caches.commit(ctx.project, ctx.sk_key, r.entry.id)
      assert again.id == entry.id
      assert {:ok, %{id: id}} = Caches.lookup_key(ctx.account, ctx.project, hex(:k), "main")
      assert id == entry.id
    end

    test "the fake store rejects a wrong body or missing headers", ctx do
      r = ctx.reservation
      other = :crypto.strong_rand_bytes(256)

      assert {:error, :bad_digest} = Fake.put(r.upload_url, r.upload_headers, other)

      assert {:error, :length_mismatch} =
               Fake.put(r.upload_url, r.upload_headers, ctx.body <> "x")

      assert {:error, :signature_mismatch} = Fake.put(r.upload_url, %{}, ctx.body)
    end

    test "a missing object is 422 on upload and frees the slot", ctx do
      r = ctx.reservation

      assert {:error, %Ecto.Changeset{errors: [upload: {"is missing", _}]}} =
               Caches.commit(ctx.project, ctx.sk_key, r.entry.id)

      refute Repo.get(Entry, r.entry.id)
      assert queued?(r.entry.object_key)
      assert {:ok, _} = reserve(ctx, hex(:k), ctx.body)
    end

    test "a wrong length, wrong checksum, or no checksum is 422 and deletes the reservation",
         ctx do
      r = ctx.reservation
      checksum = :sha256 |> :crypto.hash(ctx.body) |> Base.encode64()

      for {size, sum, message} <- [
            {255, checksum, "has the wrong size"},
            {256, Base.encode64(:crypto.hash(:sha256, "other")), "has the wrong checksum"},
            {256, nil, "has the wrong checksum"}
          ] do
        {:ok, r} =
          if Repo.get(Entry, r.entry.id), do: {:ok, r}, else: reserve(ctx, hex(:k), ctx.body)

        Fake.put_object(r.entry.object_key, size, sum)

        assert {:error, %Ecto.Changeset{errors: [upload: {^message, _}]}} =
                 Caches.commit(ctx.project, ctx.sk_key, r.entry.id)

        refute Repo.get(Entry, r.entry.id)
        assert {:error, :not_found} = Caches.lookup_key(ctx.account, ctx.project, hex(:k), "main")
      end
    end

    test "a store that cannot answer HEAD keeps the reservation", ctx do
      r = ctx.reservation
      :ok = Fake.put(r.upload_url, r.upload_headers, ctx.body)
      Fake.fail_deletes(r.entry.object_key)
      on_exit(fn -> Fake.heal(r.entry.object_key) end)

      assert {:error, :object_store_unavailable} =
               Caches.commit(ctx.project, ctx.sk_key, r.entry.id)

      assert Repo.get!(Entry, r.entry.id).state == :reserved
      refute queued?(r.entry.object_key)
    end

    test "a rejected upload's object is deleted only after its upload URL expires", ctx do
      r = ctx.reservation
      Fake.put_object(r.entry.object_key, 255, nil)

      assert {:error, %Ecto.Changeset{}} = Caches.commit(ctx.project, ctx.sk_key, r.entry.id)
      assert_deleted_after_upload_url(r)
    end

    test "a purged reservation's object is deleted only after its upload URL expires", ctx do
      r = ctx.reservation
      :ok = Fake.put(r.upload_url, r.upload_headers, ctx.body)

      assert {:ok, 1} = Caches.delete(ctx.project, hex(:k), %{"scope" => "main"})
      assert_deleted_after_upload_url(r)
    end

    test "another key, an expired reservation, another project, or a bad id is 404", ctx do
      r = ctx.reservation
      Fake.put(r.upload_url, r.upload_headers, ctx.body)
      {other_key, _} = api_key_fixture(ctx.account_user, %{type: :private})

      assert {:error, :not_found} = Caches.commit(ctx.project, other_key, r.entry.id)
      assert Repo.get!(Entry, r.entry.id).state == :reserved

      other_project = project_fixture(ctx.account)
      assert {:error, :not_found} = Caches.commit(other_project, ctx.sk_key, r.entry.id)
      assert {:error, :not_found} = Caches.commit(ctx.project, ctx.sk_key, "not-a-uuid")

      assert {:error, :not_found} =
               Caches.commit(ctx.project, ctx.sk_key, String.upcase(r.entry.id))

      Repo.update_all(from(e in Entry, where: e.id == ^r.entry.id), set: [expires_at: ago(1)])
      assert {:error, :not_found} = Caches.commit(ctx.project, ctx.sk_key, r.entry.id)
    end

    test "a late upload after a new reservation does not change the committed bytes", ctx do
      r1 = ctx.reservation
      Repo.update_all(from(e in Entry, where: e.id == ^r1.entry.id), set: [expires_at: ago(1)])

      body2 = :crypto.strong_rand_bytes(256)
      {:ok, r2} = reserve(ctx, hex(:k), body2)
      :ok = Fake.put(r2.upload_url, r2.upload_headers, body2)
      {:ok, committed} = Caches.commit(ctx.project, ctx.sk_key, r2.entry.id)

      # The old URL names the old, now-deleted reservation's object.
      _ = Fake.put(r1.upload_url, r1.upload_headers, ctx.body)
      refute r1.entry.object_key == committed.object_key

      assert {:ok, %{size: 256, checksum_sha256: sum}} =
               ObjectStore.head(committed.object_key)

      assert sum == :sha256 |> :crypto.hash(body2) |> Base.encode64()
    end
  end

  describe "multipart commit (4.1)" do
    @part 5_242_880

    setup ctx do
      body = :crypto.strong_rand_bytes(2 * @part + 1_000)

      chunks = [
        binary_part(body, 0, @part),
        binary_part(body, @part, @part),
        binary_part(body, 2 * @part, 1_000)
      ]

      md5s = Enum.map(chunks, &Base.encode64(:crypto.hash(:md5, &1)))

      attrs =
        body
        |> reservation_body()
        |> Map.put("parts", %{"size" => @part, "md5" => md5s})

      {:ok, r} = reserve(ctx, hex(:k), attrs)

      Map.merge(ctx, %{
        body: body,
        chunks: chunks,
        attrs: attrs,
        reservation: r,
        prefix: "caches/#{ctx.project.id}/"
      })
    end

    defp upload(r, chunks, numbers \\ [1, 2, 3]) do
      for n <- numbers do
        part = Enum.at(r.upload_parts, n - 1)
        assert :ok = Fake.put_part(part.url, part.headers, Enum.at(chunks, n - 1))
      end
    end

    defp commit(ctx), do: Caches.commit(ctx.project, ctx.sk_key, ctx.reservation.entry.id)

    defp assert_rejected(ctx, message) do
      r = ctx.reservation
      assert {:error, %Ecto.Changeset{errors: [upload: {^message, _}]}} = commit(ctx)
      refute Repo.get(Entry, r.entry.id)
      assert Fake.upload_state(r.entry.multipart_upload_id) in [:aborted, :completed]
      assert queued?(r.entry.object_key)
      assert {:error, :not_found} = Caches.lookup_key(ctx.account, ctx.project, hex(:k), "main")
    end

    defp assert_kept(ctx) do
      assert {:error, :object_store_unavailable} = commit(ctx)
      assert Repo.get!(Entry, ctx.reservation.entry.id).state == :reserved
      refute queued?(ctx.reservation.entry.object_key)
    end

    test "commits after every part; the download is the concatenated parts", ctx do
      r = ctx.reservation
      upload(r, ctx.chunks)
      refute Fake.exists?(r.entry.object_key)

      assert {:ok, entry} = commit(ctx)
      assert entry.state == :committed
      assert entry.sha256 == ctx.attrs["sha256"]
      assert Fake.body(r.entry.object_key) == ctx.body
      assert Fake.upload_state(r.entry.multipart_upload_id) == :completed

      assert {:ok, %{sha256: sha}} = Caches.lookup_key(ctx.account, ctx.project, hex(:k), "main")
      assert sha == ctx.attrs["sha256"]
      assert {:ok, again} = commit(ctx)
      assert again.id == entry.id
    end

    test "parts uploaded but not committed leave no object and no hit", ctx do
      upload(ctx.reservation, ctx.chunks)
      refute Fake.exists?(ctx.reservation.entry.object_key)
      assert {:error, :not_found} = Caches.lookup_key(ctx.account, ctx.project, hex(:k), "main")
    end

    test "a missing part is 422, frees the slot and aborts the upload", ctx do
      r = ctx.reservation
      upload(r, ctx.chunks, [1, 3])
      assert_rejected(ctx, "has missing or wrong parts")
      assert Fake.upload_state(r.entry.multipart_upload_id) == :aborted

      part = Enum.at(r.upload_parts, 1)

      assert {:error, :no_such_upload} =
               Fake.put_part(part.url, part.headers, Enum.at(ctx.chunks, 1))

      assert {:ok, _} = reserve(ctx, hex(:k), ctx.attrs)
    end

    test "a part with another ETag or size is 422", ctx do
      r = ctx.reservation
      upload(r, ctx.chunks)
      # Re-presign part 3 for other bytes of the same length, as a client
      # holding the bucket's keys could.
      other = :crypto.strong_rand_bytes(1_000)

      {url, headers} =
        ObjectStore.presign_part(
          r.entry.object_key,
          r.entry.multipart_upload_id,
          3,
          %{
            size: 1_000,
            md5: Base.encode64(:crypto.hash(:md5, other)),
            expires_in: 60
          }
        )

      assert :ok = Fake.put_part(url, headers, other)
      assert_rejected(ctx, "has missing or wrong parts")
    end

    test "a completed object with another ETag or size is 422", ctx do
      r = ctx.reservation
      upload(r, ctx.chunks)
      Fake.complete_upload(r.entry.multipart_upload_id)
      Fake.put_object(r.entry.object_key, byte_size(ctx.body), nil, "0123-3")
      assert_rejected(ctx, "has the wrong checksum")

      {:ok, r} = reserve(ctx, hex(:k), ctx.attrs)
      ctx = %{ctx | reservation: r}
      upload(r, ctx.chunks)
      Fake.complete_upload(r.entry.multipart_upload_id)
      etag = ObjectStore.multipart_etag(ctx.attrs["parts"]["md5"])
      Fake.put_object(r.entry.object_key, byte_size(ctx.body) - 1, nil, etag)
      assert_rejected(ctx, "has the wrong size")
    end

    test "a completion the store refuses is 422", ctx do
      upload(ctx.reservation, ctx.chunks)
      Fake.fail(:complete_multipart, ctx.prefix, {:error, {:rejected, "InvalidPart"}})
      on_exit(fn -> Fake.heal(:complete_multipart, ctx.prefix) end)
      assert_rejected(ctx, "has missing or wrong parts")
    end

    test "list, complete or HEAD failures are 503 and keep the reservation", ctx do
      r = ctx.reservation
      upload(r, ctx.chunks)

      for call <- [:list_parts, :complete_multipart, :head] do
        Fake.fail(call, ctx.prefix)
        assert_kept(ctx)
        Fake.heal(call, ctx.prefix)
      end

      assert {:ok, %{state: :committed}} = commit(ctx)
    end

    test "a retry after the upload was completed behind the server's back is 200", ctx do
      r = ctx.reservation
      upload(r, ctx.chunks)
      Fake.complete_upload(r.entry.multipart_upload_id)

      assert {:ok, entry} = commit(ctx)
      assert entry.state == :committed
      assert Fake.body(r.entry.object_key) == ctx.body
    end

    test "the upload gone and no object yet is 503 and keeps the reservation", ctx do
      # Another commit's CompleteMultipartUpload may still be running.
      ObjectStore.abort_multipart(
        ctx.reservation.entry.object_key,
        ctx.reservation.entry.multipart_upload_id
      )

      assert_kept(ctx)
    end

    test "a complete that reports the upload gone and no object yet is 503", ctx do
      upload(ctx.reservation, ctx.chunks)
      Fake.fail(:complete_multipart, ctx.prefix, {:error, :not_found})
      on_exit(fn -> Fake.heal(:complete_multipart, ctx.prefix) end)
      assert_kept(ctx)
    end

    test "a completed upload whose object then vanished is 422 is missing", ctx do
      r = ctx.reservation
      upload(r, ctx.chunks)
      # The store completes the upload but the object is not there for HEAD.
      Fake.fail(:head, ctx.prefix, {:error, :not_found})
      on_exit(fn -> Fake.heal(:head, ctx.prefix) end)
      assert_rejected(ctx, "is missing")
    end

    test "a transaction that raises aborts the started upload and queues it", ctx do
      # The project is deleted between the access checks and the insert,
      # so locking its row raises.
      :ok = GoodFlows.Projects.delete_project(ctx.account, ctx.project)
      prefix = "caches/#{ctx.project.id}/"

      assert_raise Ecto.NoResultsError, fn -> reserve(ctx, hex(:other), ctx.attrs) end

      assert [{upload_id, object_key, :aborted}] =
               prefix
               |> Fake.uploads()
               |> Enum.reject(&(elem(&1, 0) == ctx.reservation.entry.multipart_upload_id))

      assert Repo.exists?(
               from d in "cache_object_deletions",
                 where: d.object_key == ^object_key and d.multipart_upload_id == ^upload_id
             )
    end
  end

  describe "list and purge (4.5)" do
    test "lists newest first with filters, paging and usage", ctx do
      e1 = entry_fixture(ctx.project, name: "deps", committed_at: ago(300), size: 10)

      e2 =
        entry_fixture(ctx.project,
          name: "deps",
          scope: "feature/x",
          committed_at: ago(200),
          size: 20
        )

      e3 = entry_fixture(ctx.project, name: "build", committed_at: ago(100), size: 30)
      reservation_fixture(ctx.project, size: 40)
      reservation_fixture(ctx.project, size: 1_000, expires_at: ago(1))

      {:ok, page} = Caches.list(ctx.account, ctx.project, %{})
      assert Enum.map(page.entries, & &1.id) == [e3.id, e2.id, e1.id]
      assert page.usage.bytes == 100
      assert page.usage.entries == 4
      assert page.usage.quota_bytes == 53_687_091_200
      assert page.usage.max_entries == 10_000

      {:ok, page} = Caches.list(ctx.account, ctx.project, %{"name" => "deps"})
      assert Enum.map(page.entries, & &1.id) == [e2.id, e1.id]

      {:ok, page} = Caches.list(ctx.account, ctx.project, %{"name" => "deps", "scope" => "main"})
      assert Enum.map(page.entries, & &1.id) == [e1.id]

      {:ok, first} = Caches.list(ctx.account, ctx.project, %{"limit" => "2"})
      assert length(first.entries) == 2

      {:ok, second} =
        Caches.list(ctx.account, ctx.project, %{"limit" => "2", "cursor" => first.next_cursor})

      assert Enum.map(second.entries, & &1.id) == [e1.id]
      assert second.next_cursor == nil

      for bad <- [%{"limit" => "201"}, %{"cursor" => "x"}, %{"name" => ""}, %{"scope" => "a\nb"}] do
        assert {:error, %Ecto.Changeset{}} = Caches.list(ctx.account, ctx.project, bad)
      end
    end

    test "delete removes one key in one scope and returns counts", ctx do
      key = hex(:k)
      main = entry_fixture(ctx.project, key: key, scope: "main")
      feature = entry_fixture(ctx.project, key: key, scope: "feature/x")

      assert {:ok, 1} = Caches.delete(ctx.project, key, %{"scope" => "main"})
      refute Repo.get(Entry, main.id)
      assert Repo.get(Entry, feature.id)
      assert {:ok, 0} = Caches.delete(ctx.project, key, %{"scope" => "main"})
      assert {:error, %Ecto.Changeset{}} = Caches.delete(ctx.project, key, %{})
      assert {:error, :not_found} = Caches.delete(ctx.project, "ABC", %{"scope" => "main"})

      assert {:error, :not_found} = Caches.lookup_key(ctx.account, ctx.project, key, "main")

      assert {:ok, %{scope: "feature/x"}} =
               Caches.lookup_key(ctx.account, ctx.project, key, "feature/x")
    end

    test "delete_matching needs a filter and matches all of them", ctx do
      p = hex(:p)
      entry_fixture(ctx.project, name: "deps", scope: "main", partial: p)
      entry_fixture(ctx.project, name: "deps", scope: "main", partial: p)
      reservation_fixture(ctx.project, name: "deps", scope: "main")
      keep = entry_fixture(ctx.project, name: "deps", scope: "feature/x", partial: p)

      assert {:error, {:unprocessable, _}} = Caches.delete_matching(ctx.project, %{})

      assert {:ok, 3} =
               Caches.delete_matching(ctx.project, %{"name" => "deps", "scope" => "main"})

      assert {:error, :not_found} = Caches.lookup_partial(ctx.account, ctx.project, p, "main")
      assert Repo.get(Entry, keep.id)
      assert {:ok, 0} = Caches.delete_matching(ctx.project, %{"partial" => hex(:none)})
    end

    test "a purged key can be reserved and committed again with a new archive", ctx do
      key = hex(:k)
      entry_fixture(ctx.project, key: key)
      {:ok, 1} = Caches.delete(ctx.project, key, %{"scope" => "main"})

      body = :crypto.strong_rand_bytes(32)
      {:ok, r} = reserve(ctx, key, body)
      :ok = Fake.put(r.upload_url, r.upload_headers, body)
      {:ok, _} = Caches.commit(ctx.project, ctx.sk_key, r.entry.id)

      assert {:ok, %{sha256: sha}} = Caches.lookup_key(ctx.account, ctx.project, key, "main")
      assert sha == :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)
    end
  end
end
