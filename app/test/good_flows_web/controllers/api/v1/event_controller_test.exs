defmodule GoodFlowsWeb.Api.V1.EventControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import Ecto.Query
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.ProjectEvents
  alias GoodFlows.ProjectEvents.Event
  alias GoodFlows.Projects
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  defp path(ctx), do: "/api/v1/projects/#{ctx.project.slug}/events"

  defp types(conn, ctx),
    do: conn |> events(ctx.project.slug) |> Map.fetch!("data") |> Enum.map(& &1["type"])

  defp of_type(conn, ctx, type),
    do:
      conn |> events(ctx.project.slug) |> Map.fetch!("data") |> Enum.filter(&(&1["type"] == type))

  defp record!(ctx, n) do
    for i <- 1..n do
      ProjectEvents.record(
        ctx.project.id,
        nil,
        "policy_version_created",
        %{"version" => i, "note" => nil},
        nil
      )
    end
  end

  describe "access and parameters" do
    test "sk_ and pk_ read, ck_ is 403, no key 401, other account 404, bad Accept 406", ctx do
      record!(ctx, 3)
      body = events(ctx.sk_conn, ctx.project.slug)
      assert_schema(body, "ProjectEventListResponse", ApiSpec.spec())
      assert length(body["data"]) == 3
      assert Enum.map(body["data"], & &1["data"]["version"]) == [1, 2, 3]
      assert length(events(ctx.pk_conn, ctx.project.slug)["data"]) == 3

      owner = Repo.preload(ctx.sk_key, :account_user).account_user
      {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read_write"})
      assert api_conn(ck) |> get(path(ctx)) |> json_response(403)
      assert build_conn() |> get(path(ctx)) |> json_response(401)
      assert ctx.other_conn |> get(path(ctx)) |> json_response(404)
      assert ctx.sk_conn |> get("/api/v1/projects/Bad%20Slug/events") |> json_response(422)

      {406, _headers, _body} =
        assert_error_sent(406, fn ->
          ctx.sk_conn |> put_req_header("accept", "text/plain") |> get(path(ctx))
        end)
    end

    test "invalid after, limit and wait are 422 on the parameter", ctx do
      for {key, value} <- [
            {"after", "abc"},
            {"after", "-1"},
            {"limit", "0"},
            {"limit", "201"},
            {"wait", "31"},
            {"wait", "-1"}
          ] do
        assert %{"errors" => errors} =
                 ctx.sk_conn |> get(path(ctx), %{key => value}) |> json_response(422)

        assert Map.keys(errors) == [key]
      end
    end

    test "paging with next_cursor and an empty page", ctx do
      record!(ctx, 5)
      first = events(ctx.sk_conn, ctx.project.slug, %{"limit" => "3"})
      assert length(first["data"]) == 3
      assert first["next_cursor"] == List.last(first["data"])["id"]

      second = events(ctx.sk_conn, ctx.project.slug, %{"after" => first["next_cursor"]})
      assert length(second["data"]) == 2
      last = second["next_cursor"]

      assert %{"data" => [], "next_cursor" => ^last} =
               events(ctx.sk_conn, ctx.project.slug, %{"after" => last, "wait" => "0"})

      assert %{"data" => [], "next_cursor" => nil} =
               events(ctx.sk_conn, project_fixture(ctx.account).slug)
    end

    test "a wait with nothing new times out with an empty page", ctx do
      started = System.monotonic_time(:millisecond)
      assert %{"data" => []} = events(ctx.sk_conn, ctx.project.slug, %{"wait" => "1"})
      assert System.monotonic_time(:millisecond) - started >= 1_000
    end

    test "a cursor before swept events is 410 with latest_cursor; resuming works", ctx do
      [old, _kept] = record!(ctx, 2)
      long_ago = DateTime.add(DateTime.utc_now(), -91, :day)
      Repo.update_all(from(e in Event, where: e.id == ^old.id), set: [inserted_at: long_ago])

      assert ProjectEvents.sweep() >= 1
      refute Repo.get(Event, old.id)
      [newest] = record!(ctx, 1)

      gone = ctx.sk_conn |> get(path(ctx), %{"after" => "0"}) |> json_response(410)
      assert_schema(gone, "EventsGoneResponse", ApiSpec.spec())
      assert gone["latest_cursor"] == newest.id

      assert %{"data" => []} =
               events(ctx.sk_conn, ctx.project.slug, %{"after" => gone["latest_cursor"]})

      # Without `after`, the feed starts at the oldest kept event.
      assert length(events(ctx.sk_conn, ctx.project.slug)["data"]) == 2
    end

    test "deleting a project with events deletes them", ctx do
      project = project_fixture(ctx.account)

      for v <- 1..2,
          do:
            ProjectEvents.record(
              project.id,
              nil,
              "policy_version_created",
              %{"version" => v},
              nil
            )

      assert :ok = Projects.delete_project(ctx.account, project)
      assert Repo.aggregate(from(e in Event, where: e.project_id == ^project.id), :count) == 0
    end
  end

  describe "emission" do
    test "state changes, merges, and nothing for a same-state request or a merge retry", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)
      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/ready")) |> json_response(200)
      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/ready")) |> json_response(200)
      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/close")) |> json_response(200)
      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/reopen")) |> json_response(200)
      merge = %{"merged_commit" => sha(7), "target_branch" => "main"}
      _ = ctx.sk_conn |> post_json(cr_path(slug, 1, "/merged"), merge) |> json_response(200)
      _ = ctx.sk_conn |> post_json(cr_path(slug, 1, "/merged"), merge) |> json_response(200)

      changes = of_type(ctx.sk_conn, ctx, "cr_state_changed")

      assert Enum.map(changes, & &1["data"]) == [
               %{"from" => "draft", "to" => "open"},
               %{"from" => "open", "to" => "closed"},
               %{"from" => "closed", "to" => "open"},
               %{"from" => "open", "to" => "merged"}
             ]

      assert Enum.all?(changes, &(&1["number"] == 1))
      assert hd(changes)["actor"]["key_id"] == ctx.sk_key.id
      assert hd(changes)["actor"]["user_id"]
    end

    test "verdict_changed only when the state, head or policy version changes", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)
      facts!(ctx.sk_conn, slug, 1, sha(1))
      claims!(ctx.sk_conn, slug, 1, sha(1), %{"cr" => 1, "door" => "one_way"})
      before = length(of_type(ctx.sk_conn, ctx, "verdict_changed"))

      # A retry of the same facts recomputes with nothing changed.
      facts!(ctx.sk_conn, slug, 1, sha(1))
      assert length(of_type(ctx.sk_conn, ctx, "verdict_changed")) == before

      [event] = ctx.sk_conn |> of_type(ctx, "verdict_changed") |> Enum.take(-1)

      assert event["data"] == %{
               "from" => "pending",
               "to" => "needs_review",
               "head" => sha(1),
               "policy_version" => 0
             }

      assert event["actor"] == nil
      assert event["number"] == 1
    end

    test "scenario set upload, approval and rejection", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug, %{"openspec_change" => "add-export"})
      body = set_body(intent_fm("add-export"))

      digest =
        ctx.sk_conn
        |> post_json(cr_path(slug, 1, "/scenario-sets"), body)
        |> json_response(201)
        |> get_in(["data", "digest"])

      _ = ctx.sk_conn |> post_json(cr_path(slug, 1, "/scenario-sets"), body) |> json_response(200)
      sets = cr_path(slug, 1, "/scenario-sets/intent")

      _ =
        ctx.sk_conn
        |> post_json(sets <> "/approvals", %{"digest" => digest})
        |> json_response(201)

      reject = %{"digest" => digest, "note" => "S2 tests the wrong path"}
      _ = ctx.sk_conn |> post_json(sets <> "/rejections", reject) |> json_response(201)
      _ = ctx.sk_conn |> post_json(sets <> "/rejections", reject) |> json_response(200)

      assert [%{"data" => %{"source" => "intent", "digest" => ^digest, "version" => 1}}] =
               of_type(ctx.sk_conn, ctx, "scenario_set_uploaded")

      assert [%{"data" => approved}] = of_type(ctx.sk_conn, ctx, "scenario_set_approved")
      assert approved == %{"source" => "intent", "digest" => digest}

      assert [%{"data" => rejected}] = of_type(ctx.sk_conn, ctx, "scenario_set_rejected")

      assert rejected == %{
               "source" => "intent",
               "digest" => digest,
               "note" => "S2 tests the wrong path"
             }

      assert [%{"data" => %{"note" => nil}, "actor" => nil}] =
               of_type(ctx.pk_conn, ctx, "scenario_set_rejected")
    end

    test "diff set acceptance and weakening rejection carry source diff", ctx do
      slug = ctx.project.slug

      policy!(ctx.sk_conn, slug, %{
        "scenarios" => %{"require_approved_intent" => true, "diff_only" => "weakening"}
      })

      _ = create_cr(ctx.sk_conn, slug)
      facts!(ctx.sk_conn, slug, 1, sha(1))
      claims!(ctx.sk_conn, slug, 1, sha(1), %{"cr" => 1})

      upload = fn scenarios ->
        digest =
          ctx.sk_conn
          |> post_json(cr_path(slug, 1, "/scenario-sets"), set_body(diff_fm(sha(1), scenarios)))
          |> json_response(201)
          |> get_in(["data", "digest"])

        doc = run_doc(digest, "diff", sha(1), Enum.map(scenarios, &result(&1["id"])))
        _ = ctx.sk_conn |> post_json("/api/v1/projects/#{slug}/verify-runs", doc)
        digest
      end

      _ = upload.([scenario("S1"), scenario("S3")])
      d2 = upload.([scenario("S1"), scenario("S3", "should")])
      item = item!(packet(ctx.sk_conn, slug, 1), "diff_set_weakened")
      reject = %{"head" => sha(1), "answer" => "reject", "note" => "S3 must stay a Must"}
      _ = ctx.sk_conn |> answer(slug, 1, item["id"], reject) |> json_response(201)
      approve = %{"head" => sha(1), "answer" => "approve"}
      _ = ctx.sk_conn |> answer(slug, 1, item["id"], approve) |> json_response(201)

      assert [%{"data" => rejected}] = of_type(ctx.sk_conn, ctx, "scenario_set_rejected")
      assert rejected == %{"source" => "diff", "digest" => d2, "note" => "S3 must stay a Must"}

      assert [%{"data" => approved}] = of_type(ctx.sk_conn, ctx, "scenario_set_approved")
      assert approved == %{"source" => "diff", "digest" => d2}
    end

    test "policy_version_created has no number", ctx do
      policy!(ctx.sk_conn, ctx.project.slug, %{}, 0, "tighten migrations")
      policy!(ctx.sk_conn, ctx.project.slug, %{}, 1, "again")

      assert [%{"number" => nil, "data" => first}, %{"data" => %{"version" => 2}}] =
               of_type(ctx.sk_conn, ctx, "policy_version_created")

      assert first == %{"version" => 1, "note" => "tighten migrations"}

      assert [%{"data" => %{"note" => nil}} | _rest] =
               of_type(ctx.pk_conn, ctx, "policy_version_created")
    end

    test "answer_recorded and task_created, redacted for pk_ without adding fields", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)
      facts!(ctx.sk_conn, slug, 1, sha(1))
      claims!(ctx.sk_conn, slug, 1, sha(1), %{"cr" => 1, "door" => "one_way"})
      [door] = packet(ctx.sk_conn, slug, 1)["items"]

      _ =
        ctx.sk_conn
        |> answer(slug, 1, door["id"], %{
          "head" => sha(1),
          "answer" => "request_change",
          "note" => "fine for v1"
        })
        |> json_response(201)

      [recorded] = of_type(ctx.sk_conn, ctx, "answer_recorded")

      assert recorded["data"] == %{
               "item_id" => door["id"],
               "kind" => "one_way_door",
               "head" => sha(1),
               "answer" => "request_change",
               "option" => nil,
               "note" => "fine for v1"
             }

      [task] = of_type(ctx.sk_conn, ctx, "task_created")

      assert %{"item_id" => item_id, "head" => head, "note" => "fine for v1", "task_id" => _} =
               task["data"]

      assert item_id == door["id"] and head == sha(1)

      [public] = of_type(ctx.pk_conn, ctx, "answer_recorded")
      assert public["actor"] == nil
      assert public["data"] == %{recorded["data"] | "note" => nil}

      # No `note` key is added to a type that has none.
      [state] = ctx.pk_conn |> of_type(ctx, "verdict_changed") |> Enum.take(1)
      refute Map.has_key?(state["data"], "note")

      assert ["fine for v1"] =
               Repo.all(
                 from e in Event, where: e.type == "answer_recorded", select: e.data["note"]
               )

      assert "verdict_changed" in types(ctx.sk_conn, ctx)
    end
  end
end
