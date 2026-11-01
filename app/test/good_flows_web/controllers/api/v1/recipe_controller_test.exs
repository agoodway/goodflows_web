defmodule GoodFlowsWeb.Api.V1.RecipeControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  @full %{
    "name" => "myapp-{{branch_slug}}",
    "setup" => ["git clone {{remote}} app", "cd app && make"],
    "start" => ["cd app && bin/start"],
    "stop" => ["cd app && bin/stop"],
    "teardown" => ["echo bye"]
  }

  describe "create" do
    test "stores all four lists in order", %{sk_conn: conn} do
      body = conn |> post(~p"/api/v1/recipes", @full) |> json_response(201)
      assert_schema(body, "RecipeResponse", ApiSpec.spec())

      data = body["data"]
      assert data["name"] == "myapp-{{branch_slug}}"
      assert data["setup"] == @full["setup"]
      assert data["teardown"] == ["echo bye"]
    end

    test "a name-only recipe gets empty lists", %{sk_conn: conn} do
      data = conn |> post(~p"/api/v1/recipes", %{"name" => "demo"}) |> json_response(201)
      assert %{"setup" => [], "start" => [], "stop" => [], "teardown" => []} = data["data"]
    end

    test "missing name is 422", %{sk_conn: conn} do
      body = conn |> post(~p"/api/v1/recipes", %{"setup" => ["x"]}) |> json_response(422)
      assert_schema(body, "ValidationErrorResponse", ApiSpec.spec())
      assert body["errors"]["name"]
    end

    test "a host step is 422 with the phase and index", %{sk_conn: conn} do
      body =
        conn
        |> post(~p"/api/v1/recipes", %{
          "name" => "x",
          "setup" => ["echo", %{"host" => "gh repo deploy-key add ..."}]
        })
        |> json_response(422)

      assert body["errors"]["setup[1]"] == ["host steps are not supported by the API"]
    end

    test "org is 422", %{sk_conn: conn} do
      body =
        conn |> post(~p"/api/v1/recipes", %{"name" => "x", "org" => "acme"}) |> json_response(422)

      assert body["errors"]["org"]
    end

    test "unknown placeholders are 422 naming the placeholder", %{sk_conn: conn} do
      body =
        conn
        |> post(~p"/api/v1/recipes", %{"name" => "x", "start" => ["echo {{foo}}"]})
        |> json_response(422)

      assert [message] = body["errors"]["start[0]"]
      assert message =~ "{{foo}}"
      assert message =~ "start"

      body =
        conn |> post(~p"/api/v1/recipes", %{"name" => "app-{{sprite}}"}) |> json_response(422)

      assert body["errors"]["name"]
    end

    test "duplicate names in one account are 422, other accounts may reuse", ctx do
      ctx.sk_conn |> post(~p"/api/v1/recipes", %{"name" => "demo"}) |> json_response(201)
      body = ctx.sk_conn |> post(~p"/api/v1/recipes", %{"name" => "demo"}) |> json_response(422)
      assert body["errors"]["name"]

      ctx.other_conn |> post(~p"/api/v1/recipes", %{"name" => "demo"}) |> json_response(201)
    end

    test "public keys cannot create", %{pk_conn: conn} do
      assert conn |> post(~p"/api/v1/recipes", %{"name" => "x"}) |> json_response(403)
    end
  end

  describe "read" do
    test "lists only the account's recipes, also with a public key", ctx do
      mine = recipe_fixture(ctx.account)
      _theirs = recipe_fixture(ctx.other_account)

      body = ctx.pk_conn |> get(~p"/api/v1/recipes") |> json_response(200)
      assert_schema(body, "RecipeListResponse", ApiSpec.spec())
      assert [%{"id" => id}] = body["data"]
      assert id == mine.id
    end

    test "shows a recipe and hides other accounts' recipes", ctx do
      recipe = recipe_fixture(ctx.account)

      assert %{"data" => %{"id" => _}} =
               ctx.pk_conn |> get(~p"/api/v1/recipes/#{recipe.id}") |> json_response(200)

      assert ctx.other_conn |> get(~p"/api/v1/recipes/#{recipe.id}") |> json_response(404)
      assert ctx.sk_conn |> get(~p"/api/v1/recipes/nope") |> json_response(404)
    end
  end

  describe "update" do
    test "replaces the recipe; an omitted list becomes empty", ctx do
      recipe = recipe_fixture(ctx.account)

      data =
        ctx.sk_conn
        |> put(~p"/api/v1/recipes/#{recipe.id}", %{"name" => recipe.name, "setup" => ["new"]})
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["setup"] == ["new"]
      assert data["stop"] == []
    end

    test "a replacement without name is 422 and keeps the recipe", ctx do
      recipe = recipe_fixture(ctx.account)

      body =
        ctx.sk_conn
        |> put(~p"/api/v1/recipes/#{recipe.id}", %{"setup" => ["new"]})
        |> json_response(422)

      assert body["errors"]["name"] == ["can't be blank"]
      assert {:ok, ^recipe} = GoodFlows.Spry.get_recipe(ctx.account, recipe.id)
    end

    test "a host step on update is 422 and leaves the recipe unchanged", ctx do
      recipe = recipe_fixture(ctx.account)

      ctx.sk_conn
      |> put(~p"/api/v1/recipes/#{recipe.id}", %{
        "name" => recipe.name,
        "teardown" => [%{"host" => "x"}]
      })
      |> json_response(422)

      assert {:ok, ^recipe} = GoodFlows.Spry.get_recipe(ctx.account, recipe.id)
    end

    test "public keys cannot update; other accounts get 404", ctx do
      recipe = recipe_fixture(ctx.account)

      assert ctx.pk_conn
             |> put(~p"/api/v1/recipes/#{recipe.id}", %{"name" => "x"})
             |> json_response(403)

      assert ctx.other_conn
             |> put(~p"/api/v1/recipes/#{recipe.id}", %{"name" => "x"})
             |> json_response(404)
    end
  end

  describe "delete" do
    test "deletes, then 404", ctx do
      recipe = recipe_fixture(ctx.account)
      assert ctx.sk_conn |> delete(~p"/api/v1/recipes/#{recipe.id}") |> response(204)
      assert ctx.sk_conn |> get(~p"/api/v1/recipes/#{recipe.id}") |> json_response(404)
    end

    test "409 while a run is active", ctx do
      recipe = recipe_fixture(ctx.account)
      run_fixture(ctx.account, recipe, status: "running")

      body = ctx.sk_conn |> delete(~p"/api/v1/recipes/#{recipe.id}") |> json_response(409)
      assert_schema(body, "ConflictResponse", ApiSpec.spec())
      assert ctx.sk_conn |> get(~p"/api/v1/recipes/#{recipe.id}") |> json_response(200)
    end

    test "completed runs stay retrievable after the recipe is deleted", ctx do
      recipe = recipe_fixture(ctx.account)
      run = run_fixture(ctx.account, recipe, status: "succeeded")

      run_step_fixture(run,
        index: 0,
        kind: "exec",
        command: "echo setup",
        status: "succeeded",
        exit_code: 0,
        output: "setup\n"
      )

      assert ctx.sk_conn |> delete(~p"/api/v1/recipes/#{recipe.id}") |> response(204)

      data =
        ctx.sk_conn |> get(~p"/api/v1/runs/#{run.id}") |> json_response(200) |> Map.fetch!("data")

      assert data["recipe_id"] == nil
      assert [%{"output" => "setup\n"}] = data["steps"]
    end

    test "public keys cannot delete; other accounts get 404", ctx do
      recipe = recipe_fixture(ctx.account)
      assert ctx.pk_conn |> delete(~p"/api/v1/recipes/#{recipe.id}") |> json_response(403)
      assert ctx.other_conn |> delete(~p"/api/v1/recipes/#{recipe.id}") |> json_response(404)
    end
  end

  test "operations appear in the OpenAPI document", %{conn: conn} do
    paths = conn |> get(~p"/api/v1/openapi") |> json_response(200) |> Map.fetch!("paths")

    assert Map.keys(paths["/api/v1/recipes"]) |> Enum.sort() == ["get", "post"]
    assert Map.keys(paths["/api/v1/recipes/{id}"]) |> Enum.sort() == ["delete", "get", "put"]
  end
end
