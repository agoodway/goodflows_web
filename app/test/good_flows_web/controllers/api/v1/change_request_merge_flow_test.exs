defmodule GoodFlowsWeb.Api.V1.ChangeRequestMergeFlowTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.MergeFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures

  setup :api_setup

  test "a stacked pair: lease, merge-result grading, merge, retarget, merge, defect", ctx do
    slug = project_fixture(ctx.account).slug
    conn = ctx.sk_conn

    # CR 1 on main, linked to an intent set and graded at its head.
    parent =
      mergeable!(conn, slug, sha(1),
        attrs: %{"openspec_change" => "add-export"},
        merge_base: sha(100)
      )

    digest =
      conn
      |> post_json(cr_path(slug, parent, "/scenario-sets"), set_body(intent_fm("add-export")))
      |> json_response(201)
      |> get_in(["data", "digest"])

    runs = "/api/v1/projects/#{slug}/verify-runs"

    conn
    |> post_json(runs, run_doc(digest, "intent", sha(1), [result("S1"), result("S2")]))
    |> json_response(201)

    assert verdict(conn, slug, parent)["state"] == "mergeable"

    # CR 2 stacked on CR 1, targeting CR 1's branch, with an approved one-way door.
    child = create_cr(conn, slug, %{"target_branch" => "feat/a"})["number"]
    _ = conn |> post(cr_path(slug, child, "/ready")) |> json_response(200)
    assert conn |> put_parent(slug, child, parent) |> json_response(200)
    facts!(conn, slug, child, sha(2), target: "feat/a")
    claims!(conn, slug, child, sha(2), %{"cr" => child, "door" => "one_way"})
    door = item!(packet(conn, slug, child), "one_way_door")

    assert conn
           |> answer(slug, child, door["id"], %{"head" => sha(2), "answer" => "approve"})
           |> json_response(201)

    waiting = verdict(conn, slug, child)
    assert waiting["state"] == "pending"
    assert Enum.sort(rules(waiting)) == ["one_way_door", "parent_not_merged"]

    # CR 1 acquires on a moved base, grades the merge result and merges.
    lease = acquire!(conn, slug, parent, sha(1), sha(200))
    assert rules(verdict(conn, slug, parent)) == ["merge_result_ungraded"]

    conn
    |> post_json(
      runs,
      run_doc(digest, "intent", sha(300), [result("S1"), result("S2")],
        merge_result: %{"base" => sha(200), "commit" => sha(300)}
      )
    )
    |> json_response(201)

    assert verdict(conn, slug, parent)["state"] == "mergeable"
    assert conn |> heartbeat(slug, lease["id"]) |> json_response(200)

    merge =
      conn
      |> merged(slug, parent, sha(400), %{"lease_id" => lease["id"]})
      |> json_response(200)
      |> get_in(["data", "merge"])

    assert %{
             "merged_without_lease" => false,
             "merged_without_mergeable_verdict" => false,
             "verdict_state" => "mergeable"
           } = merge

    # CR 2 is no longer waiting on its parent, retargets to main and keeps its answer.
    assert %{"state" => "mergeable"} = unblocked = verdict(conn, slug, child)
    assert rules(unblocked) == ["one_way_door"]

    assert %{"data" => %{"target_branch" => "main", "head" => head}} =
             conn |> retarget(slug, child, "main") |> json_response(200)

    assert head == sha(2)
    assert rules(verdict(conn, slug, child)) == ["git_facts_missing"]

    facts!(conn, slug, child, sha(2))
    assert verdict(conn, slug, child)["state"] == "mergeable"
    assert item!(packet(conn, slug, child), "one_way_door")["answer"]["answer"] == "approve"

    # Its base is its facts' merge base, so no merge-result check applies.
    child_lease = acquire!(conn, slug, child, sha(2), sha(0))
    assert verdict(conn, slug, child)["state"] == "mergeable"

    assert %{
             "data" => %{
               "merge" => %{
                 "merged_without_lease" => false,
                 "merged_without_mergeable_verdict" => false
               }
             }
           } =
             conn
             |> merged(slug, child, sha(401), %{"lease_id" => child_lease["id"]})
             |> json_response(200)

    # A defect by CR 1's commit is attributed to CR 1 and shows in the report and feed.
    defect =
      conn
      |> post_defect(slug, %{"commit" => sha(1), "severity" => "high"})
      |> json_response(201)
      |> Map.fetch!("data")

    assert %{"change_request" => ^parent, "attribution" => "commit"} = defect

    report = conn |> get(calibration_path(slug)) |> json_response(200) |> Map.fetch!("data")
    assert %{"merged_count" => 1, "defect_count" => 1} = report["lanes"]["auto"]
    assert %{"merged_count" => 1, "defect_count" => 0} = report["lanes"]["reviewed"]

    feed = events(conn, slug)["data"]
    assert %{"number" => ^parent} = Enum.find(feed, &(&1["type"] == "defect_recorded"))

    types = Enum.map(feed, & &1["type"])

    for type <- ~w(lease_acquired lease_renewed lease_released defect_recorded),
        do: assert(type in types)
  end
end
