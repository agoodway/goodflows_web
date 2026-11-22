defmodule GoodFlowsWeb.Api.V1.ChangeRequestReviewFlowTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures

  setup :api_setup

  test "needs_review, request a change, push a new head, approve everything, mergeable", ctx do
    slug = project_fixture(ctx.account).slug
    conn = ctx.sk_conn

    _ = create_cr(conn, slug)
    _ = conn |> post(cr_path(slug, 1, "/ready")) |> json_response(200)

    question = %{
      "id" => "q1",
      "text" => "Keep the old route?",
      "options" => ["keep", "drop"],
      "recommendation" => "keep"
    }

    claims = %{"cr" => 1, "door" => "one_way", "questions" => [question]}
    facts!(conn, slug, 1, sha(1))
    claims!(conn, slug, 1, sha(1), claims)
    cursor = events(conn, slug)["next_cursor"]

    packet = packet(conn, slug, 1)
    assert packet["verdict"] == "needs_review"
    door = item!(packet, "one_way_door")
    q1 = item!(packet, "question")

    _ =
      conn
      |> answer(slug, 1, door["id"], %{
        "head" => sha(1),
        "answer" => "request_change",
        "note" => "add a down migration"
      })
      |> json_response(201)

    [task] = conn |> get(cr_path(slug, 1, "/tasks")) |> json_response(200) |> Map.fetch!("data")
    assert %{"state" => "open", "note" => "add a down migration"} = task

    facts!(conn, slug, 1, sha(2))
    claims!(conn, slug, 1, sha(2), claims)

    [stale] = conn |> get(cr_path(slug, 1, "/tasks")) |> json_response(200) |> Map.fetch!("data")
    assert %{"id" => id, "state" => "stale"} = stale
    assert id == task["id"]

    packet = packet(conn, slug, 1)
    assert packet["head"] == sha(2)
    assert Enum.all?(packet["items"], &(&1["answer"] == nil))
    assert Enum.sort(Enum.map(packet["items"], & &1["id"])) == Enum.sort([door["id"], q1["id"]])

    _ =
      conn
      |> answer(slug, 1, door["id"], %{"head" => sha(2), "answer" => "approve"})
      |> json_response(201)

    _ =
      conn
      |> answer(slug, 1, q1["id"], %{"head" => sha(2), "answer" => "choose", "option" => "keep"})
      |> json_response(201)

    assert verdict(conn, slug, 1)["state"] == "mergeable"

    feed = events(conn, slug, %{"after" => cursor})["data"]
    types = Enum.map(feed, & &1["type"])
    assert "answer_recorded" in types and "task_created" in types

    assert %{"data" => %{"to" => "mergeable", "head" => head}, "number" => 1} =
             feed |> Enum.filter(&(&1["type"] == "verdict_changed")) |> List.last()

    assert head == sha(2)
  end

  describe "weakened diff set answers" do
    setup ctx do
      slug = project_fixture(ctx.account).slug

      policy!(ctx.sk_conn, slug, %{
        "scenarios" => %{"require_approved_intent" => true, "diff_only" => "weakening"}
      })

      _ = create_cr(ctx.sk_conn, slug)
      facts!(ctx.sk_conn, slug, 1, sha(1))
      claims!(ctx.sk_conn, slug, 1, sha(1), %{"cr" => 1})
      ctx = Map.put(ctx, :slug, slug)
      _ = passing_diff!(ctx, sha(1), [scenario("S1"), scenario("S3"), scenario("S5")])
      %{slug: slug}
    end

    defp passing_diff!(ctx, head, scenarios, body \\ "# QA scenarios\n") do
      digest =
        ctx.sk_conn
        |> post_json(
          cr_path(ctx.slug, 1, "/scenario-sets"),
          set_body(diff_fm(head, scenarios), body: body)
        )
        |> json_response(201)
        |> get_in(["data", "digest"])

      results = Enum.map(scenarios, &result(&1["id"]))
      doc = run_doc(digest, "diff", head, results)

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{ctx.slug}/verify-runs", doc)
        |> json_response(201)

      digest
    end

    defp weakened(ctx), do: items(packet(ctx.sk_conn, ctx.slug, 1), "diff_set_weakened")

    defp weakened!(ctx, id),
      do: Enum.find(weakened(ctx), &(&1["subject"] == ["diff", id])) || flunk("no item #{id}")

    defp answer!(ctx, conn, id, answer, note \\ nil) do
      body = %{"head" => sha(1), "answer" => answer}
      body = if note, do: Map.put(body, "note", note), else: body
      conn |> answer(ctx.slug, 1, weakened!(ctx, id)["id"], body) |> json_response(201)
    end

    defp decisions(ctx, version) do
      ctx.sk_conn
      |> get(cr_path(ctx.slug, 1, "/scenario-sets/diff/versions/#{version}"))
      |> json_response(200)
      |> get_in(["data", "decisions"])
    end

    defp task_states(ctx) do
      ctx.sk_conn
      |> get(cr_path(ctx.slug, 1, "/tasks"))
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["state"])
    end

    defp rules(ctx), do: Enum.map(verdict(ctx.sk_conn, ctx.slug, 1)["reasons"], & &1["rule"])

    test "accepting the only weakening makes the verdict mergeable", ctx do
      d2 = passing_diff!(ctx, sha(1), [scenario("S1"), scenario("S3", "should"), scenario("S5")])
      assert verdict(ctx.sk_conn, ctx.slug, 1)["state"] == "needs_review"
      assert [%{"subject" => ["diff", "S3"]}] = weakened(ctx)

      _ = answer!(ctx, ctx.sk_conn, "S3", "approve")

      verdict = verdict(ctx.sk_conn, ctx.slug, 1)
      assert verdict["state"] == "mergeable"
      refute "diff_set_weakened" in rules(ctx)
      assert verdict["scenarios"]["diff"]["baseline_version"] == 2
      assert verdict["scenarios"]["diff"]["accepted"]

      assert [%{"decision" => "approve", "digest" => ^d2, "channel" => "cli"}] =
               decisions(ctx, 2)

      assert decisions(ctx, 1) == []
    end

    test "one of two weakenings accepted records no decision", ctx do
      _ =
        passing_diff!(ctx, sha(1), [
          scenario("S1"),
          scenario("S3", "should"),
          scenario("S5", "could")
        ])

      _ = answer!(ctx, ctx.sk_conn, "S3", "approve")

      verdict = verdict(ctx.sk_conn, ctx.slug, 1)
      assert verdict["state"] == "needs_review"
      assert verdict["review"] == %{"items" => 2, "cleared" => 1}
      assert decisions(ctx, 2) == []
    end

    test "the decision is made by the completing member", ctx do
      d2 = passing_diff!(ctx, sha(1), [scenario("S1"), scenario("S3", "should")])
      assert length(weakened(ctx)) == 2

      first = answer!(ctx, ctx.sk_conn, "S3", "approve")["data"]
      completing = answer!(ctx, ctx.member_sk_conn, "S5", "approve")["data"]

      assert [%{"decision" => "approve", "digest" => ^d2, "channel" => "cli"} = decision] =
               decisions(ctx, 2)

      assert decision["decided_by"]["user_id"] == completing["answered_by"]["user_id"]
      assert decision["decided_by"]["user_id"] != first["answered_by"]["user_id"]

      assert [event] =
               Enum.filter(
                 events(ctx.sk_conn, ctx.slug)["data"],
                 &(&1["type"] == "scenario_set_approved")
               )

      assert event["data"] == %{"digest" => d2, "source" => "diff"}
      assert event["actor"] == completing["answered_by"]
      assert verdict(ctx.sk_conn, ctx.slug, 1)["state"] == "mergeable"
    end

    test "the next push after acceptance has no weakened item", ctx do
      scenarios = [scenario("S1"), scenario("S3", "should"), scenario("S5")]
      _ = passing_diff!(ctx, sha(1), scenarios)
      _ = answer!(ctx, ctx.sk_conn, "S3", "approve")

      facts!(ctx.sk_conn, ctx.slug, 1, sha(2))
      claims!(ctx.sk_conn, ctx.slug, 1, sha(2), %{"cr" => 1})
      _ = passing_diff!(ctx, sha(2), scenarios)

      assert weakened(ctx) == []
      verdict = verdict(ctx.sk_conn, ctx.slug, 1)
      assert verdict["state"] == "mergeable"
      assert verdict["scenarios"]["diff"]["baseline_version"] == 2
    end

    test "a rejection records a reject decision and a task and keeps the item", ctx do
      d2 = passing_diff!(ctx, sha(1), [scenario("S1"), scenario("S3", "should"), scenario("S5")])
      _ = answer!(ctx, ctx.sk_conn, "S3", "reject", "S3 must stay a Must")

      assert [%{"decision" => "reject", "digest" => ^d2, "note" => "S3 must stay a Must"}] =
               decisions(ctx, 2)

      [task] =
        ctx.sk_conn
        |> get(cr_path(ctx.slug, 1, "/tasks"))
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{"state" => "open", "note" => "S3 must stay a Must"} = task
      assert %{"answer" => %{"answer" => "reject"}} = weakened!(ctx, "S3")
      assert verdict(ctx.sk_conn, ctx.slug, 1)["state"] == "needs_review"
    end

    test "rejecting twice with the same note adds one decision row", ctx do
      d2 = passing_diff!(ctx, sha(1), [scenario("S1"), scenario("S3", "should"), scenario("S5")])
      _ = answer!(ctx, ctx.sk_conn, "S3", "reject", "S3 must stay a Must")
      _ = answer!(ctx, ctx.sk_conn, "S3", "reject", "S3 must stay a Must")

      assert [%{"decision" => "reject", "digest" => ^d2, "note" => "S3 must stay a Must"}] =
               decisions(ctx, 2)
    end

    test "a re-upload at the same head resets the answers and stales their tasks", ctx do
      scenarios = [scenario("S1"), scenario("S3", "should"), scenario("S5", "should")]
      _ = passing_diff!(ctx, sha(1), scenarios)
      _ = answer!(ctx, ctx.sk_conn, "S3", "approve")
      _ = answer!(ctx, ctx.sk_conn, "S5", "reject", "S5 must stay a Must")
      assert task_states(ctx) == ["open"]

      _ = passing_diff!(ctx, sha(1), scenarios, "# v3\n")

      assert %{"answer" => nil} = weakened!(ctx, "S3")
      assert %{"answer" => nil} = weakened!(ctx, "S5")
      assert verdict(ctx.sk_conn, ctx.slug, 1)["state"] == "needs_review"
      assert task_states(ctx) == ["stale"]
    end

    test "an earlier answer does not complete a later version", ctx do
      scenarios = [scenario("S1"), scenario("S3", "should"), scenario("S5", "should")]
      _ = passing_diff!(ctx, sha(1), scenarios)
      _ = answer!(ctx, ctx.sk_conn, "S3", "approve")

      _ = passing_diff!(ctx, sha(1), scenarios, "# v3\n")
      _ = answer!(ctx, ctx.sk_conn, "S5", "approve")

      assert decisions(ctx, 3) == []
      verdict = verdict(ctx.sk_conn, ctx.slug, 1)
      assert verdict["state"] == "needs_review"
      assert verdict["review"] == %{"items" => 2, "cleared" => 1}
    end
  end
end
