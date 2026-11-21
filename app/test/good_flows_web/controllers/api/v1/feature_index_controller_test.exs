defmodule GoodFlowsWeb.Api.V1.FeatureIndexControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.FeatureIndex.Version
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx, do: %{project: project_fixture(ctx.account)}

  defp fi_path(ctx, suffix \\ ""),
    do: "/api/v1/projects/#{ctx.project.slug}/feature-index" <> suffix

  @body %{
    "features" => [
      %{"id" => "checkout", "title" => "Checkout", "paths" => ["app/lib/shop/checkout/**"]}
    ]
  }

  test "member sk_ syncs, pk_ reads, pk_ and ck_ refused", ctx do
    assert ctx.pk_conn |> get(fi_path(ctx)) |> json_response(404)
    assert ctx.pk_conn |> post_json(fi_path(ctx), @body) |> json_response(403)
    assert Repo.aggregate(Version, :count) == 0

    created = ctx.member_sk_conn |> post_json(fi_path(ctx), @body) |> json_response(201)
    assert_schema(created, "FeatureIndexResponse", ApiSpec.spec())
    assert %{"version" => 1, "duplicate" => false} = created["data"]

    assert %{"data" => %{"version" => 1, "duplicate" => true}} =
             ctx.sk_conn |> post_json(fi_path(ctx), @body) |> json_response(200)

    shown = ctx.pk_conn |> get(fi_path(ctx)) |> json_response(200)
    assert shown["data"]["features"] == @body["features"]

    owner = Repo.preload(ctx.sk_key, :account_user).account_user
    {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read_write"})
    assert api_conn(ck) |> get(fi_path(ctx)) |> json_response(403)
  end

  test "versions list and show; invalid bodies", ctx do
    ctx.sk_conn |> post_json(fi_path(ctx), @body) |> json_response(201)
    changed = put_in(@body, ["features", Access.at(0), "paths"], ["app/lib/shop/**"])
    ctx.sk_conn |> post_json(fi_path(ctx), changed) |> json_response(201)

    list = ctx.pk_conn |> get(fi_path(ctx, "/versions")) |> json_response(200)
    assert_schema(list, "FeatureIndexVersionListResponse", ApiSpec.spec())
    assert [%{"version" => 2, "feature_count" => 1}, %{"version" => 1}] = list["data"]

    assert %{"data" => %{"version" => 1}} =
             ctx.pk_conn |> get(fi_path(ctx, "/versions/1")) |> json_response(200)

    assert ctx.pk_conn |> get(fi_path(ctx, "/versions/3")) |> json_response(404)
    assert ctx.pk_conn |> get(fi_path(ctx, "/versions/x")) |> json_response(404)

    assert %{"errors" => %{"features" => _}} =
             ctx.sk_conn |> post_json(fi_path(ctx), %{"features" => []}) |> json_response(422)

    dup = %{"features" => [feature("login", ["a"]), feature("login", ["b"])]}
    assert ctx.sk_conn |> post_json(fi_path(ctx), dup) |> json_response(422)
    assert ctx.sk_conn |> post_json(fi_path(ctx), "{") |> json_response(400)
    assert Repo.aggregate(Version, :count) == 2
  end
end
