defmodule GoodFlowsWeb.Api.V1.ChangeRequestReviewFlowTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
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
end
