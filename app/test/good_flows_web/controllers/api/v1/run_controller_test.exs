defmodule GoodFlowsWeb.Api.V1.RunControllerTest do
  use GoodFlowsWeb.ConnCase, async: false
  use Mimic

  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Spry.Executions
  alias GoodFlows.Spry.Sprites, as: Wrapper
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup %{account: account} do
    compile_jobs!()
    credential_fixture(account)

    recipe =
      recipe_fixture(account, %{
        "name" => "app-{{branch_slug}}",
        "setup" => ["echo hi"],
        "teardown" => ["echo bye"]
      })

    reject(&Wrapper.create/3)
    reject(&Wrapper.exec/4)
    reject(&Wrapper.destroy/3)
    %{recipe: recipe}
  end

  describe "POST /recipes/:id/runs" do
    test "accepts a setup run", ctx do
      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
          "phase" => "setup",
          "branch" => "feat/x"
        })
        |> json_response(202)

      assert_schema(body, "RunResponse", ApiSpec.spec())

      assert %{"status" => "queued", "phase" => "setup", "sprite_name" => "app-feat-x"} =
               body["data"]
    end

    test "the sprite override wins", ctx do
      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
          "phase" => "start",
          "sprite" => "demo"
        })
        |> json_response(202)

      assert body["data"]["sprite_name"] == "demo"
    end

    test "invalid phase, misplaced flags, and missing inputs are 422", ctx do
      path = ~p"/api/v1/recipes/#{ctx.recipe.id}/runs"

      assert ctx.sk_conn
             |> post(path, %{"phase" => "deploy"})
             |> json_response(422)
             |> get_in(["errors", "phase"])

      assert ctx.sk_conn
             |> post(path, %{"phase" => "setup", "branch" => "x", "no_destroy" => true})
             |> json_response(422)
             |> get_in(["errors", "no_destroy"])

      body = ctx.sk_conn |> post(path, %{"phase" => "setup"}) |> json_response(422)
      assert_schema(body, "ValidationErrorResponse", ApiSpec.spec())
      assert [message] = body["errors"]["branch"]
      assert message =~ "branch_slug"
    end

    test "no credential is 422 and creates nothing", ctx do
      GoodFlows.Spry.delete_credential(ctx.account)

      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{"phase" => "setup", "branch" => "x"})
        |> json_response(422)

      assert body["errors"]["detail"] =~ "Sprites credential"
      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Run, :count) == 0
    end

    test "409 identifies the active run", ctx do
      active = run_fixture(ctx.account, ctx.recipe, sprite_name: "app-feat-x", status: "running")

      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
          "phase" => "teardown",
          "branch" => "feat/x"
        })
        |> json_response(409)

      assert_schema(body, "RunConflictResponse", ApiSpec.spec())
      assert body["errors"]["active_run_id"] == active.id
    end

    test "records the API key that started the run", ctx do
      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{"phase" => "setup", "branch" => "x"})
        |> json_response(202)

      run = GoodFlows.Repo.get!(GoodFlows.Spry.Run, body["data"]["id"])
      assert run.started_by_api_key_id == ctx.sk_key.id
      assert body["data"]["started_by_api_key_id"] == ctx.sk_key.id

      # Deleting the key keeps the run and clears the reference.
      GoodFlows.Repo.delete!(ctx.sk_key)
      assert GoodFlows.Repo.get!(GoodFlows.Spry.Run, run.id).started_by_api_key_id == nil
    end

    test "an enqueue failure is a 503 and creates no run", ctx do
      stub(PgFlow, :enqueue, fn _module, _input -> {:error, :queue_down} end)

      {body, log} =
        ExUnit.CaptureLog.with_log(fn ->
          ctx.sk_conn
          |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
            "phase" => "setup",
            "branch" => "x"
          })
          |> json_response(503)
        end)

      assert_schema(body, "ErrorResponse", ApiSpec.spec())
      assert body["errors"]["detail"] =~ "could not be queued"
      assert log =~ "Could not enqueue Spry run"
      assert log =~ ":queue_down"
      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Run, :count) == 0
      assert queued_job_messages() == 0
    end

    test "inputs outside their allowed characters or lengths are 422", ctx do
      path = ~p"/api/v1/recipes/#{ctx.recipe.id}/runs"

      for {field, value} <- [
            {"branch", "x; rm -rf /"},
            {"branch", "--upload-pack=evil"},
            {"commit", "abc$(id)"},
            {"remote", "https://example.com/a b"},
            {"branch", String.duplicate("a", 256)},
            {"remote", "r" <> String.duplicate("a", 1024)}
          ] do
        body =
          ctx.sk_conn
          |> post(path, %{"phase" => "setup", "branch" => "x"} |> Map.put(field, value))
          |> json_response(422)

        assert body["errors"][field], "expected an error on #{field} for #{inspect(value)}"
      end

      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Run, :count) == 0
    end

    test "invalid sprite names are 422, including names that differ only by case", ctx do
      path = ~p"/api/v1/recipes/#{ctx.recipe.id}/runs"

      # {{branch_slug}} keeps case, so an uppercase branch cannot alias a
      # lowercase sprite.
      body =
        ctx.sk_conn
        |> post(path, %{"phase" => "setup", "branch" => "Feat/X"})
        |> json_response(422)

      assert [message] = body["errors"]["sprite_name"]
      assert message =~ "app-Feat-X"
      assert message =~ "not a valid sprite name"

      for sprite <- ["Demo", "demo#1", "a..b", "-demo", String.duplicate("a", 64)] do
        body =
          ctx.sk_conn
          |> post(path, %{"phase" => "start", "sprite" => sprite})
          |> json_response(422)

        assert body["errors"]["sprite"] || body["errors"]["sprite_name"], "accepted #{sprite}"
      end

      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Run, :count) == 0
    end

    test "dry run returns the plan with 200 and creates nothing", ctx do
      stub(Wrapper, :exists?, fn _client, "app-feat-x", _opts -> {:ok, false} end)

      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
          "phase" => "setup",
          "branch" => "feat/x",
          "dry_run" => true
        })
        |> json_response(200)

      assert_schema(body, "RunPlan", ApiSpec.spec())

      assert body["data"]["steps"] == [
               %{"index" => 0, "kind" => "create", "command" => "create app-feat-x"},
               %{"index" => 1, "kind" => "exec", "command" => "echo hi"}
             ]

      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Run, :count) == 0
    end

    test "any boolean form of dry_run is a dry run, never a real run", ctx do
      stub(Wrapper, :exists?, fn _client, "app-feat-x", _opts -> {:ok, true} end)
      path = ~p"/api/v1/recipes/#{ctx.recipe.id}/runs"

      for value <- ["1", "true", true] do
        body =
          ctx.sk_conn
          |> post(path, %{"phase" => "setup", "branch" => "feat/x", "dry_run" => value})
          |> json_response(200)

        assert_schema(body, "RunPlan", ApiSpec.spec())
      end

      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Run, :count) == 0
      assert queued_job_messages() == 0
    end

    test "an invalid dry_run value is 422 and creates nothing", ctx do
      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
          "phase" => "setup",
          "branch" => "x",
          "dry_run" => "maybe"
        })
        |> json_response(422)

      assert body["errors"]["dry_run"]
      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Run, :count) == 0
    end

    test "an invalid phase is reported before a missing credential", ctx do
      GoodFlows.Spry.delete_credential(ctx.account)

      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{"phase" => "deploy"})
        |> json_response(422)

      assert body["errors"]["phase"]
      refute body["errors"]["detail"]
    end

    test "contended admission is a retryable 503, never a 409 without a run id", ctx do
      run_fixture(ctx.account, ctx.recipe, sprite_name: "app-x", status: "running")
      stub(GoodFlows.Spry, :active_run_id, fn _account, _sprite -> nil end)

      conn =
        post(ctx.sk_conn, ~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
          "phase" => "setup",
          "branch" => "x"
        })

      body = json_response(conn, 503)
      assert_schema(body, "ErrorResponse", ApiSpec.spec())
      assert body["errors"]["detail"] =~ "retry"
      assert get_resp_header(conn, "retry-after") == ["1"]
    end

    test "a dry-run lookup timeout is a 422 with a timeout message", ctx do
      stub(Wrapper, :exists?, fn _client, _name, opts ->
        assert opts[:timeout] == 15_000
        {:error, :timeout}
      end)

      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
          "phase" => "setup",
          "branch" => "feat/x",
          "dry_run" => true
        })
        |> json_response(422)

      assert body["errors"]["detail"] == "timed out checking whether sprite app-feat-x exists"
      assert GoodFlows.Repo.aggregate(GoodFlows.Spry.Run, :count) == 0
    end

    test "dry run fails where the run would", ctx do
      stub(Wrapper, :exists?, fn _client, _name, _opts -> {:ok, false} end)

      body =
        ctx.sk_conn
        |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
          "phase" => "start",
          "branch" => "x",
          "dry_run" => true
        })
        |> json_response(422)

      assert body["errors"]["detail"] =~ "does not exist"
    end

    test "public keys cannot start runs or dry runs", ctx do
      path = ~p"/api/v1/recipes/#{ctx.recipe.id}/runs"

      assert ctx.pk_conn
             |> post(path, %{"phase" => "setup", "branch" => "x"})
             |> json_response(403)

      assert ctx.pk_conn
             |> post(path, %{"phase" => "setup", "dry_run" => true})
             |> json_response(403)
    end

    test "other accounts' recipes are 404", ctx do
      credential_fixture(ctx.other_account)

      assert ctx.other_conn
             |> post(~p"/api/v1/recipes/#{ctx.recipe.id}/runs", %{
               "phase" => "setup",
               "branch" => "x"
             })
             |> json_response(404)
    end
  end

  describe "GET /recipes/:id/runs" do
    test "lists newest first without steps, with a public key", ctx do
      runs =
        for {name, offset} <- [{"a", -30}, {"b", -20}, {"c", -10}] do
          run_fixture(ctx.account, ctx.recipe,
            sprite_name: name,
            status: "succeeded",
            inserted_at: DateTime.add(DateTime.utc_now(), offset, :second)
          )
        end

      body = ctx.pk_conn |> get(~p"/api/v1/recipes/#{ctx.recipe.id}/runs") |> json_response(200)
      assert_schema(body, "RunListResponse", ApiSpec.spec())
      assert Enum.map(body["data"], & &1["id"]) == runs |> Enum.reverse() |> Enum.map(& &1.id)
      refute Enum.any?(body["data"], &Map.has_key?(&1, "steps"))
      assert body["next_cursor"] == nil
    end

    test "pages with limit and cursor, newest first", ctx do
      now = DateTime.utc_now()

      ids =
        for i <- 1..5 do
          run_fixture(ctx.account, ctx.recipe,
            sprite_name: "p#{i}",
            status: "succeeded",
            inserted_at: DateTime.add(now, i, :second)
          ).id
        end
        |> Enum.reverse()

      path = ~p"/api/v1/recipes/#{ctx.recipe.id}/runs"
      page1 = ctx.pk_conn |> get(path, %{"limit" => "2"}) |> json_response(200)
      assert_schema(page1, "RunListResponse", ApiSpec.spec())
      assert Enum.map(page1["data"], & &1["id"]) == Enum.slice(ids, 0, 2)
      assert is_binary(page1["next_cursor"])

      # A run started meanwhile does not shift later pages.
      run_fixture(ctx.account, ctx.recipe,
        sprite_name: "newer",
        status: "queued",
        inserted_at: DateTime.add(now, 60, :second)
      )

      page2 =
        ctx.pk_conn
        |> get(path, %{"limit" => "2", "cursor" => page1["next_cursor"]})
        |> json_response(200)

      assert Enum.map(page2["data"], & &1["id"]) == Enum.slice(ids, 2, 2)

      page3 =
        ctx.pk_conn
        |> get(path, %{"limit" => "2", "cursor" => page2["next_cursor"]})
        |> json_response(200)

      assert Enum.map(page3["data"], & &1["id"]) == Enum.slice(ids, 4, 1)
      assert page3["next_cursor"] == nil
    end

    test "defaults to 50 per page", ctx do
      for i <- 1..51,
          do: run_fixture(ctx.account, ctx.recipe, sprite_name: "d#{i}", status: "failed")

      body = ctx.pk_conn |> get(~p"/api/v1/recipes/#{ctx.recipe.id}/runs") |> json_response(200)
      assert length(body["data"]) == 50
      assert body["next_cursor"]
    end

    test "an invalid limit or cursor is 422", ctx do
      path = ~p"/api/v1/recipes/#{ctx.recipe.id}/runs"

      for params <- [
            %{"limit" => "0"},
            %{"limit" => "201"},
            %{"limit" => "x"},
            %{"cursor" => "nope"}
          ] do
        body = ctx.pk_conn |> get(path, params) |> json_response(422)
        assert_schema(body, "ValidationErrorResponse", ApiSpec.spec())
      end
    end

    test "other accounts get 404", ctx do
      assert ctx.other_conn
             |> get(~p"/api/v1/recipes/#{ctx.recipe.id}/runs")
             |> json_response(404)
    end
  end

  describe "GET /runs/:id" do
    test "returns the run with steps in order", ctx do
      run = run_fixture(ctx.account, ctx.recipe, status: "succeeded")

      run_step_fixture(run,
        index: 1,
        kind: "exec",
        command: "echo hi",
        status: "succeeded",
        exit_code: 0,
        output: "hi\n"
      )

      run_step_fixture(run, index: 0, kind: "create", command: "create x", status: "succeeded")

      body = ctx.sk_conn |> get(~p"/api/v1/runs/#{run.id}") |> json_response(200)
      assert_schema(body, "RunResponse", ApiSpec.spec())

      assert [
               %{"kind" => "create", "command" => "create x"},
               %{"kind" => "exec", "exit_code" => 0, "command" => "echo hi", "output" => "hi\n"}
             ] = body["data"]["steps"]
    end

    test "public keys see steps without command or output", ctx do
      run = run_fixture(ctx.account, ctx.recipe, status: "failed")

      run_step_fixture(run,
        index: 0,
        kind: "exec",
        command: "echo $SECRET",
        status: "failed",
        exit_code: 1,
        output: "hunter2\n"
      )

      conn = get(ctx.pk_conn, ~p"/api/v1/runs/#{run.id}")
      body = json_response(conn, 200)
      assert_schema(body, "RunResponse", ApiSpec.spec())

      assert [%{"kind" => "exec", "status" => "failed", "exit_code" => 1} = step] =
               body["data"]["steps"]

      refute Map.has_key?(step, "command")
      refute Map.has_key?(step, "output")
      refute conn.resp_body =~ "hunter2"
      refute conn.resp_body =~ "SECRET"
    end

    test "worker bookkeeping and the plan snapshot are never rendered", ctx do
      run =
        run_fixture(ctx.account, ctx.recipe,
          status: "running",
          owner_id: Executions.new_owner_id(),
          pgflow_run_id: Ecto.UUID.generate(),
          started_at: DateTime.utc_now(),
          action_started_at: DateTime.utc_now(),
          reaper_checked_at: DateTime.utc_now()
        )

      show = ctx.sk_conn |> get(~p"/api/v1/runs/#{run.id}") |> json_response(200)
      index = ctx.sk_conn |> get(~p"/api/v1/recipes/#{ctx.recipe.id}/runs") |> json_response(200)

      for data <- [show["data"] | index["data"]],
          key <- ~w(owner_id pgflow_run_id plan action_started_at reaper_checked_at account_id) do
        refute Map.has_key?(data, key), "rendered #{key}"
      end

      refute Jason.encode!(show) =~ run.owner_id
    end

    test "other accounts and unknown ids get 404", ctx do
      run = run_fixture(ctx.account, ctx.recipe)
      assert ctx.other_conn |> get(~p"/api/v1/runs/#{run.id}") |> json_response(404)
      assert ctx.sk_conn |> get(~p"/api/v1/runs/#{Ecto.UUID.generate()}") |> json_response(404)
    end
  end

  test "the OpenAPI document resolves and documents both run responses", %{conn: conn} do
    spec = OpenApiSpex.resolve_schema_modules(ApiSpec.spec())
    assert %OpenApiSpex.OpenApi{} = spec

    doc = conn |> get(~p"/api/v1/openapi") |> json_response(200)
    responses = doc["paths"]["/api/v1/recipes/{id}/runs"]["post"]["responses"]
    assert Map.has_key?(responses, "200")
    assert Map.has_key?(responses, "202")
    assert Map.has_key?(responses, "409")

    assert responses["409"]["content"]["application/json"]["schema"]["$ref"] =~
             "RunConflictResponse"

    params = doc["paths"]["/api/v1/recipes/{id}/runs"]["get"]["parameters"]
    assert Enum.any?(params, &(&1["name"] == "limit" and &1["in"] == "query"))
    assert Enum.any?(params, &(&1["name"] == "cursor" and &1["in"] == "query"))
    assert doc["paths"]["/api/v1/runs/{id}"]["get"]

    for name <-
          ~w(Recipe RecipeRequest RunRequest Run RunStep RunPlan ConflictResponse RunConflictResponse SpritesCredentialStatus) do
      assert doc["components"]["schemas"][name], "missing schema #{name}"
    end

    refute get_in(doc, [
             "components",
             "schemas",
             "SpritesCredentialStatus",
             "properties",
             "data",
             "properties",
             "token"
           ])
  end
end
