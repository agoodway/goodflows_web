defmodule GoodFlowsWeb.Api.V1.WorkflowRunContractTest do
  @moduledoc """
  Uploads the fixtures vendored from goodflows
  (`test/support/fixtures/goodflows_workflow_runs/README.md`) byte for byte,
  as the CLI sends them.
  """
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.SpryFixtures, only: [project_fixture: 1]
  import GoodFlows.WorkflowRunFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Repo
  alias GoodFlows.WorkflowRuns.Run
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  defp upload(conn, slug, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/projects/#{slug}/workflow-runs", body)
  end

  test "every goodflows fixture uploads, and an exact retry is 200", ctx do
    # `full`/`history-parent-default` and `child`/`history-child-suite`
    # share run ids, so each fixture gets its own project.
    for name <- goodflows_names() do
      project = project_fixture(ctx.account)
      body = goodflows_json(name)
      assert_schema(goodflows(name), "WorkflowRunRequest", ApiSpec.spec())

      created = ctx.sk_conn |> upload(project.slug, body) |> json_response(201)
      assert created["data"]["duplicate"] == false, name

      retried = ctx.sk_conn |> upload(project.slug, body) |> json_response(200)
      assert retried["data"] == %{created["data"] | "duplicate" => true}, name
    end

    assert Repo.aggregate(Run, :count) == length(goodflows_names())
  end

  test "full.json round-trips graph, ci and source.branch", ctx do
    project = project_fixture(ctx.account)
    fixture = goodflows("full")
    ctx.sk_conn |> upload(project.slug, goodflows_json("full")) |> json_response(201)

    shown =
      ctx.sk_conn
      |> get("/api/v1/projects/#{project.slug}/workflow-runs/#{fixture["run_id"]}")
      |> json_response(200)

    assert_schema(shown, "WorkflowRunResponse", ApiSpec.spec())
    document = shown["data"]["document"]
    assert document == fixture
    assert document["graph"] == fixture["graph"]
    assert document["ci"] == fixture["ci"]
    assert document["source"]["branch"] == "feature/login"

    call = document["graph"]["jobs"] |> Enum.at(2) |> Map.fetch!("call")
    assert call == %{"workflow" => "suite", "graph_sha256" => goodflows("child")["graph_sha256"]}

    [summary] =
      ctx.sk_conn
      |> get("/api/v1/projects/#{project.slug}/workflow-runs")
      |> json_response(200)
      |> Map.fetch!("data")

    assert summary["source"] == fixture["source"]
    assert summary["ci"] == fixture["ci"]
    refute Map.has_key?(summary, "graph")
  end

  # goodflows `add-run-links` adds `links.json`, which is not vendored yet
  # (design D6 of `accept-run-links`), so `links` is added to `full.json`
  # in memory. The vendored files are unchanged.
  test "full.json with links uploads, retries, round-trips and is found by link", ctx do
    project = project_fixture(ctx.account)
    thread = "https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"

    links = %{
      "threads" => [
        thread,
        "https://ampcode.com/threads/a%7Eb",
        "https://ampcode.com/threads/a%2fb"
      ],
      "tickets" => ["GOO-291", "goo-300"]
    }

    fixture = Map.put(goodflows("full"), "links", links)
    assert_schema(fixture, "WorkflowRunRequest", ApiSpec.spec())
    body = Jason.encode!(fixture)

    created = ctx.sk_conn |> upload(project.slug, body) |> json_response(201)
    assert created["data"]["duplicate"] == false
    retried = ctx.sk_conn |> upload(project.slug, body) |> json_response(200)
    assert retried["data"] == %{created["data"] | "duplicate" => true}

    shown =
      ctx.sk_conn
      |> get("/api/v1/projects/#{project.slug}/workflow-runs/#{fixture["run_id"]}")
      |> json_response(200)

    assert_schema(shown, "WorkflowRunResponse", ApiSpec.spec())
    assert shown["data"]["document"] == fixture
    assert shown["data"]["document"]["links"] == links

    respelled = "HTTPS://AmpCode.com:443/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"

    for query <- [
          "ticket=goo-291",
          "ticket=GOO-300",
          "thread_url=" <> URI.encode_www_form(thread),
          "thread_url=" <> URI.encode_www_form(respelled),
          "thread_url=" <> URI.encode_www_form("https://ampcode.com/threads/a%7Eb"),
          "thread_url=" <> URI.encode_www_form("https://ampcode.com/threads/a%2fb")
        ] do
      data =
        ctx.sk_conn
        |> get("/api/v1/projects/#{project.slug}/workflow-runs?#{query}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(data, & &1["run_id"]) == [fixture["run_id"]], query
    end
  end

  test "invalid envelope values are 422 on their path and store nothing", ctx do
    project = project_fixture(ctx.account)
    full = goodflows("full")
    jobs = ["graph", "jobs"]

    for {change, path} <- [
          {&put_in(&1, ["source", "branch"], nil), "source.branch"},
          {&put_in(&1, ["source", "branch"], "a\nb"), "source.branch"},
          {&put_in(&1, ["ci", "provider"], "gitlab"), "ci.provider"},
          {&put_in(&1, ["ci", "url"], "http://github.com/a/b/actions/runs/1"), "ci.url"},
          {&put_in(&1, ["graph"], nil), "graph"},
          {&put_in(&1, jobs, []), "graph.jobs"},
          {&put_in(&1, jobs ++ [Access.at(2), "name"], "build"), "graph.jobs[2].name"},
          {&put_in(&1, jobs ++ [Access.at(1), "depends_on"], ["deploy"]),
           "graph.jobs[1].depends_on[0]"},
          {&put_in(&1, jobs ++ [Access.at(0), "depends_on"], ["test"]),
           "graph.jobs[1].depends_on"},
          {&put_in(&1, ["results", Access.at(0), "name"], "deploy"), "results[0].name"},
          {&put_in(&1, jobs ++ [Access.at(2), "call", "jobs"], []), "graph.jobs[2].call"}
        ] do
      body = full |> change.() |> Jason.encode!()

      errors =
        ctx.sk_conn |> upload(project.slug, body) |> json_response(422) |> Map.get("errors")

      assert Map.has_key?(errors, path), "expected #{path}, got #{inspect(errors)}"
    end

    # An inlined called workflow nests past depth 8 and is rejected before decode.
    inlined =
      put_in(full, jobs ++ [Access.at(2), "call", "graph"], %{"jobs" => full["graph"]["jobs"]})

    assert ctx.sk_conn |> upload(project.slug, Jason.encode!(inlined)) |> json_response(422) ==
             %{"errors" => %{"body" => ["is nested too deeply"]}}

    assert Repo.aggregate(Run, :count) == 0
  end
end
