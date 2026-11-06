defmodule GoodFlowsWeb.Api.V1.ProjectControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Projects
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  describe "create" do
    test "returns 201 with the slug and an id, without account_id", ctx do
      body =
        ctx.sk_conn |> post(~p"/api/v1/projects", %{"slug" => "goodcases"}) |> json_response(201)

      assert_schema(body, "ProjectResponse", ApiSpec.spec())
      assert %{"id" => id, "slug" => "goodcases"} = body["data"]
      refute Map.has_key?(body["data"], "account_id")
      assert {:ok, %{id: ^id}} = Projects.get_project(ctx.account, "goodcases")
    end

    test "a duplicate slug is 422 on slug; another account may reuse it", ctx do
      ctx.sk_conn |> post(~p"/api/v1/projects", %{"slug" => "goodcases"}) |> json_response(201)

      body =
        ctx.sk_conn |> post(~p"/api/v1/projects", %{"slug" => "goodcases"}) |> json_response(422)

      assert_schema(body, "ValidationErrorResponse", ApiSpec.spec())
      assert body["errors"]["slug"]
      assert [_] = Projects.list_projects(ctx.account)

      ctx.other_conn |> post(~p"/api/v1/projects", %{"slug" => "goodcases"}) |> json_response(201)
    end

    test "invalid slugs are 422 on slug and store nothing", ctx do
      for slug <- ["GoodCases", "-app", "abc\n", "", String.duplicate("a", 65)] do
        body = ctx.sk_conn |> post(~p"/api/v1/projects", %{"slug" => slug}) |> json_response(422)
        assert body["errors"]["slug"], "expected #{inspect(slug)} to be rejected"
      end

      assert Projects.list_projects(ctx.account) == []
    end

    test "public keys cannot create", ctx do
      assert ctx.pk_conn |> post(~p"/api/v1/projects", %{"slug" => "x"}) |> json_response(403)
      assert Projects.list_projects(ctx.account) == []
    end
  end

  describe "read" do
    test "lists the account's projects ordered by slug, also with a public key", ctx do
      for slug <- ["zeta", "alpha"], do: project_fixture(ctx.account, %{"slug" => slug})
      project_fixture(ctx.other_account, %{"slug" => "beta"})

      body = ctx.pk_conn |> get(~p"/api/v1/projects") |> json_response(200)
      assert_schema(body, "ProjectListResponse", ApiSpec.spec())
      assert Enum.map(body["data"], & &1["slug"]) == ["alpha", "zeta"]
    end

    test "shows a project", ctx do
      project = project_fixture(ctx.account)

      body = ctx.pk_conn |> get(~p"/api/v1/projects/#{project.slug}") |> json_response(200)
      assert_schema(body, "ProjectResponse", ApiSpec.spec())
      assert body["data"]["id"] == project.id
      assert body["data"]["slug"] == project.slug
    end

    test "a 64-byte slug is served; a 65-byte path slug is 422", ctx do
      slug = String.duplicate("a", 64)
      project_fixture(ctx.account, %{"slug" => slug})

      body = ctx.pk_conn |> get(~p"/api/v1/projects/#{slug}") |> json_response(200)
      assert body["data"]["slug"] == slug

      assert ctx.pk_conn
             |> get(~p"/api/v1/projects/#{slug <> "a"}")
             |> json_response(422)
             |> get_in(["errors", "project"])
    end

    test "another account's project is 404", ctx do
      project = project_fixture(ctx.other_account)
      assert ctx.sk_conn |> get(~p"/api/v1/projects/#{project.slug}") |> json_response(404)
      assert ctx.sk_conn |> delete(~p"/api/v1/projects/#{project.slug}") |> json_response(404)
    end

    test "project-scoped routes without a Bearer token are 401", %{conn: conn} do
      for path <- ["/api/v1/projects/missing", "/api/v1/projects/GoodCases"] do
        assert conn |> get(path) |> json_response(401)
        assert conn |> delete(path) |> json_response(401)
      end
    end

    test "an invalid path slug is 422 on project", ctx do
      for slug <- ["GoodCases", "-app"] do
        body = ctx.sk_conn |> get(~p"/api/v1/projects/#{slug}") |> json_response(422)
        assert_schema(body, "ValidationErrorResponse", ApiSpec.spec())
        assert body["errors"]["project"]

        assert ctx.sk_conn
               |> delete(~p"/api/v1/projects/#{slug}")
               |> json_response(422)
               |> get_in(["errors", "project"])
      end
    end
  end

  describe "delete" do
    test "an empty project is deleted; a later show is 404", ctx do
      project = project_fixture(ctx.account)

      assert ctx.sk_conn |> delete(~p"/api/v1/projects/#{project.slug}") |> response(204)
      assert ctx.sk_conn |> get(~p"/api/v1/projects/#{project.slug}") |> json_response(404)
    end

    test "a project with a recipe is 409 and both remain", ctx do
      project = project_fixture(ctx.account)
      recipe = recipe_fixture(project)
      run_fixture(ctx.account, recipe, status: "succeeded")

      body = ctx.sk_conn |> delete(~p"/api/v1/projects/#{project.slug}") |> json_response(409)
      assert_schema(body, "ConflictResponse", ApiSpec.spec())
      assert body["errors"]["detail"] =~ "recipes"
      assert {:ok, _} = Projects.get_project(ctx.account, project.slug)
      assert {:ok, _} = GoodFlows.Spry.get_recipe(ctx.account, project, recipe.id)
    end

    test "public keys cannot delete", ctx do
      project = project_fixture(ctx.account)

      assert ctx.pk_conn |> delete(~p"/api/v1/projects/#{project.slug}") |> json_response(403)
      assert {:ok, _} = Projects.get_project(ctx.account, project.slug)
    end

    test "a public key deleting a missing or invalid project is 403", ctx do
      assert ctx.pk_conn |> delete(~p"/api/v1/projects/missing") |> json_response(403)
      assert ctx.pk_conn |> delete(~p"/api/v1/projects/GoodCases") |> json_response(403)
    end
  end

  test "there is no update route", ctx do
    project = project_fixture(ctx.account)

    assert ctx.sk_conn
           |> put(~p"/api/v1/projects/#{project.slug}", %{"slug" => "renamed"})
           |> response(404)
  end

  test "operations appear in the OpenAPI document", %{conn: conn} do
    doc = conn |> get(~p"/api/v1/openapi") |> json_response(200)

    delete = doc["paths"]["/api/v1/projects/{project}"]["delete"]

    assert delete["responses"]["409"]["content"]["application/json"]["schema"]["$ref"] =~
             "ConflictResponse"

    for name <- ~w(Project ProjectRequest ProjectResponse ProjectListResponse) do
      assert doc["components"]["schemas"][name], "missing schema #{name}"
    end
  end
end
