defmodule GoodFlowsWeb.Api.V1.ProjectControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import Ecto.Query
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Projects
  alias GoodFlows.Repo
  alias GoodFlows.WorkflowRuns.Run
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

    test "a project whose only content is a workflow run is 409 and both remain", ctx do
      project = project_fixture(ctx.account)
      id = stored_run(ctx.account, project)

      body = ctx.sk_conn |> delete(~p"/api/v1/projects/#{project.slug}") |> json_response(409)
      assert_schema(body, "ConflictResponse", ApiSpec.spec())

      assert body["errors"]["detail"] ==
               "The project has stored workflow runs and cannot be deleted"

      refute inspect(body) =~ id
      assert ctx.sk_conn |> get(~p"/api/v1/projects/#{project.slug}") |> json_response(200)
      assert Repo.get(Run, id)
    end

    test "a project whose only content is a closed change request is 409", ctx do
      project = project_fixture(ctx.account)
      _ = create_cr(ctx.sk_conn, project.slug)
      _ = ctx.sk_conn |> post(cr_path(project.slug, 1, "/close")) |> json_response(200)

      body = ctx.sk_conn |> delete(~p"/api/v1/projects/#{project.slug}") |> json_response(409)
      assert_schema(body, "ConflictResponse", ApiSpec.spec())
      assert body["errors"]["detail"] == "The project has change requests and cannot be deleted"
      assert ctx.sk_conn |> get(cr_path(project.slug, 1)) |> json_response(200)
    end

    test "a project whose only content is review policy versions is deleted with them", ctx do
      project = project_fixture(ctx.account)

      for previous <- [0, 1] do
        body = %{
          "previous_version" => previous,
          "policy" => %{"format" => "review-policy/1"},
          "note" => "v#{previous}"
        }

        assert ctx.sk_conn
               |> put_json("/api/v1/projects/#{project.slug}/review-policy", body)
               |> json_response(201)
      end

      assert ctx.sk_conn |> delete(~p"/api/v1/projects/#{project.slug}") |> response(204)
      assert ctx.sk_conn |> get(~p"/api/v1/projects/#{project.slug}") |> json_response(404)

      assert Repo.aggregate(
               from(v in GoodFlows.ReviewPolicies.Version, where: v.project_id == ^project.id),
               :count
             ) == 0
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

  describe "default branch" do
    test "create defaults default_branch to main and accepts another", ctx do
      body =
        ctx.sk_conn |> post(~p"/api/v1/projects", %{"slug" => "goodcases"}) |> json_response(201)

      assert body["data"]["default_branch"] == "main"

      body =
        ctx.sk_conn
        |> post(~p"/api/v1/projects", %{"slug" => "other", "default_branch" => "trunk"})
        |> json_response(201)

      assert_schema(body, "ProjectResponse", ApiSpec.spec())
      assert body["data"]["default_branch"] == "trunk"
    end

    test "a default branch that is not a Git ref is accepted", ctx do
      body =
        ctx.sk_conn
        |> post(~p"/api/v1/projects", %{"slug" => "odd", "default_branch" => "pr 42..head"})
        |> json_response(201)

      assert body["data"]["default_branch"] == "pr 42..head"
    end

    test "an invalid default branch is 422 on default_branch and stores nothing", ctx do
      for branch <- ["", "main\n", String.duplicate("a", 257), 42] do
        body =
          ctx.sk_conn
          |> post(~p"/api/v1/projects", %{"slug" => "goodcases", "default_branch" => branch})
          |> json_response(422)

        assert body["errors"]["default_branch"], "expected #{inspect(branch)} to be rejected"
      end

      assert Projects.list_projects(ctx.account) == []
    end

    test "show and list render default_branch", ctx do
      project = project_fixture(ctx.account)

      body = ctx.pk_conn |> get(~p"/api/v1/projects/#{project.slug}") |> json_response(200)
      assert body["data"]["default_branch"] == "main"

      body = ctx.pk_conn |> get(~p"/api/v1/projects") |> json_response(200)
      assert [%{"default_branch" => "main"}] = body["data"]
    end

    test "PATCH changes default_branch", ctx do
      project = project_fixture(ctx.account)

      body =
        ctx.sk_conn
        |> patch(~p"/api/v1/projects/#{project.slug}", %{"default_branch" => "trunk"})
        |> json_response(200)

      assert_schema(body, "ProjectResponse", ApiSpec.spec())
      assert body["data"]["default_branch"] == "trunk"
      assert {:ok, %{default_branch: "trunk"}} = Projects.get_project(ctx.account, project.slug)
    end

    test "PATCH refuses a rename and any other key", ctx do
      project = project_fixture(ctx.account)

      for body <- [
            %{"slug" => "renamed"},
            %{"default_branch" => "trunk", "slug" => "renamed"},
            %{"default_branch" => "trunk", "other" => 1}
          ] do
        resp =
          ctx.sk_conn |> patch(~p"/api/v1/projects/#{project.slug}", body) |> json_response(422)

        assert_schema(resp, "ValidationErrorResponse", ApiSpec.spec())
      end

      assert {:ok, %{slug: slug, default_branch: "main"}} =
               Projects.get_project(ctx.account, project.slug)

      assert slug == project.slug
    end

    test "PATCH with an invalid default branch is 422", ctx do
      project = project_fixture(ctx.account)

      for branch <- ["", "x\ny", String.duplicate("b", 257), nil] do
        body =
          ctx.sk_conn
          |> patch(~p"/api/v1/projects/#{project.slug}", %{"default_branch" => branch})
          |> json_response(422)

        assert body["errors"]["default_branch"]
      end
    end

    test "public keys cannot update", ctx do
      project = project_fixture(ctx.account)

      assert ctx.pk_conn
             |> patch(~p"/api/v1/projects/#{project.slug}", %{"default_branch" => "trunk"})
             |> json_response(403)

      assert {:ok, %{default_branch: "main"}} = Projects.get_project(ctx.account, project.slug)
    end

    test "PATCH on an invalid path slug is 422; another account's project is 404", ctx do
      for slug <- ["GoodCases", "-app"] do
        assert ctx.sk_conn
               |> patch("/api/v1/projects/#{slug}", %{"default_branch" => "trunk"})
               |> json_response(422)
      end

      other = project_fixture(ctx.other_account)

      assert ctx.sk_conn
             |> patch(~p"/api/v1/projects/#{other.slug}", %{"default_branch" => "trunk"})
             |> json_response(404)
    end

    test "PUT is still not a route", ctx do
      project = project_fixture(ctx.account)

      assert ctx.sk_conn
             |> put(~p"/api/v1/projects/#{project.slug}", %{"slug" => "renamed"})
             |> response(404)
    end
  end

  test "a project whose only content is caches and a cache key is deleted", ctx do
    import GoodFlows.CacheFixtures

    project = project_fixture(ctx.account)
    entry = entry_fixture(project)
    {_key, token} = cache_key_fixture(ctx.account, project, %{"access" => "read"})

    assert ctx.sk_conn |> delete(~p"/api/v1/projects/#{project.slug}") |> response(204)
    assert ctx.sk_conn |> get(~p"/api/v1/projects/#{project.slug}") |> json_response(404)
    refute Repo.get(GoodFlows.Caches.Entry, entry.id)

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM cache_object_deletions WHERE object_key = $1",
               [entry.object_key]
             )

    assert token
           |> api_conn()
           |> get("/api/v1/projects/#{project.slug}/caches/entries/#{entry.key}")
           |> json_response(401)
  end

  test "operations appear in the OpenAPI document", %{conn: conn} do
    doc = conn |> get(~p"/api/v1/openapi") |> json_response(200)

    delete = doc["paths"]["/api/v1/projects/{project}"]["delete"]

    assert delete["responses"]["409"]["content"]["application/json"]["schema"]["$ref"] =~
             "ConflictResponse"

    assert doc["paths"]["/api/v1/projects/{project}"]["patch"]["requestBody"]["content"][
             "application/json"
           ]["schema"]["$ref"] =~ "ProjectUpdateRequest"

    for name <-
          ~w(Project ProjectRequest ProjectResponse ProjectListResponse ProjectUpdateRequest) do
      assert doc["components"]["schemas"][name], "missing schema #{name}"
    end
  end
end
