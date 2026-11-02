defmodule GoodFlowsWeb.Api.V1.PoolControllerTest do
  use GoodFlowsWeb.ConnCase, async: false

  import GoodFlows.PoolsFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Pools.{Config, Pool}
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    credential_fixture(ctx.account)

    %{
      project: project_fixture(ctx.account, %{"slug" => "app"}),
      web: project_fixture(ctx.account, %{"slug" => "web"})
    }
  end

  defp pools_path(project), do: "/api/v1/projects/#{project.slug}/pools"
  defp pool_path(project, slug), do: "#{pools_path(project)}/#{slug}"

  @body %{
    "slug" => "rust-ci",
    "setup" => ["curl -sSf https://sh.rustup.rs | sh -s -- -y"],
    "max_members" => 4
  }

  describe "create" do
    test "201 with defaults", ctx do
      body = ctx.sk_conn |> post(pools_path(ctx.project), @body) |> json_response(201)
      assert_schema(body, "PoolResponse", ApiSpec.spec())

      assert %{
               "slug" => "rust-ci",
               "project" => "app",
               "min_ready" => 1,
               "setup_version" => 1,
               "status" => "active",
               "provision_failures" => 0,
               "next_provision_at" => nil,
               "last_provision_error" => nil
             } = body["data"]

      refute Map.has_key?(body["data"], "golden_checkpoint_id")
    end

    test "duplicate slug is 422, another project may reuse it", ctx do
      ctx.sk_conn |> post(pools_path(ctx.project), @body) |> json_response(201)
      body = ctx.sk_conn |> post(pools_path(ctx.project), @body) |> json_response(422)
      assert body["errors"]["slug"]
      ctx.sk_conn |> post(pools_path(ctx.web), @body) |> json_response(201)
    end

    test "validation errors are 422 on the field", ctx do
      cases = [
        {%{@body | "max_members" => 4} |> Map.put("min_ready", 5), "min_ready"},
        {%{@body | "max_members" => Config.max_members_cap() + 1}, "max_members"},
        {%{@body | "setup" => ["git checkout {{commit}}"]}, "setup[0]"},
        {%{@body | "setup" => [%{"host" => "x"}]}, "setup[0]"},
        {Map.put(@body, "project", "app"), "project"},
        {Map.put(@body, "setup_version", 3), "setup_version"}
      ]

      for {body, field} <- cases do
        resp = ctx.sk_conn |> post(pools_path(ctx.project), body) |> json_response(422)
        assert_schema(resp, "ValidationErrorResponse", ApiSpec.spec())
        assert resp["errors"][field], "no error on #{field}"
      end

      resp =
        ctx.sk_conn
        |> post(pools_path(ctx.project), %{@body | "setup" => ["git checkout {{commit}}"]})
        |> json_response(422)

      assert hd(resp["errors"]["setup[0]"]) =~ "{{commit}}"
      assert Repo.aggregate(Pool, :count) == 0
    end

    test "no credential is 422", ctx do
      GoodFlows.Spry.delete_credential(ctx.account)
      body = ctx.sk_conn |> post(pools_path(ctx.project), @body) |> json_response(422)
      assert body["errors"]["detail"] =~ "Sprites credential must be configured"
      assert Repo.aggregate(Pool, :count) == 0
    end

    test "public keys are 403", ctx do
      assert ctx.pk_conn |> post(pools_path(ctx.project), @body) |> json_response(403)
    end
  end

  describe "reads" do
    setup ctx do
      pool = pool_fixture(ctx.project, %{"slug" => "rust-ci"})
      member_fixture(pool)
      member_fixture(pool, %{state: "provisioning", helper_version: nil})
      %{pool: pool}
    end

    test "list, show, and members with a public key", ctx do
      pool_fixture(ctx.project, %{"slug" => "a"})

      body = ctx.pk_conn |> get(pools_path(ctx.project)) |> json_response(200)
      assert_schema(body, "PoolListResponse", ApiSpec.spec())
      assert Enum.map(body["data"], & &1["slug"]) == ["a", "rust-ci"]

      body = ctx.pk_conn |> get(pool_path(ctx.project, "rust-ci")) |> json_response(200)
      assert %{"idle" => 1, "provisioning" => 1} = body["data"]["members"]

      body =
        ctx.pk_conn |> get(pool_path(ctx.project, "rust-ci") <> "/members") |> json_response(200)

      assert_schema(body, "PoolMemberListResponse", ApiSpec.spec())

      for member <- body["data"] do
        assert member["name"] =~ ~r/^gfp-[a-z0-9-]+$/
        assert member["stale"] == false
        refute Map.has_key?(member, "golden_checkpoint_id")
        refute Map.has_key?(member, "owner_id")
        refute Map.has_key?(member, "credential_snapshot")
      end

      assert Enum.sort(Enum.map(body["data"], & &1["state"])) == ["idle", "provisioning"]
    end

    test "404 under another project or account", ctx do
      assert ctx.sk_conn |> get(pool_path(ctx.web, "rust-ci")) |> json_response(404)
      assert ctx.sk_conn |> get(pool_path(ctx.web, "rust-ci") <> "/members") |> json_response(404)
      assert ctx.other_conn |> get(pool_path(ctx.project, "rust-ci")) |> json_response(404)
      assert ctx.sk_conn |> get(pool_path(ctx.project, "nope")) |> json_response(404)
      assert ctx.sk_conn |> get("/api/v1/projects/Bad/pools") |> json_response(422)
    end
  end

  describe "update" do
    test "replaces and bumps setup_version only for setup changes", ctx do
      pool_fixture(ctx.project, @body)
      path = pool_path(ctx.project, "rust-ci")

      body = ctx.sk_conn |> put(path, %{@body | "max_members" => 2}) |> json_response(200)
      assert body["data"]["setup_version"] == 1

      body = ctx.sk_conn |> put(path, %{@body | "setup" => ["x"]}) |> json_response(200)
      assert body["data"]["setup_version"] == 2
    end

    test "an unknown key is 422 on that key and leaves storage unchanged", ctx do
      pool_fixture(ctx.project, @body)
      path = pool_path(ctx.project, "rust-ci")
      before = GoodFlows.Repo.get_by!(GoodFlows.Pools.Pool, slug: "rust-ci")

      body =
        ctx.sk_conn
        |> put(path, Map.merge(@body, %{"setup" => ["changed"], "setup_version" => 9}))
        |> json_response(422)

      assert body["errors"]["setup_version"]
      after_put = GoodFlows.Repo.get_by!(GoodFlows.Pools.Pool, slug: "rust-ci")

      assert Map.take(after_put, [:setup, :setup_version, :max_members, :updated_at]) ==
               Map.take(before, [:setup, :setup_version, :max_members, :updated_at])
    end

    test "rename is 422 and keeps the pool; other project 404; pk 403", ctx do
      pool_fixture(ctx.project, @body)

      body =
        ctx.sk_conn
        |> put(pool_path(ctx.project, "rust-ci"), %{@body | "slug" => "rust"})
        |> json_response(422)

      assert body["errors"]["slug"]
      assert ctx.sk_conn |> get(pool_path(ctx.project, "rust-ci")) |> json_response(200)
      assert ctx.sk_conn |> put(pool_path(ctx.web, "rust-ci"), @body) |> json_response(404)
      assert ctx.pk_conn |> put(pool_path(ctx.project, "rust-ci"), @body) |> json_response(403)
    end
  end

  describe "delete" do
    test "202, then 404", ctx do
      pool_fixture(ctx.project, @body)
      assert ctx.sk_conn |> delete(pool_path(ctx.project, "rust-ci")) |> response(202)
      assert ctx.sk_conn |> get(pool_path(ctx.project, "rust-ci")) |> json_response(404)
    end

    test "409 with an active or waiting session", ctx do
      pool = pool_fixture(ctx.project, @body)

      for status <- ["active", "waiting"] do
        session = session_fixture(pool, ctx.sk_key, %{status: status})

        body = ctx.sk_conn |> delete(pool_path(ctx.project, "rust-ci")) |> json_response(409)
        assert_schema(body, "ConflictResponse", ApiSpec.spec())
        assert ctx.sk_conn |> get(pool_path(ctx.project, "rust-ci")) |> json_response(200)

        GoodFlows.Repo.delete!(session)
      end
    end

    test "other project 404, public key 403", ctx do
      pool_fixture(ctx.project, @body)
      assert ctx.sk_conn |> delete(pool_path(ctx.web, "rust-ci")) |> json_response(404)
      assert ctx.pk_conn |> delete(pool_path(ctx.project, "rust-ci")) |> json_response(403)
    end
  end

  describe "pools disabled" do
    setup do
      original = Application.get_env(:good_flows, GoodFlows.Pools)
      Application.put_env(:good_flows, GoodFlows.Pools, Keyword.put(original, :enabled, false))
      on_exit(fn -> Application.put_env(:good_flows, GoodFlows.Pools, original) end)
    end

    test "every pool route is 503", ctx do
      routes = [
        {:get, pools_path(ctx.project)},
        {:post, pools_path(ctx.project)},
        {:get, pool_path(ctx.project, "x")},
        {:put, pool_path(ctx.project, "x")},
        {:get, pool_path(ctx.project, "x") <> "/members"}
      ]

      for {method, path} <- routes do
        conn = dispatch(ctx.sk_conn, @endpoint, method, path, @body)
        body = json_response(conn, 503)
        assert_schema(body, "ErrorResponse", ApiSpec.spec())
      end
    end

    test "a pool can still be deleted, so a rollback can be cleaned up", ctx do
      GoodFlows.PoolsFixtures.pool_fixture(ctx.project, %{"slug" => "old"})
      assert ctx.sk_conn |> delete(pool_path(ctx.project, "old")) |> response(202)
      assert ctx.sk_conn |> delete(pool_path(ctx.project, "old")) |> json_response(404)
    end

    test "session, workspace, and report routes are 503 too", ctx do
      id = Ecto.UUID.generate()

      routes = [
        {:post, pool_path(ctx.project, "x") <> "/sessions",
         %{"max_members" => 1, "acquire_timeout_ms" => 60_000}},
        {:get, "/api/v1/pool-sessions/#{id}", nil},
        {:delete, "/api/v1/pool-sessions/#{id}", nil},
        {:get, "/api/v1/pool-execs/#{id}/reports/a.jsonl", nil}
      ]

      for {method, path, body} <- routes do
        conn = dispatch(ctx.sk_conn, @endpoint, method, path, body)
        body = json_response(conn, 503)
        assert_schema(body, "ErrorResponse", ApiSpec.spec())
      end

      conn =
        ctx.sk_conn
        |> put_req_header("content-type", "application/gzip")
        |> put("/api/v1/pool-sessions/#{id}/workspace", :zlib.gzip("x"))

      assert_schema(json_response(conn, 503), "ErrorResponse", ApiSpec.spec())
    end
  end

  test "operations appear in the OpenAPI document", %{conn: conn} do
    paths = conn |> get(~p"/api/v1/openapi") |> json_response(200) |> Map.fetch!("paths")

    for {path, verbs} <- [
          {"/api/v1/projects/{project}/pools", ~w(get post)},
          {"/api/v1/projects/{project}/pools/{pool}", ~w(get put delete)},
          {"/api/v1/projects/{project}/pools/{pool}/members", ~w(get)}
        ],
        verb <- verbs do
      assert paths[path][verb], "#{verb} #{path} is not documented"
      # Deletion stays available while pools are disabled.
      if verb == "delete",
        do: refute(paths[path][verb]["responses"]["503"]),
        else: assert(paths[path][verb]["responses"]["503"])
    end

    for {path, verb} <- [
          {"/api/v1/projects/{project}/pools", "post"},
          {"/api/v1/projects/{project}/pools/{pool}", "put"}
        ] do
      assert paths[path][verb]["responses"]["415"]
    end

    assert paths["/api/v1/projects/{project}/pools/{pool}"]["delete"]["responses"]["202"]
  end
end
