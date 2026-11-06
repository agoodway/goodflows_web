defmodule GoodFlowsWeb.Api.V1.RecipeControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    %{
      project: project_fixture(ctx.account),
      sibling: project_fixture(ctx.account, %{"slug" => "other"}),
      other_project: project_fixture(ctx.other_account)
    }
  end

  defp recipes_path(project), do: "/api/v1/projects/#{project.slug}/recipes"
  defp recipe_path(project, recipe), do: "#{recipes_path(project)}/#{recipe.id}"

  @full %{
    "name" => "myapp-{{branch_slug}}",
    "setup" => ["git clone {{remote}} app", "cd app && make"],
    "start" => ["cd app && bin/start"],
    "stop" => ["cd app && bin/stop"],
    "teardown" => ["echo bye"]
  }

  describe "create" do
    test "stores all four lists in order", %{sk_conn: conn, project: project} do
      body = conn |> post(recipes_path(project), @full) |> json_response(201)
      assert_schema(body, "RecipeResponse", ApiSpec.spec())

      data = body["data"]
      assert data["name"] == "myapp-{{branch_slug}}"
      assert data["setup"] == @full["setup"]
      assert data["teardown"] == ["echo bye"]
    end

    test "a name-only recipe gets empty lists", %{sk_conn: conn, project: project} do
      data = conn |> post(recipes_path(project), %{"name" => "demo"}) |> json_response(201)
      assert %{"setup" => [], "start" => [], "stop" => [], "teardown" => []} = data["data"]
    end

    test "missing name is 422", %{sk_conn: conn, project: project} do
      body = conn |> post(recipes_path(project), %{"setup" => ["x"]}) |> json_response(422)
      assert_schema(body, "ValidationErrorResponse", ApiSpec.spec())
      assert body["errors"]["name"]
    end

    test "a host step is 422 with the phase and index", %{sk_conn: conn, project: project} do
      body =
        conn
        |> post(recipes_path(project), %{
          "name" => "x",
          "setup" => ["echo", %{"host" => "gh repo deploy-key add ..."}]
        })
        |> json_response(422)

      assert body["errors"]["setup[1]"] == ["host steps are not supported by the API"]
    end

    test "org is 422", %{sk_conn: conn, project: project} do
      body =
        conn
        |> post(recipes_path(project), %{"name" => "x", "org" => "acme"})
        |> json_response(422)

      assert body["errors"]["org"]
    end

    test "unknown placeholders are 422 naming the placeholder", %{sk_conn: conn, project: project} do
      body =
        conn
        |> post(recipes_path(project), %{"name" => "x", "start" => ["echo {{foo}}"]})
        |> json_response(422)

      assert [message] = body["errors"]["start[0]"]
      assert message =~ "{{foo}}"
      assert message =~ "start"

      body =
        conn |> post(recipes_path(project), %{"name" => "app-{{sprite}}"}) |> json_response(422)

      assert body["errors"]["name"]
    end

    test "gfp- recipe names are accepted", %{sk_conn: conn} = ctx do
      for name <- ["gfp-{{branch_slug}}", "gfp-app"] do
        body = conn |> post(recipes_path(ctx.project), %{"name" => name}) |> json_response(201)
        assert body["data"]["name"] == name
      end

      conn |> post(recipes_path(ctx.project), %{"name" => "app-gfp"}) |> json_response(201)

      conn
      |> post(recipes_path(ctx.project), %{"name" => "{{branch_slug}}-app"})
      |> json_response(201)
    end

    test "duplicate names in one account are 422, other accounts may reuse", ctx do
      ctx.sk_conn |> post(recipes_path(ctx.project), %{"name" => "demo"}) |> json_response(201)

      body =
        ctx.sk_conn |> post(recipes_path(ctx.project), %{"name" => "demo"}) |> json_response(422)

      assert body["errors"]["name"]

      ctx.other_conn
      |> post(recipes_path(ctx.other_project), %{"name" => "demo"})
      |> json_response(201)
    end

    test "public keys cannot create", %{pk_conn: conn, project: project} do
      assert conn |> post(recipes_path(project), %{"name" => "x"}) |> json_response(403)
    end
  end

  describe "read" do
    test "lists only the account's recipes, also with a public key", ctx do
      mine = recipe_fixture(ctx.project)
      _theirs = recipe_fixture(ctx.other_project)

      body = ctx.pk_conn |> get(recipes_path(ctx.project)) |> json_response(200)
      assert_schema(body, "RecipeListResponse", ApiSpec.spec())
      assert [%{"id" => id}] = body["data"]
      assert id == mine.id
    end

    test "shows a recipe and hides other accounts' recipes", ctx do
      recipe = recipe_fixture(ctx.project)

      assert %{"data" => %{"id" => _}} =
               ctx.pk_conn |> get(recipe_path(ctx.project, recipe)) |> json_response(200)

      assert ctx.other_conn |> get(recipe_path(ctx.project, recipe)) |> json_response(404)
      assert ctx.sk_conn |> get("#{recipes_path(ctx.project)}/nope") |> json_response(404)
    end
  end

  describe "update" do
    test "replaces the recipe; an omitted list becomes empty", ctx do
      recipe = recipe_fixture(ctx.project)

      data =
        ctx.sk_conn
        |> put(recipe_path(ctx.project, recipe), %{"name" => recipe.name, "setup" => ["new"]})
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["setup"] == ["new"]
      assert data["stop"] == []
    end

    test "a replacement without name is 422 and keeps the recipe", ctx do
      recipe = recipe_fixture(ctx.project)

      body =
        ctx.sk_conn
        |> put(recipe_path(ctx.project, recipe), %{"setup" => ["new"]})
        |> json_response(422)

      assert body["errors"]["name"] == ["can't be blank"]
      assert {:ok, ^recipe} = GoodFlows.Spry.get_recipe(ctx.account, ctx.project, recipe.id)
    end

    test "a host step on update is 422 and leaves the recipe unchanged", ctx do
      recipe = recipe_fixture(ctx.project)

      ctx.sk_conn
      |> put(recipe_path(ctx.project, recipe), %{
        "name" => recipe.name,
        "teardown" => [%{"host" => "x"}]
      })
      |> json_response(422)

      assert {:ok, ^recipe} = GoodFlows.Spry.get_recipe(ctx.account, ctx.project, recipe.id)
    end

    test "public keys cannot update; other accounts get 404", ctx do
      recipe = recipe_fixture(ctx.project)

      assert ctx.pk_conn
             |> put(recipe_path(ctx.project, recipe), %{"name" => "x"})
             |> json_response(403)

      assert ctx.other_conn
             |> put(recipe_path(ctx.project, recipe), %{"name" => "x"})
             |> json_response(404)
    end
  end

  describe "delete" do
    test "deletes, then 404", ctx do
      recipe = recipe_fixture(ctx.project)
      assert ctx.sk_conn |> delete(recipe_path(ctx.project, recipe)) |> response(204)
      assert ctx.sk_conn |> get(recipe_path(ctx.project, recipe)) |> json_response(404)
    end

    test "409 while a run is active", ctx do
      recipe = recipe_fixture(ctx.project)
      run_fixture(ctx.account, recipe, status: "running")

      body = ctx.sk_conn |> delete(recipe_path(ctx.project, recipe)) |> json_response(409)
      assert_schema(body, "ConflictResponse", ApiSpec.spec())
      assert ctx.sk_conn |> get(recipe_path(ctx.project, recipe)) |> json_response(200)
    end

    test "completed runs stay retrievable after the recipe is deleted", ctx do
      recipe = recipe_fixture(ctx.project)
      run = run_fixture(ctx.account, recipe, status: "succeeded")

      run_step_fixture(run,
        index: 0,
        kind: "exec",
        command: "echo setup",
        status: "succeeded",
        exit_code: 0,
        output: "setup\n"
      )

      assert ctx.sk_conn |> delete(recipe_path(ctx.project, recipe)) |> response(204)

      data =
        ctx.sk_conn |> get(~p"/api/v1/runs/#{run.id}") |> json_response(200) |> Map.fetch!("data")

      assert data["recipe_id"] == nil
      assert [%{"output" => "setup\n"}] = data["steps"]
    end

    test "public keys cannot delete; other accounts get 404", ctx do
      recipe = recipe_fixture(ctx.project)
      assert ctx.pk_conn |> delete(recipe_path(ctx.project, recipe)) |> json_response(403)
      assert ctx.other_conn |> delete(recipe_path(ctx.project, recipe)) |> json_response(404)
    end
  end

  describe "projects" do
    test "201 returns project_id and project", ctx do
      body = ctx.sk_conn |> post(recipes_path(ctx.project), @full) |> json_response(201)
      assert body["data"]["project"] == ctx.project.slug
      assert body["data"]["project_id"] == ctx.project.id

      shown =
        ctx.pk_conn
        |> get("#{recipes_path(ctx.project)}/#{body["data"]["id"]}")
        |> json_response(200)

      assert shown["data"]["project"] == ctx.project.slug

      slug = ctx.project.slug

      assert [%{"project" => ^slug}] =
               ctx.pk_conn
               |> get(recipes_path(ctx.project))
               |> json_response(200)
               |> Map.fetch!("data")
    end

    test "a body project on create is 422 and stores nothing", ctx do
      body =
        ctx.sk_conn
        |> post(recipes_path(ctx.project), %{"name" => "demo", "project" => "other"})
        |> json_response(422)

      assert body["errors"]["project"]
      assert GoodFlows.Spry.list_recipes(ctx.account, ctx.project) == []
      assert GoodFlows.Spry.list_recipes(ctx.account, ctx.sibling) == []
    end

    test "a body project on replace is 422 and keeps the recipe", ctx do
      recipe = recipe_fixture(ctx.project)

      body =
        ctx.sk_conn
        |> put(recipe_path(ctx.project, recipe), %{"name" => "new", "project" => "other"})
        |> json_response(422)

      assert body["errors"]["project"]
      assert {:ok, ^recipe} = GoodFlows.Spry.get_recipe(ctx.account, ctx.project, recipe.id)
    end

    test "replace keeps the project", ctx do
      recipe = recipe_fixture(ctx.project)

      data =
        ctx.sk_conn
        |> put(recipe_path(ctx.project, recipe), %{
          "name" => "new",
          "project_id" => ctx.sibling.id
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["project"] == ctx.project.slug
      assert data["project_id"] == ctx.project.id
    end

    test "the same name in two projects is allowed", ctx do
      ctx.sk_conn |> post(recipes_path(ctx.project), %{"name" => "demo"}) |> json_response(201)
      ctx.sk_conn |> post(recipes_path(ctx.sibling), %{"name" => "demo"}) |> json_response(201)
    end

    test "list omits other projects' recipes", ctx do
      recipe_fixture(ctx.sibling)
      assert %{"data" => []} = ctx.pk_conn |> get(recipes_path(ctx.project)) |> json_response(200)
    end

    test "show, replace, and delete under another project of the account are 404", ctx do
      recipe = recipe_fixture(ctx.project)
      path = recipe_path(ctx.sibling, recipe)

      assert ctx.sk_conn |> get(path) |> json_response(404)
      assert ctx.sk_conn |> put(path, %{"name" => "x"}) |> json_response(404)
      assert ctx.sk_conn |> delete(path) |> json_response(404)
      assert {:ok, ^recipe} = GoodFlows.Spry.get_recipe(ctx.account, ctx.project, recipe.id)
    end

    test "a missing project is 404 for create and list and creates nothing", ctx do
      assert ctx.sk_conn
             |> post("/api/v1/projects/missing/recipes", %{"name" => "demo"})
             |> json_response(404)

      assert ctx.pk_conn |> get("/api/v1/projects/missing/recipes") |> json_response(404)
      assert GoodFlows.Projects.get_project(ctx.account, "missing") == {:error, :not_found}
    end

    test "a public key writing to a missing project is 403", ctx do
      assert ctx.pk_conn
             |> post("/api/v1/projects/missing/recipes", %{"name" => "demo"})
             |> json_response(403)
    end

    test "an invalid project slug is 422 on project and stores nothing", ctx do
      for slug <- ["GoodCases", "-app", String.duplicate("a", 65)] do
        body = ctx.pk_conn |> get("/api/v1/projects/#{slug}/recipes") |> json_response(422)
        assert_schema(body, "ValidationErrorResponse", ApiSpec.spec())
        assert body["errors"]["project"]
      end

      body =
        ctx.sk_conn
        |> post("/api/v1/projects/GoodCases/recipes", %{"name" => "demo"})
        |> json_response(422)

      assert body["errors"]["project"]
      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Recipe, :count) == 0
    end

    test "project delete with a recipe is 409", ctx do
      recipe = recipe_fixture(ctx.project)

      body = ctx.sk_conn |> delete("/api/v1/projects/#{ctx.project.slug}") |> json_response(409)
      assert_schema(body, "ConflictResponse", ApiSpec.spec())
      assert {:ok, _} = GoodFlows.Spry.get_recipe(ctx.account, ctx.project, recipe.id)
    end

    test "project-scoped recipe routes without a Bearer token are 401", %{conn: conn} = ctx do
      for path <- [
            "/api/v1/projects/GoodCases/recipes",
            "/api/v1/projects/missing/recipes",
            recipes_path(ctx.project)
          ] do
        assert conn |> get(path) |> json_response(401)
        assert conn |> post(path, %{"name" => "demo"}) |> json_response(401)
      end

      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Recipe, :count) == 0
    end

    test "a 64-byte project slug lists recipes; 65 bytes is 422", ctx do
      slug = String.duplicate("a", 64)
      project = project_fixture(ctx.account, %{"slug" => slug})
      recipe = recipe_fixture(project)

      assert [%{"id" => id, "project" => ^slug}] =
               ctx.pk_conn
               |> get(recipes_path(project))
               |> json_response(200)
               |> Map.fetch!("data")

      assert id == recipe.id

      assert ctx.pk_conn
             |> get("/api/v1/projects/#{slug}a/recipes")
             |> json_response(422)
             |> get_in(["errors", "project"])
    end

    test "the unscoped recipe routes are gone", ctx do
      assert ctx.pk_conn |> get("/api/v1/recipes") |> response(404)
      assert ctx.sk_conn |> post("/api/v1/recipes", %{"name" => "demo"}) |> response(404)
      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Recipe, :count) == 0
    end
  end

  test "operations appear in the OpenAPI document", %{conn: conn} do
    paths = conn |> get(~p"/api/v1/openapi") |> json_response(200) |> Map.fetch!("paths")

    assert Map.keys(paths["/api/v1/projects"]) |> Enum.sort() == ["get", "post"]
    assert Map.keys(paths["/api/v1/projects/{project}"]) |> Enum.sort() == ["delete", "get"]
    assert Map.keys(paths["/api/v1/projects/{project}/recipes"]) |> Enum.sort() == ["get", "post"]

    assert Map.keys(paths["/api/v1/projects/{project}/recipes/{id}"]) |> Enum.sort() ==
             ["delete", "get", "put"]

    assert Map.keys(paths["/api/v1/projects/{project}/recipes/{id}/runs"]) |> Enum.sort() ==
             ["get", "post"]

    refute paths["/api/v1/recipes"]
    refute paths["/api/v1/recipes/{id}"]
    refute paths["/api/v1/recipes/{id}/runs"]
  end
end
