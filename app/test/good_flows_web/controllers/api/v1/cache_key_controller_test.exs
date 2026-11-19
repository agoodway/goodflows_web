defmodule GoodFlowsWeb.Api.V1.CacheKeyControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.CacheFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Accounts.ApiKey
  alias GoodFlows.Caches.{Keys, Sweep}
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account, %{"slug" => "alpha"})}
  end

  defp mint(conn, project, body),
    do: post(conn, ~p"/api/v1/projects/#{project.slug}/cache-keys", body)

  defp cache_key_count, do: Repo.aggregate(where_cache_keys(), :count)

  defp where_cache_keys do
    import Ecto.Query
    where(ApiKey, [k], k.type in ^ApiKey.cache_types())
  end

  defp lookup(token, project, key \\ hex(:missing)),
    do: token |> api_conn() |> get("/api/v1/projects/#{project.slug}/caches/entries/#{key}")

  describe "ApiAuth refuses cache keys outside cache routes" do
    test "a ck_ key gets 403 on read and write routes", ctx do
      {_key, token} = cache_key_fixture(ctx.account, ctx.project)
      conn = api_conn(token)
      slug = ctx.project.slug

      assert conn |> get(~p"/api/v1/projects") |> json_response(403)
      assert conn |> get(~p"/api/v1/me") |> json_response(403)
      assert conn |> get(~p"/api/v1/projects/#{slug}/workflow-runs") |> json_response(403)

      assert conn
             |> put_req_header("content-type", "application/json")
             |> post(~p"/api/v1/projects/#{slug}/test-reports", "{}")
             |> json_response(403)

      assert conn |> get(~p"/api/v1/projects/#{slug}/cache-keys") |> json_response(403)

      count = cache_key_count()

      assert conn
             |> mint(ctx.project, %{"access" => "read_write"})
             |> json_response(403)

      assert cache_key_count() == count
    end

    test "sk_ and pk_ keys keep their access", ctx do
      assert ctx.sk_conn |> get(~p"/api/v1/projects") |> json_response(200)
      assert ctx.pk_conn |> get(~p"/api/v1/projects") |> json_response(200)
      assert ctx.pk_conn |> get(~p"/api/v1/me") |> json_response(200)
    end
  end

  describe "mint" do
    test "a bound read-write key with a TTL", ctx do
      body =
        ctx.sk_conn
        |> mint(ctx.project, %{
          "access" => "read_write",
          "scope" => "feature/login",
          "ttl_seconds" => 3600
        })
        |> json_response(201)

      assert_schema(body, "CacheKeyResponse", ApiSpec.spec())

      assert %{"token" => "ck_" <> _, "access" => "read_write", "scope" => "feature/login"} =
               body["data"]

      {:ok, expires_at, 0} = DateTime.from_iso8601(body["data"]["expires_at"])
      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 3600, 5

      key = Repo.get!(ApiKey, body["data"]["id"])
      assert key.type == :cache_write
      assert key.project_id == ctx.project.id
      assert key.scope == "feature/login"
    end

    test "public keys cannot mint", ctx do
      assert ctx.pk_conn |> mint(ctx.project, %{"access" => "read"}) |> json_response(403)
      assert cache_key_count() == 0
    end

    test "omitting ttl_seconds gives 21,600 seconds", ctx do
      body = ctx.sk_conn |> mint(ctx.project, %{"access" => "read"}) |> json_response(201)
      {:ok, expires_at, 0} = DateTime.from_iso8601(body["data"]["expires_at"])
      assert_in_delta DateTime.diff(expires_at, DateTime.utc_now()), 21_600, 5
    end

    test "a named read key without expiry", ctx do
      body =
        ctx.sk_conn
        |> mint(ctx.project, %{"access" => "read", "ttl_seconds" => nil, "name" => "orb setup"})
        |> json_response(201)

      assert body["data"]["expires_at"] == nil
      assert Repo.get!(ApiKey, body["data"]["id"]).name == "orb setup"
    end

    test "invalid lifetimes or fields and unknown keys are 422 and create nothing", ctx do
      cases = [
        {%{"access" => "read_write", "ttl_seconds" => nil}, "ttl_seconds"},
        {%{"access" => "read_write", "ttl_seconds" => 86_401}, "ttl_seconds"},
        {%{"access" => "read_write", "ttl_seconds" => 59}, "ttl_seconds"},
        {%{"access" => "read", "ttl_seconds" => 59}, "ttl_seconds"},
        {%{"access" => "read", "ttl_seconds" => 31_536_001}, "ttl_seconds"},
        {%{"access" => "read", "ttl_seconds" => "3600"}, "ttl_seconds"},
        {%{"access" => "read", "ttl_seconds" => nil}, "name"},
        {%{"access" => "write"}, "access"},
        {%{}, "access"},
        {%{"access" => "read", "scope" => "main\n"}, "scope"},
        {%{"access" => "read", "name" => String.duplicate("n", 101)}, "name"},
        {%{"access" => "read", "ttl" => 3600}, "ttl"}
      ]

      for {body, field} <- cases do
        resp = ctx.sk_conn |> mint(ctx.project, body) |> json_response(422)
        assert resp["errors"][field], "#{inspect(body)} should be 422 on #{field}"
      end

      assert cache_key_count() == 0
    end

    test "minting above the project's cap of active keys is 422 and creates nothing", ctx do
      account_user = owner_account_user(ctx.account)
      now = DateTime.utc_now(:second)

      key_row = fn i, overrides ->
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            name: "key #{i}",
            type: :cache_read,
            token_prefix: "ck_cap#{i}",
            token_hash: "cap-hash-#{ctx.project.id}-#{i}",
            status: :active,
            expires_at: DateTime.add(now, 3_600, :second),
            account_user_id: account_user.id,
            project_id: ctx.project.id,
            inserted_at: now,
            updated_at: now
          },
          overrides
        )
      end

      # Revoked and expired keys do not count toward the cap of 1,000.
      rows =
        [key_row.(:revoked, %{status: :revoked}), key_row.(:expired, %{expires_at: now})] ++
          for i <- 1..999, do: key_row.(i, %{})

      Repo.insert_all(ApiKey, rows)

      body = %{"access" => "read"}
      assert ctx.sk_conn |> mint(ctx.project, body) |> json_response(201)

      count = cache_key_count()
      response = ctx.sk_conn |> mint(ctx.project, body) |> json_response(422)
      assert response["errors"]["detail"] =~ "1000 active cache keys"
      assert cache_key_count() == count

      # Another project has its own cap.
      other = project_fixture(ctx.account, %{"slug" => "beta"})
      assert ctx.sk_conn |> mint(other, body) |> json_response(201)
    end

    test "the upper TTL bounds are accepted", ctx do
      assert ctx.sk_conn
             |> mint(ctx.project, %{"access" => "read_write", "ttl_seconds" => 86_400})
             |> json_response(201)

      assert ctx.sk_conn
             |> mint(ctx.project, %{"access" => "read", "ttl_seconds" => 31_536_000})
             |> json_response(201)
    end

    test "an expired key gets 401", ctx do
      {key, token} = cache_key_fixture(ctx.account, ctx.project, %{"ttl_seconds" => 60})
      past = DateTime.utc_now(:second) |> DateTime.add(-60, :second)
      key |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      assert lookup(token, ctx.project) |> json_response(401)
    end

    test "a non-expiring read key still restores after the sweep runs", ctx do
      {_key, token} =
        cache_key_fixture(ctx.account, ctx.project, %{
          "access" => "read",
          "ttl_seconds" => nil,
          "name" => "orbs"
        })

      entry = entry_fixture(ctx.project, last_accessed_at: DateTime.utc_now())
      Sweep.run()

      assert lookup(token, ctx.project, entry.key) |> json_response(200)
    end
  end

  describe "list" do
    test "lists active keys without tokens", ctx do
      {orb, _token} =
        cache_key_fixture(ctx.account, ctx.project, %{
          "access" => "read",
          "ttl_seconds" => nil,
          "name" => "orbs"
        })

      {revoked, _token} = cache_key_fixture(ctx.account, ctx.project)
      assert :ok = Keys.revoke(ctx.project, revoked.id)

      {expired, _token} = cache_key_fixture(ctx.account, ctx.project)
      past = DateTime.utc_now(:second) |> DateTime.add(-1, :second)
      expired |> Ecto.Changeset.change(expires_at: past) |> Repo.update!()

      other = project_fixture(ctx.account)
      cache_key_fixture(ctx.account, other)

      body =
        ctx.sk_conn
        |> get(~p"/api/v1/projects/#{ctx.project.slug}/cache-keys")
        |> json_response(200)

      assert_schema(body, "CacheKeyListResponse", ApiSpec.spec())
      assert [listed] = body["data"]
      assert listed["id"] == orb.id
      assert listed["name"] == "orbs"
      assert listed["access"] == "read"
      assert listed["expires_at"] == nil
      refute Map.has_key?(listed, "token")
      refute inspect(body) =~ "token_hash"
    end

    test "pages newest first with a cursor", ctx do
      for _ <- 1..3, do: cache_key_fixture(ctx.account, ctx.project)
      path = ~p"/api/v1/projects/#{ctx.project.slug}/cache-keys"

      first = ctx.sk_conn |> get(path, %{"limit" => "2"}) |> json_response(200)
      assert length(first["data"]) == 2
      assert first["next_cursor"]

      second =
        ctx.sk_conn
        |> get(path, %{"limit" => "2", "cursor" => first["next_cursor"]})
        |> json_response(200)

      assert length(second["data"]) == 1
      assert second["next_cursor"] == nil

      ids = Enum.map(first["data"] ++ second["data"], & &1["id"])
      assert length(Enum.uniq(ids)) == 3

      assert ctx.sk_conn |> get(path, %{"cursor" => "bogus"}) |> json_response(422)
      assert ctx.sk_conn |> get(path, %{"limit" => "0"}) |> json_response(422)
    end

    test "public keys cannot list", ctx do
      assert ctx.pk_conn
             |> get(~p"/api/v1/projects/#{ctx.project.slug}/cache-keys")
             |> json_response(403)
    end
  end

  describe "revoke" do
    test "a revoked key gets 401; revoking again is 204", ctx do
      {key, token} = cache_key_fixture(ctx.account, ctx.project)
      path = ~p"/api/v1/projects/#{ctx.project.slug}/cache-keys/#{key.id}"

      assert ctx.sk_conn |> delete(path) |> response(204)
      assert lookup(token, ctx.project) |> json_response(401)
      assert ctx.sk_conn |> delete(path) |> response(204)
    end

    test "another project's key, an sk_ key, and a bad id are 404", ctx do
      other = project_fixture(ctx.account)
      {other_key, other_token} = cache_key_fixture(ctx.account, other)
      base = "/api/v1/projects/#{ctx.project.slug}/cache-keys"

      assert ctx.sk_conn |> delete("#{base}/#{other_key.id}") |> json_response(404)
      assert lookup(other_token, other) |> json_response(404)

      assert ctx.sk_conn |> delete("#{base}/#{ctx.sk_key.id}") |> json_response(404)
      assert ctx.sk_conn |> get(~p"/api/v1/projects") |> json_response(200)

      assert ctx.sk_conn |> delete("#{base}/not-a-uuid") |> json_response(404)
    end

    test "public keys cannot revoke", ctx do
      {key, token} = cache_key_fixture(ctx.account, ctx.project)

      assert ctx.pk_conn
             |> delete(~p"/api/v1/projects/#{ctx.project.slug}/cache-keys/#{key.id}")
             |> json_response(403)

      assert lookup(token, ctx.project) |> json_response(404)
    end
  end
end
