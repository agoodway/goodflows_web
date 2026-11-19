defmodule GoodFlowsWeb.Api.V1.CacheEntryControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import Ecto.Query
  import GoodFlows.CacheFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Entry
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  @gib 1_073_741_824

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account, %{"slug" => "alpha"})}
  end

  defp base(project), do: "/api/v1/projects/#{project.slug}/caches"

  defp show(conn, project, key, query \\ %{}),
    do: get(conn, "#{base(project)}/entries/#{key}", query)

  defp lookup(conn, project, query), do: get(conn, "#{base(project)}/entries", query)

  defp reserve(conn, project, key, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("#{base(project)}/entries/#{key}", Jason.encode!(body))
  end

  defp commit(conn, project, upload_id),
    do: post(conn, "#{base(project)}/uploads/#{upload_id}/commit")

  defp ck(ctx, attrs \\ %{}) do
    {key, token} = cache_key_fixture(ctx.account, ctx.project, attrs)
    {key, api_conn(token)}
  end

  defp entries_count(project),
    do: Repo.aggregate(from(e in Entry, where: e.project_id == ^project.id), :count)

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  # Reserves, uploads `body` through the fake store, and commits.
  defp save(conn, project, key, body, overrides \\ %{}) do
    r = conn |> reserve(project, key, reservation_body(body, overrides)) |> json_response(201)
    :ok = Fake.put(r["data"]["upload_url"], r["data"]["upload_headers"], body)
    conn |> commit(project, r["data"]["upload_id"]) |> json_response(200)
  end

  describe "authentication and key types" do
    test "a public key gets 403 on every cache route and no download URL", ctx do
      entry = entry_fixture(ctx.project)
      conn = ctx.pk_conn

      body = conn |> show(ctx.project, entry.key, %{"scope" => "main"}) |> json_response(403)
      refute inspect(body) =~ "download_url"
      assert conn |> lookup(ctx.project, %{"partial" => entry.partial}) |> json_response(403)
      assert conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(403)
      assert conn |> commit(ctx.project, Ecto.UUID.generate()) |> json_response(403)
      assert conn |> get(base(ctx.project)) |> json_response(403)

      assert conn
             |> delete("#{base(ctx.project)}/entries", %{"name" => "deps"})
             |> json_response(403)

      assert entries_count(ctx.project) == 1
    end

    test "a cache key on another project of the account is 403", ctx do
      beta = project_fixture(ctx.account, %{"slug" => "beta"})
      entry = entry_fixture(beta)
      {_key, conn} = ck(ctx)

      assert conn |> show(beta, entry.key, %{"scope" => "main"}) |> json_response(403)
      assert conn |> reserve(beta, hex(:k), reservation_body("x")) |> json_response(403)
    end

    test "a cache key cannot list or purge", ctx do
      entry_fixture(ctx.project)
      {_key, conn} = ck(ctx)

      assert conn |> get(base(ctx.project)) |> json_response(403)

      assert conn
             |> delete("#{base(ctx.project)}/entries", %{"name" => "deps"})
             |> json_response(403)

      assert conn
             |> delete("#{base(ctx.project)}/entries/#{hex(:x)}", %{"scope" => "main"})
             |> json_response(403)

      assert entries_count(ctx.project) == 1
    end

    test "missing, expired and revoked keys are 401", ctx do
      assert build_conn()
             |> put_req_header("accept", "application/json")
             |> reserve(ctx.project, hex(:k), reservation_body("x"))
             |> json_response(401)

      {expired, expired_conn} = ck(ctx)
      past = DateTime.utc_now(:second) |> DateTime.add(-1, :second)
      expired |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()
      assert expired_conn |> show(ctx.project, hex(:k)) |> json_response(401)

      {revoked, revoked_conn} = ck(ctx)
      revoked |> Ecto.Changeset.change(status: :revoked) |> Repo.update!()
      assert revoked_conn |> show(ctx.project, hex(:k)) |> json_response(401)

      assert entries_count(ctx.project) == 0
    end

    test "an invalid slug is 422 on project; an unknown slug is 404", ctx do
      assert ctx.sk_conn |> show(%{slug: "GoodCases"}, hex(:k)) |> json_response(422)
      assert ctx.sk_conn |> show(%{slug: "missing"}, hex(:k)) |> json_response(404)
    end
  end

  describe "scope access" do
    test "a bound read-write key writes only its own scope", ctx do
      {_key, conn} = ck(ctx, %{"scope" => "feature/login"})

      assert conn
             |> reserve(
               ctx.project,
               hex(:a),
               reservation_body("x", %{"scope" => "feature/login"})
             )
             |> json_response(201)

      assert conn
             |> reserve(ctx.project, hex(:b), reservation_body("x", %{"scope" => "main"}))
             |> json_response(403)

      {_key, pr42} = ck(ctx, %{"scope" => "pr-42"})

      assert pr42
             |> reserve(ctx.project, hex(:c), reservation_body("x", %{"scope" => "pr-43"}))
             |> json_response(403)

      assert entries_count(ctx.project) == 1
    end

    test "a bound key reads its scope, the default branch and no scope, nothing else", ctx do
      entry = entry_fixture(ctx.project, scope: "main")
      {_key, conn} = ck(ctx, %{"access" => "read", "scope" => "feature/login"})

      for query <- [%{}, %{"scope" => "main"}, %{"scope" => "feature/login"}] do
        assert conn |> show(ctx.project, entry.key, query) |> json_response(200)
      end

      assert conn
             |> lookup(ctx.project, %{"partial" => entry.partial, "scope" => "feature/other"})
             |> json_response(403)
    end

    test "a read key cannot reserve", ctx do
      {_key, conn} = ck(ctx, %{"access" => "read"})
      assert conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(403)
      assert entries_count(ctx.project) == 0
    end

    test "a key that cannot satisfy the request gets 403 before validation", ctx do
      {_key, read} = ck(ctx, %{"access" => "read"})

      # A read key reserving: malformed body, unknown key, bad path key,
      # wrong content type, all 403.
      assert read
             |> reserve(ctx.project, hex(:k), %{"scope" => "main\n", "bogus" => 1})
             |> json_response(403)

      assert read |> reserve(ctx.project, "NOT-HEX", %{}) |> json_response(403)

      assert read
             |> put_req_header("content-type", "text/plain")
             |> post("#{base(ctx.project)}/entries/#{hex(:k)}", "x")
             |> json_response(403)

      assert read |> commit(ctx.project, "not-a-uuid") |> json_response(403)

      # A bound key with another scope: 403 even when the rest is malformed.
      {_key, bound} = ck(ctx, %{"scope" => "feature/login"})

      assert bound
             |> reserve(ctx.project, hex(:k), %{"scope" => "main", "size" => "big"})
             |> json_response(403)

      assert bound
             |> reserve(ctx.project, hex(:k), Map.delete(reservation_body("x"), "scope"))
             |> json_response(403)

      assert bound
             |> lookup(ctx.project, %{"scope" => "feature/other", "partial" => "NOT-HEX"})
             |> json_response(403)

      assert bound
             |> show(ctx.project, "NOT-HEX", %{"scope" => "feature/other"})
             |> json_response(403)

      # Keys that may write some scope still get field errors: the scope must
      # be validated before it can be checked.
      {_key, unbound} = ck(ctx)

      assert unbound
             |> reserve(ctx.project, hex(:k), reservation_body("x", %{"scope" => "main\n"}))
             |> json_response(422)
             |> get_in(["errors", "scope"])

      assert bound
             |> reserve(
               ctx.project,
               hex(:k),
               reservation_body("x", %{"scope" => "feature/login", "size" => "1"})
             )
             |> json_response(422)
             |> get_in(["errors", "size"])

      assert bound
             |> lookup(ctx.project, %{"scope" => "feature/login", "partial" => "NOT-HEX"})
             |> json_response(422)
             |> get_in(["errors", "partial"])

      assert entries_count(ctx.project) == 0
    end

    test "an unbound long-lived read key restores a feature branch, then main", ctx do
      p = hex(:p)
      main = entry_fixture(ctx.project, partial: p, scope: "main")

      {_key, conn} =
        ck(ctx, %{"access" => "read", "ttl_seconds" => nil, "name" => "orbs"})

      query = %{"partial" => p, "scope" => "feature/login"}
      body = conn |> lookup(ctx.project, query) |> json_response(200)
      assert body["data"]["key"] == main.key

      feature =
        entry_fixture(ctx.project, partial: p, scope: "feature/login", committed_at: ago(3600))

      body = conn |> lookup(ctx.project, query) |> json_response(200)
      assert body["data"]["key"] == feature.key

      assert conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(403)
    end

    test "an orb key bound to the default branch reads only main", ctx do
      p = hex(:p)
      main = entry_fixture(ctx.project, partial: p, scope: "main")
      entry_fixture(ctx.project, partial: p, scope: "feature/login")

      body =
        ctx.sk_conn
        |> post("/api/v1/projects/alpha/cache-keys", %{
          "access" => "read",
          "ttl_seconds" => nil,
          "scope" => "main",
          "name" => "orbs"
        })
        |> json_response(201)

      conn = api_conn(body["data"]["token"])

      for query <- [%{"partial" => p}, %{"partial" => p, "scope" => "main"}] do
        assert conn |> lookup(ctx.project, query) |> json_response(200) |> get_in(["data", "key"]) ==
                 main.key
      end

      assert conn
             |> lookup(ctx.project, %{"partial" => p, "scope" => "feature/login"})
             |> json_response(403)
    end
  end

  describe "identifier formats" do
    test "a malformed path key or upload_id is 404", ctx do
      upper = String.upcase(hex(:k))
      assert ctx.sk_conn |> show(ctx.project, upper) |> json_response(404)

      assert ctx.sk_conn
             |> reserve(ctx.project, upper, reservation_body("x"))
             |> json_response(404)

      assert ctx.sk_conn |> commit(ctx.project, "not-a-uuid") |> json_response(404)

      assert ctx.sk_conn
             |> delete("#{base(ctx.project)}/entries/#{upper}", %{"scope" => "main"})
             |> json_response(404)
    end

    test "query values in the wrong format are 422 on that field", ctx do
      body =
        ctx.sk_conn
        |> lookup(ctx.project, %{"partial" => String.duplicate("a", 63)})
        |> json_response(422)

      assert_schema(body, "ValidationErrorResponse", ApiSpec.spec())
      assert body["errors"]["partial"]

      assert ctx.sk_conn
             |> lookup(ctx.project, %{})
             |> json_response(422)
             |> get_in(["errors", "partial"])

      assert ctx.sk_conn
             |> show(ctx.project, hex(:k), %{"scope" => String.duplicate("s", 257)})
             |> json_response(422)
             |> get_in(["errors", "scope"])
    end

    test "reservation scopes: a non-Git label is accepted, oversize and newline are 422", ctx do
      assert ctx.sk_conn
             |> reserve(ctx.project, hex(:a), reservation_body("x", %{"scope" => "pr 42..head"}))
             |> json_response(201)

      for scope <- [String.duplicate("s", 257), "main\n"] do
        body =
          ctx.sk_conn
          |> reserve(ctx.project, hex(:b), reservation_body("x", %{"scope" => scope}))
          |> json_response(422)

        assert body["errors"]["scope"]
      end
    end
  end

  describe "lookups" do
    test "an exact hit returns metadata and a download URL", ctx do
      entry = entry_fixture(ctx.project, scope: "feature/login", size: 52_428_800)
      entry_fixture(ctx.project, key: entry.key, scope: "main")

      body =
        ctx.sk_conn
        |> show(ctx.project, entry.key, %{"scope" => "feature/login"})
        |> json_response(200)

      assert_schema(body, "CacheEntryResponse", ApiSpec.spec())
      data = body["data"]
      assert data["scope"] == "feature/login"
      assert data["size"] == 52_428_800
      assert data["sha256"] == entry.sha256
      assert data["key"] == entry.key
      assert data["partial"] == entry.partial
      assert data["name"] == "deps"
      assert data["created_at"]
      assert data["download_url"] =~ entry.object_key
      assert data["download_url"] =~ "X-Amz-Expires=900"
      {:ok, expires, 0} = DateTime.from_iso8601(data["download_url_expires_at"])
      assert_in_delta DateTime.diff(expires, DateTime.utc_now()), 900, 5
    end

    test "falls back to main; never reads another branch; no scope reads main only", ctx do
      main = entry_fixture(ctx.project, scope: "main")
      other = entry_fixture(ctx.project, scope: "feature/other")

      assert ctx.sk_conn
             |> show(ctx.project, main.key, %{"scope" => "feature/login"})
             |> json_response(200)
             |> get_in(["data", "scope"]) == "main"

      assert ctx.sk_conn
             |> show(ctx.project, other.key, %{"scope" => "feature/login"})
             |> json_response(404)

      assert ctx.sk_conn |> show(ctx.project, other.key) |> json_response(404)
    end

    test "a reservation is not visible", ctx do
      reservation = reservation_fixture(ctx.project)

      assert ctx.sk_conn
             |> show(ctx.project, reservation.key, %{"scope" => "main"})
             |> json_response(404)
    end

    test "partial: newest of a scope, and the requested scope beats a newer default", ctx do
      p = hex(:p)
      entry_fixture(ctx.project, partial: p, committed_at: ago(7200))
      newer = entry_fixture(ctx.project, partial: p, committed_at: ago(3600))

      feature =
        entry_fixture(ctx.project, partial: p, scope: "feature/login", committed_at: ago(9000))

      assert ctx.sk_conn
             |> lookup(ctx.project, %{"partial" => p, "scope" => "main"})
             |> json_response(200)
             |> get_in(["data", "key"]) == newer.key

      assert ctx.sk_conn
             |> lookup(ctx.project, %{"partial" => p, "scope" => "feature/login"})
             |> json_response(200)
             |> get_in(["data", "key"]) == feature.key
    end

    test "changing the default branch changes the fallback", ctx do
      trunk = entry_fixture(ctx.project, scope: "trunk")

      ctx.sk_conn
      |> patch("/api/v1/projects/alpha", %{"default_branch" => "trunk"})
      |> json_response(200)

      assert ctx.sk_conn
             |> show(ctx.project, trunk.key, %{"scope" => "feature/x"})
             |> json_response(200)
    end
  end

  describe "reserve" do
    test "returns an upload URL with signed headers for the size and checksum", ctx do
      digest = hex(:digest)

      body =
        ctx.sk_conn
        |> reserve(
          ctx.project,
          hex(:k),
          reservation_body("x", %{"size" => 52_428_800, "sha256" => digest})
        )
        |> json_response(201)

      assert_schema(body, "CacheReservationResponse", ApiSpec.spec())
      data = body["data"]

      assert data["upload_headers"] == %{
               "content-length" => "52428800",
               "content-type" => "application/gzip",
               "x-amz-checksum-sha256" =>
                 digest |> Base.decode16!(case: :lower) |> Base.encode64()
             }

      signed = data["upload_url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      headers = String.split(signed["X-Amz-SignedHeaders"], ";")
      assert "content-length" in headers
      assert "content-type" in headers
      assert "x-amz-checksum-sha256" in headers
      assert data["upload_id"] =~ ~r/\A[0-9a-f-]{36}\z/
      assert data["expires_at"] && data["upload_url_expires_at"]
    end

    test "409 for a committed key; 201 in another scope", ctx do
      entry = entry_fixture(ctx.project, scope: "main")

      body =
        ctx.sk_conn
        |> reserve(ctx.project, entry.key, reservation_body("x"))
        |> json_response(409)

      assert_schema(body, "ConflictResponse", ApiSpec.spec())
      assert Repo.get!(Entry, entry.id).sha256 == entry.sha256

      assert ctx.sk_conn
             |> reserve(
               ctx.project,
               entry.key,
               reservation_body("x", %{"scope" => "feature/login"})
             )
             |> json_response(201)
    end

    test "an expired reservation is replaced; its old upload_id cannot commit", ctx do
      key = hex(:k)

      old =
        reservation_fixture(ctx.project, key: key, expires_at: ago(1), api_key_id: ctx.sk_key.id)

      body = ctx.sk_conn |> reserve(ctx.project, key, reservation_body("x")) |> json_response(201)
      refute body["data"]["upload_id"] == old.id
      assert ctx.sk_conn |> commit(ctx.project, old.id) |> json_response(404)
    end

    test "the entry cap: at the cap 201, one byte over 413", ctx do
      assert ctx.sk_conn
             |> reserve(ctx.project, hex(:a), reservation_body("x", %{"size" => 5_000_000_000}))
             |> json_response(201)

      assert ctx.sk_conn
             |> reserve(ctx.project, hex(:b), reservation_body("x", %{"size" => 5_000_000_001}))
             |> json_response(413)

      assert entries_count(ctx.project) == 1
    end

    test "a size of 0 or a non-integer is 422", ctx do
      for size <- [0, 1.5, "10"] do
        assert ctx.sk_conn
               |> reserve(ctx.project, hex(:a), reservation_body("x", %{"size" => size}))
               |> json_response(422)
               |> get_in(["errors", "size"])
      end
    end

    test "an unknown body key or a missing field is 422 and reserves nothing", ctx do
      body =
        ctx.sk_conn
        |> reserve(ctx.project, hex(:a), reservation_body("x", %{"project" => "alpha"}))
        |> json_response(422)

      assert body["errors"]["project"]

      assert ctx.sk_conn
             |> reserve(ctx.project, hex(:a), Map.delete(reservation_body("x"), "sha256"))
             |> json_response(422)
             |> get_in(["errors", "sha256"])

      assert entries_count(ctx.project) == 0
    end

    test "a form-encoded body is 415 and reserves nothing", ctx do
      assert ctx.sk_conn
             |> put_req_header("content-type", "application/x-www-form-urlencoded")
             |> post(
               "#{base(ctx.project)}/entries/#{hex(:a)}",
               URI.encode_query(reservation_body("x"))
             )
             |> json_response(415)

      assert entries_count(ctx.project) == 0
    end

    test "a JSON content type with parameters or another case is accepted", ctx do
      for {content_type, key} <- [
            {"application/json; charset=utf-8", hex(:charset)},
            {"Application/JSON", hex(:case)}
          ] do
        assert ctx.sk_conn
               |> put_req_header("content-type", content_type)
               |> post(
                 "#{base(ctx.project)}/entries/#{key}",
                 Jason.encode!(reservation_body("x"))
               )
               |> json_response(201)
      end
    end

    test "507 when reservations fill the quota; committed entries untouched", ctx do
      committed = entry_fixture(ctx.project, size: 2 * @gib)
      reservation_fixture(ctx.project, size: 48 * @gib)

      assert ctx.sk_conn
             |> reserve(ctx.project, hex(:a), reservation_body("x", %{"size" => 4_000_000_000}))
             |> json_response(507)

      assert Repo.get(Entry, committed.id)
    end

    test "a full project evicts the least recently used entry", ctx do
      a = entry_fixture(ctx.project, size: 25 * @gib, last_accessed_at: ago(86_400))
      b = entry_fixture(ctx.project, size: 25 * @gib, last_accessed_at: ago(60))

      assert ctx.sk_conn
             |> reserve(ctx.project, hex(:new), reservation_body("x", %{"size" => 4_000_000_000}))
             |> json_response(201)

      refute Repo.get(Entry, a.id)
      assert Repo.get(Entry, b.id)
    end
  end

  describe "commit" do
    test "reserve, upload, commit, then lookup; a retry returns the same entry", ctx do
      body = :crypto.strong_rand_bytes(300)
      {_key, conn} = ck(ctx, %{"scope" => "feature/login"})

      r =
        conn
        |> reserve(ctx.project, hex(:k), reservation_body(body, %{"scope" => "feature/login"}))
        |> json_response(201)

      :ok = Fake.put(r["data"]["upload_url"], r["data"]["upload_headers"], body)

      first = conn |> commit(ctx.project, r["data"]["upload_id"]) |> json_response(200)
      assert_schema(first, "CacheEntryResponse", ApiSpec.spec())
      second = conn |> commit(ctx.project, r["data"]["upload_id"]) |> json_response(200)

      assert Map.drop(first["data"], ~w(download_url download_url_expires_at)) ==
               Map.drop(second["data"], ~w(download_url download_url_expires_at))

      assert conn
             |> show(ctx.project, hex(:k), %{"scope" => "feature/login"})
             |> json_response(200)
    end

    test "commit without an upload is 422 on upload and frees the key", ctx do
      r =
        ctx.sk_conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(201)

      body = ctx.sk_conn |> commit(ctx.project, r["data"]["upload_id"]) |> json_response(422)
      assert body["errors"]["upload"] == ["is missing"]

      assert ctx.sk_conn
             |> reserve(ctx.project, hex(:k), reservation_body("x"))
             |> json_response(201)
    end

    test "a body whose SHA-256 differs is rejected by the store and commit is 422", ctx do
      r =
        ctx.sk_conn
        |> reserve(ctx.project, hex(:k), reservation_body("right"))
        |> json_response(201)

      assert {:error, :bad_digest} =
               Fake.put(r["data"]["upload_url"], r["data"]["upload_headers"], "wrong")

      assert ctx.sk_conn |> commit(ctx.project, r["data"]["upload_id"]) |> json_response(422)
    end

    test "a missing checksum from the store is 422 and nothing is committed", ctx do
      r =
        ctx.sk_conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(201)

      Fake.put_object("caches/#{ctx.project.id}/#{r["data"]["upload_id"]}", 1, nil)

      body = ctx.sk_conn |> commit(ctx.project, r["data"]["upload_id"]) |> json_response(422)
      assert body["errors"]["upload"]
      assert ctx.sk_conn |> show(ctx.project, hex(:k), %{"scope" => "main"}) |> json_response(404)
    end

    test "a store that cannot answer HEAD is 503 with retry-after; the reservation stays",
         ctx do
      r =
        ctx.sk_conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(201)

      :ok = Fake.put(r["data"]["upload_url"], r["data"]["upload_headers"], "x")
      object_key = "caches/#{ctx.project.id}/#{r["data"]["upload_id"]}"
      Fake.fail_deletes(object_key)
      on_exit(fn -> Fake.heal(object_key) end)

      conn = ctx.sk_conn |> commit(ctx.project, r["data"]["upload_id"])
      assert json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert Repo.get!(Entry, r["data"]["upload_id"]).state == :reserved

      Fake.heal(object_key)
      assert ctx.sk_conn |> commit(ctx.project, r["data"]["upload_id"]) |> json_response(200)
    end

    test "commit by another key is 404 and leaves the reservation", ctx do
      r =
        ctx.sk_conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(201)

      :ok = Fake.put(r["data"]["upload_url"], r["data"]["upload_headers"], "x")

      {_key, conn} = ck(ctx)
      assert conn |> commit(ctx.project, r["data"]["upload_id"]) |> json_response(404)
      assert Repo.get!(Entry, r["data"]["upload_id"]).state == :reserved
    end

    test "commit after expiry is 404", ctx do
      r =
        ctx.sk_conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(201)

      :ok = Fake.put(r["data"]["upload_url"], r["data"]["upload_headers"], "x")
      id = r["data"]["upload_id"]
      Repo.update_all(from(e in Entry, where: e.id == ^id), set: [expires_at: ago(1)])

      assert ctx.sk_conn |> commit(ctx.project, id) |> json_response(404)
    end

    test "re-upload after purge returns the new archive", ctx do
      save(ctx.sk_conn, ctx.project, hex(:k), "first")

      assert ctx.sk_conn
             |> delete("#{base(ctx.project)}/entries/#{hex(:k)}", %{"scope" => "main"})
             |> json_response(200) == %{"data" => %{"deleted" => 1}}

      second = save(ctx.sk_conn, ctx.project, hex(:k), "second")
      sha = :sha256 |> :crypto.hash("second") |> Base.encode16(case: :lower)
      assert second["data"]["sha256"] == sha

      assert ctx.sk_conn
             |> show(ctx.project, hex(:k), %{"scope" => "main"})
             |> json_response(200)
             |> get_in(["data", "sha256"]) == sha
    end
  end

  describe "multipart" do
    @part 5_242_880

    setup ctx do
      body = :crypto.strong_rand_bytes(@part + 1_000)
      chunks = [binary_part(body, 0, @part), binary_part(body, @part, 1_000)]
      md5s = Enum.map(chunks, &Base.encode64(:crypto.hash(:md5, &1)))
      attrs = Map.put(reservation_body(body), "parts", %{"size" => @part, "md5" => md5s})
      %{body: body, chunks: chunks, attrs: attrs, prefix: "caches/#{ctx.project.id}/"}
    end

    defp put_parts(data, chunks, numbers) do
      for n <- numbers do
        part = Enum.at(data["upload_parts"], n - 1)
        assert :ok = Fake.put_part(part["url"], part["headers"], Enum.at(chunks, n - 1))
      end
    end

    test "201 has upload_parts in order and no single upload URL", ctx do
      body = ctx.sk_conn |> reserve(ctx.project, hex(:k), ctx.attrs) |> json_response(201)
      assert_schema(body, "CacheReservationResponse", ApiSpec.spec())
      data = body["data"]

      assert Map.keys(data) |> Enum.sort() ==
               ~w(expires_at upload_id upload_parts upload_url_expires_at)

      assert [%{"number" => 1} = p1, %{"number" => 2} = p2] = data["upload_parts"]
      assert Map.keys(p1) |> Enum.sort() == ~w(headers number url)
      [m1, m2] = ctx.attrs["parts"]["md5"]
      assert p1["headers"] == %{"content-length" => "5242880", "content-md5" => m1}
      assert p2["headers"] == %{"content-length" => "1000", "content-md5" => m2}

      signed = p1["url"] |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert signed["X-Amz-SignedHeaders"] == "content-length;content-md5;host"
      assert signed["partNumber"] == "1"

      {:ok, expires, _} = DateTime.from_iso8601(data["upload_url_expires_at"])
      assert DateTime.diff(expires, DateTime.utc_now()) in 7_190..7_200
    end

    test "a single-PUT reservation has no upload_parts", ctx do
      data =
        ctx.sk_conn |> reserve(ctx.project, hex(:k), reservation_body("x")) |> json_response(201)

      refute Map.has_key?(data["data"], "upload_parts")
      assert data["data"]["upload_url"]
    end

    test "invalid parts are 422 on parts and reserve nothing", ctx do
      [m1, _m2] = ctx.attrs["parts"]["md5"]

      for parts <- [
            %{"size" => @part, "md5" => [m1]},
            %{"size" => @part - 1, "md5" => ctx.attrs["parts"]["md5"]},
            %{"size" => @part, "md5" => [m1, "AAAA"]},
            Map.put(ctx.attrs["parts"], "etags", ["x"])
          ] do
        body =
          ctx.sk_conn
          |> reserve(ctx.project, hex(:k), Map.put(ctx.attrs, "parts", parts))
          |> json_response(422)

        assert body["errors"]["parts"]
      end

      body =
        ctx.sk_conn
        |> reserve(ctx.project, hex(:k), Map.delete(ctx.attrs, "sha256"))
        |> json_response(422)

      assert body["errors"]["sha256"]
      assert entries_count(ctx.project) == 0
    end

    test "a store that cannot start the upload is 503 with retry-after", ctx do
      Fake.fail(:create_multipart, ctx.prefix)
      conn = ctx.sk_conn |> reserve(ctx.project, hex(:k), ctx.attrs)
      assert json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert entries_count(ctx.project) == 0

      Fake.heal(:create_multipart, ctx.prefix)
      assert ctx.sk_conn |> reserve(ctx.project, hex(:k), ctx.attrs) |> json_response(201)
    end

    test "409 for a taken key aborts the upload it started", ctx do
      entry_fixture(ctx.project, key: hex(:k), scope: "main")
      assert ctx.sk_conn |> reserve(ctx.project, hex(:k), ctx.attrs) |> json_response(409)
      assert [{_id, _key, :aborted}] = Fake.uploads(ctx.prefix)
    end

    test "commit after all parts is 200; the download is the archive; lookup has sha256", ctx do
      data = ctx.sk_conn |> reserve(ctx.project, hex(:k), ctx.attrs) |> json_response(201)
      data = data["data"]
      put_parts(data, ctx.chunks, [2, 1])

      body = ctx.sk_conn |> commit(ctx.project, data["upload_id"]) |> json_response(200)
      assert_schema(body, "CacheEntryResponse", ApiSpec.spec())
      assert body["data"]["sha256"] == ctx.attrs["sha256"]
      assert body["data"]["download_url"] =~ Fake.signature()
      object_key = "#{ctx.prefix}#{data["upload_id"]}"
      assert Fake.body(object_key) == ctx.body

      assert ctx.sk_conn |> commit(ctx.project, data["upload_id"]) |> json_response(200)

      hit = ctx.sk_conn |> show(ctx.project, hex(:k), %{"scope" => "main"}) |> json_response(200)
      assert hit["data"]["sha256"] == ctx.attrs["sha256"]
    end

    test "commit with a part missing is 422 on upload and the key is free again", ctx do
      data = ctx.sk_conn |> reserve(ctx.project, hex(:k), ctx.attrs) |> json_response(201)
      data = data["data"]
      put_parts(data, ctx.chunks, [1])

      body = ctx.sk_conn |> commit(ctx.project, data["upload_id"]) |> json_response(422)
      assert body["errors"]["upload"] == ["has missing or wrong parts"]

      part = Enum.at(data["upload_parts"], 1)

      assert {:error, :no_such_upload} =
               Fake.put_part(part["url"], part["headers"], Enum.at(ctx.chunks, 1))

      assert ctx.sk_conn |> reserve(ctx.project, hex(:k), ctx.attrs) |> json_response(201)
    end

    test "a store that cannot list parts is 503 with retry-after; a retry commits", ctx do
      data = ctx.sk_conn |> reserve(ctx.project, hex(:k), ctx.attrs) |> json_response(201)
      data = data["data"]
      put_parts(data, ctx.chunks, [1, 2])
      Fake.fail(:list_parts, ctx.prefix)

      conn = ctx.sk_conn |> commit(ctx.project, data["upload_id"])
      assert json_response(conn, 503)
      assert get_resp_header(conn, "retry-after") == ["1"]

      Fake.heal(:list_parts, ctx.prefix)
      assert ctx.sk_conn |> commit(ctx.project, data["upload_id"]) |> json_response(200)
    end
  end

  describe "list and purge" do
    test "lists by name with usage", ctx do
      deps = entry_fixture(ctx.project, name: "deps", size: 10)
      entry_fixture(ctx.project, name: "build", size: 20)
      reservation_fixture(ctx.project, size: 5)

      body = ctx.sk_conn |> get(base(ctx.project), %{"name" => "deps"}) |> json_response(200)
      assert_schema(body, "CacheListResponse", ApiSpec.spec())
      assert [%{"key" => key} = item] = body["data"]
      assert key == deps.key
      refute Map.has_key?(item, "download_url")

      assert body["usage"] == %{
               "bytes" => 35,
               "entries" => 3,
               "quota_bytes" => 53_687_091_200,
               "max_entries" => 10_000
             }

      assert ctx.sk_conn |> get(base(ctx.project), %{"limit" => "500"}) |> json_response(422)
    end

    test "purge by name and scope; partial lookups then miss", ctx do
      p = hex(:p)
      entry_fixture(ctx.project, name: "deps", partial: p)
      entry_fixture(ctx.project, name: "deps", partial: p, committed_at: ago(10))

      body =
        ctx.sk_conn
        |> delete("#{base(ctx.project)}/entries", %{"name" => "deps", "scope" => "main"})
        |> json_response(200)

      assert_schema(body, "CachePurgeResponse", ApiSpec.spec())
      assert body["data"]["deleted"] == 2

      assert ctx.sk_conn
             |> lookup(ctx.project, %{"partial" => p, "scope" => "main"})
             |> json_response(404)
    end

    test "purge without filters is 422 and deletes nothing", ctx do
      entry_fixture(ctx.project)
      assert ctx.sk_conn |> delete("#{base(ctx.project)}/entries") |> json_response(422)
      assert entries_count(ctx.project) == 1
    end

    test "purging a missing key is 200 with 0; scope is required", ctx do
      path = "#{base(ctx.project)}/entries/#{hex(:none)}"

      assert ctx.sk_conn |> delete(path, %{"scope" => "main"}) |> json_response(200) ==
               %{"data" => %{"deleted" => 0}}

      assert ctx.sk_conn |> delete(path) |> json_response(422) |> get_in(["errors", "scope"])
    end
  end

  test "routes resolve per method for /caches/entries and /caches/entries/:key", ctx do
    entry = entry_fixture(ctx.project)

    assert ctx.sk_conn |> lookup(ctx.project, %{"partial" => entry.partial}) |> json_response(200)
    assert ctx.sk_conn |> show(ctx.project, entry.key) |> json_response(200)

    assert ctx.sk_conn
           |> delete("#{base(ctx.project)}/entries/#{entry.key}", %{"scope" => "main"})
           |> json_response(200)
           |> get_in(["data", "deleted"]) == 1

    assert ctx.sk_conn
           |> delete("#{base(ctx.project)}/entries", %{"name" => "x"})
           |> json_response(200)
  end

  test "error bodies never contain a presigned URL or signature", ctx do
    entry = entry_fixture(ctx.project)

    responses = [
      ctx.sk_conn |> reserve(ctx.project, entry.key, reservation_body("x")),
      ctx.pk_conn |> show(ctx.project, entry.key),
      ctx.sk_conn |> commit(ctx.project, Ecto.UUID.generate())
    ]

    for conn <- responses do
      assert conn.status >= 400
      refute conn.resp_body =~ Fake.signature()
      refute conn.resp_body =~ "X-Amz"
    end
  end
end
