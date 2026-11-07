defmodule GoodFlowsWeb.Plugs.RequireParsedBodyTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.SpryFixtures

  alias GoodFlows.Repo
  alias GoodFlows.Spry.Recipe

  setup :api_setup

  setup ctx do
    credential_fixture(ctx.account)
    project = project_fixture(ctx.account)
    %{project: project, recipe: recipe_fixture(project)}
  end

  defp plain(conn), do: put_req_header(conn, "content-type", "text/plain")

  defp write_routes(%{project: project, recipe: recipe}) do
    [
      {:post, "/api/v1/projects"},
      {:put, "/api/v1/sprites-credential"},
      {:post, "/api/v1/projects/#{project.slug}/recipes"},
      {:put, "/api/v1/projects/#{project.slug}/recipes/#{recipe.id}"},
      {:post, "/api/v1/projects/#{project.slug}/recipes/#{recipe.id}/runs"}
    ]
  end

  test "an unparsed text/plain body on a write route is 415, not 500", ctx do
    for {method, path} <- write_routes(ctx) do
      conn = ctx.sk_conn |> plain() |> dispatch(@endpoint, method, path, ~s({"name":"x"}))

      assert %{"errors" => %{"detail" => "Unsupported Media Type"}} = json_response(conn, 415),
             "#{method} #{path}"
    end

    assert Repo.aggregate(Recipe, :count) == 1
    assert %Recipe{name: name} = Repo.get!(Recipe, ctx.recipe.id)
    assert name == ctx.recipe.name
  end

  test "authentication and write access come before 415", ctx do
    path = "/api/v1/projects/#{ctx.project.slug}/recipes"

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> plain()
      |> post(path, "name=x")

    assert json_response(conn, 401)
    assert ctx.pk_conn |> plain() |> post(path, "name=x") |> json_response(403)
  end

  test "a body-less delete with a text/plain content type is not rejected", ctx do
    conn =
      ctx.sk_conn
      |> plain()
      |> delete("/api/v1/projects/#{ctx.project.slug}/recipes/#{ctx.recipe.id}")

    assert response(conn, 204)
  end

  test "a JSON body still reaches the controller", ctx do
    conn =
      ctx.sk_conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/projects/#{ctx.project.slug}/recipes",
        Jason.encode!(recipe_attrs(%{"name" => "json-recipe"}))
      )

    assert json_response(conn, 201)
  end
end
