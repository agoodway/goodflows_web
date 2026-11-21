defmodule GoodFlowsWeb.Api.V1.ReviewPolicyControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.ReviewPolicies
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  defp rp_path(slug, suffix \\ ""), do: "/api/v1/projects/#{slug}/review-policy#{suffix}"

  defp body(previous \\ 0, sections \\ %{}, note \\ "Require ci") do
    %{
      "previous_version" => previous,
      "policy" => Map.merge(%{"format" => "review-policy/1"}, sections),
      "note" => note
    }
  end

  defp admin_conn(ctx) do
    au = account_user_fixture(ctx.account, user_fixture(), :admin)
    {_key, token} = api_key_fixture(au, %{type: :private})
    {api_conn(token), au}
  end

  test "a new project reads version 0", ctx do
    data = ctx.sk_conn |> get(rp_path(ctx.project.slug)) |> json_response(200)
    assert_schema(data, "ReviewPolicyResponse", ApiSpec.spec())

    assert %{
             "version" => 0,
             "written_by" => nil,
             "note" => nil,
             "inserted_at" => nil,
             "effective" => %{
               "claims" => %{"min_proof_level" => "ran"},
               "size" => %{"max_changed_files" => 40},
               "evidence" => %{"required_workflows" => []},
               "scenarios" => %{"require_approved_intent" => false, "spec_gaps" => "ignore"},
               "coverage" => %{"unmapped_areas" => "ignore", "undriven_features" => "ignore"}
             }
           } = data["data"]

    assert ctx.sk_conn |> get(rp_path(ctx.project.slug, "/versions")) |> json_response(200) ==
             %{"data" => [], "next_cursor" => nil}
  end

  test "an admin writes a version; a retry is 200; a stale write is 409", ctx do
    {conn, au} = admin_conn(ctx)
    created = conn |> put_json(rp_path(ctx.project.slug), body()) |> json_response(201)
    assert_schema(created, "ReviewPolicyResponse", ApiSpec.spec())

    assert %{
             "version" => 1,
             "previous_version" => 0,
             "note" => "Require ci",
             "written_by" => %{"user_id" => user_id},
             "active_settings" => active
           } = created["data"]

    assert user_id == au.user_id
    assert "claims.one_way_door" in active
    refute "coverage.undriven_features" in active

    assert %{"data" => %{"version" => 1}} =
             conn |> put_json(rp_path(ctx.project.slug), body()) |> json_response(200)

    assert conn
           |> put_json(rp_path(ctx.project.slug), body(0, %{}, "other"))
           |> json_response(409)

    partial = body(1, %{"size" => %{"max_changed_files" => 10}})
    v2 = ctx.sk_conn |> put_json(rp_path(ctx.project.slug), partial) |> json_response(201)
    assert v2["data"]["effective"]["size"]["max_changed_lines"] == 1500
    assert v2["data"]["policy"] == partial["policy"]

    v1 = ctx.sk_conn |> get(rp_path(ctx.project.slug, "/versions/1")) |> json_response(200)
    assert v1["data"]["policy"] == %{"format" => "review-policy/1"}
    assert ctx.sk_conn |> get(rp_path(ctx.project.slug, "/versions/9")) |> json_response(404)
    assert ctx.sk_conn |> get(rp_path(ctx.project.slug, "/versions/x")) |> json_response(422)
  end

  test "public keys read with note and written_by null and cannot write", ctx do
    {:ok, :created, _} =
      ReviewPolicies.write(
        ctx.project,
        GoodFlows.Repo.preload(ctx.sk_key, :account_user).account_user,
        ctx.sk_key,
        body()
      )

    history = ctx.pk_conn |> get(rp_path(ctx.project.slug, "/versions")) |> json_response(200)
    assert_schema(history, "ReviewPolicyVersionListResponse", ApiSpec.spec())
    assert [%{"version" => 1, "note" => nil, "written_by" => nil}] = history["data"]

    assert %{"note" => nil, "written_by" => nil} =
             ctx.pk_conn
             |> get(rp_path(ctx.project.slug))
             |> json_response(200)
             |> Map.fetch!("data")

    assert ctx.pk_conn |> put_json(rp_path(ctx.project.slug), body(1)) |> json_response(403)
    assert ReviewPolicies.current(ctx.project).version == 1
  end

  test "a plain member gets 403 before the body is read", ctx do
    conn = ctx.member_sk_conn |> put_json(rp_path(ctx.project.slug), "{")
    assert json_response(conn, 403)
    assert ReviewPolicies.current(ctx.project).version == 0
  end

  test "cache keys, missing keys, unknown and other accounts' projects", ctx do
    owner = GoodFlows.Repo.preload(ctx.sk_key, :account_user).account_user
    {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read"})
    assert api_conn(ck) |> get(rp_path(ctx.project.slug)) |> json_response(403)
    assert api_conn(ck) |> put_json(rp_path(ctx.project.slug), body()) |> json_response(403)

    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> get(rp_path(ctx.project.slug))
           |> json_response(401)

    assert api_conn("sk_nope") |> get(rp_path(ctx.project.slug)) |> json_response(401)
    assert ctx.sk_conn |> get(rp_path("missing")) |> json_response(404)
    assert ctx.other_conn |> get(rp_path(ctx.project.slug)) |> json_response(404)
    assert ctx.sk_conn |> get(rp_path("Bad Slug")) |> json_response(422)
  end

  test "strict JSON bodies", ctx do
    slug = ctx.project.slug
    assert ctx.sk_conn |> put_json(rp_path(slug), "{") |> json_response(400)

    assert %{"errors" => %{"body" => ["has a duplicate key"]}} =
             ctx.sk_conn
             |> put_json(
               rp_path(slug),
               ~s({"previous_version": 0, "policy": {"format": "review-policy/1"}, "policy": {}})
             )
             |> json_response(422)

    assert ctx.sk_conn
           |> put_json(
             rp_path(slug),
             ~s({"previous_version": 0.5, "policy": {"format": "review-policy/1"}})
           )
           |> json_response(422)

    assert ctx.sk_conn
           |> put_req_header("content-type", "text/plain")
           |> put(rp_path(slug), "{}")
           |> json_response(415)

    assert ctx.sk_conn
           |> put_req_header("content-type", "application/json")
           |> put_req_header("content-encoding", "gzip")
           |> put(rp_path(slug), "{}")
           |> json_response(415)

    assert ctx.sk_conn
           |> put_req_header("content-type", "application/json")
           |> put_req_header("content-length", "262145")
           |> put(rp_path(slug), "{}")
           |> json_response(413)

    big =
      body(0, %{}, nil) |> Map.delete("note") |> Map.put("pad", String.duplicate("a", 262_200))

    assert ctx.sk_conn |> put_json(rp_path(slug), big) |> json_response(413)

    assert %{"errors" => %{"policy" => ["has an unknown field"]}} =
             ctx.sk_conn
             |> put_json(rp_path(slug), body(0, %{"rules" => []}))
             |> json_response(422)

    assert ReviewPolicies.current(ctx.project).version == 0
  end
end
