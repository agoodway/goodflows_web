defmodule GoodFlowsWeb.Api.V1.ReviewControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import Ecto.Query
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.Repo
  alias GoodFlows.Review.{Answer, Items, Task}
  alias GoodFlows.ScenarioSets.Decision
  alias GoodFlows.VerifyRuns.Artifact
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp one_way!(ctx, head \\ sha(1), overrides \\ %{}) do
    slug = ctx.project.slug
    facts!(ctx.sk_conn, slug, 1, head)
    claims!(ctx.sk_conn, slug, 1, head, Map.merge(%{"cr" => 1, "door" => "one_way"}, overrides))
  end

  defp intent_set!(ctx, fm \\ nil) do
    body = set_body(fm || intent_fm("add-export"))

    ctx.sk_conn
    |> post_json(cr_path(ctx.project.slug, 1, "/scenario-sets"), body)
    |> json_response(201)
    |> get_in(["data", "digest"])
  end

  describe "access" do
    setup ctx do
      _ = create_cr(ctx.sk_conn, ctx.project.slug)
      :ok
    end

    test "sk_ reads, pk_ and ck_ are 403 with no packet data, no key is 401", ctx do
      slug = ctx.project.slug
      body = ctx.sk_conn |> get(cr_path(slug, 1, "/review")) |> json_response(200)
      assert_schema(body, "ReviewPacketResponse", ApiSpec.spec())
      assert body["data"]["number"] == 1

      forbidden = ctx.pk_conn |> get(cr_path(slug, 1, "/review")) |> json_response(403)
      assert Map.keys(forbidden) == ["errors"]

      owner = Repo.preload(ctx.sk_key, :account_user).account_user
      {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read_write"})
      assert api_conn(ck) |> get(cr_path(slug, 1, "/review")) |> json_response(403)

      assert build_conn() |> get(cr_path(slug, 1, "/review")) |> json_response(401)
      assert ctx.pk_conn |> get(cr_path(slug, 1, "/tasks")) |> json_response(403)

      assert ctx.pk_conn
             |> answer(slug, 1, "one_way_door:x", %{"head" => nil, "answer" => "approve"})
             |> json_response(403)

      assert count(Answer) == 0
    end

    test "unknown change request and other account are 404, bad Accept is 406", ctx do
      slug = ctx.project.slug
      assert ctx.sk_conn |> get(cr_path(slug, 999, "/review")) |> json_response(404)
      assert ctx.other_conn |> get(cr_path(slug, 1, "/review")) |> json_response(404)
      assert ctx.sk_conn |> get(cr_path("Bad Slug", 1, "/review")) |> json_response(422)

      {status, _headers, _body} =
        assert_error_sent(406, fn ->
          ctx.sk_conn
          |> put_req_header("accept", "text/plain")
          |> get(cr_path(slug, 1, "/review"))
        end)

      assert status == 406
    end
  end

  describe "packet header" do
    test "no facts: head and base null, pending git_facts_missing, no items", ctx do
      _ = create_cr(ctx.sk_conn, ctx.project.slug)
      packet = packet(ctx.sk_conn, ctx.project.slug, 1)

      assert %{"head" => nil, "base" => nil, "verdict" => "pending", "items" => []} = packet
      assert [%{"rule" => "git_facts_missing", "subject" => []}] = packet["pending"]
      assert packet["blocked"] == []
    end

    test "head, base, policy version and what passed", ctx do
      slug = ctx.project.slug
      policy!(ctx.sk_conn, slug, %{"evidence" => %{"required_workflows" => ["ci"]}})
      _ = create_cr(ctx.sk_conn, slug, %{"openspec_change" => "add-export"})
      head = sha(1)
      one_way!(ctx, head)

      assert ctx.sk_conn
             |> post_json("/api/v1/projects/#{slug}/workflow-runs", run_document(head, "passed"))
             |> json_response(201)

      digest =
        intent_set!(ctx, intent_fm("add-export", [scenario("S1"), scenario("S2", "should")]))

      doc = run_doc(digest, "intent", head, [result("S1"), result("S2")])

      assert ctx.sk_conn
             |> post_json("/api/v1/projects/#{slug}/verify-runs", doc)
             |> json_response(201)

      packet = packet(ctx.sk_conn, slug, 1)
      assert packet["head"] == head
      assert packet["base"] == %{"branch" => "main", "merge_base" => sha(0)}
      assert packet["policy_version"] == 1
      assert packet["passed"] == %{"must" => 1, "should" => 1, "workflows" => ["ci"]}
      assert packet["verdict"] == "needs_review"
    end

    test "a mergeable change request has no items, pending or blocked entries", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)
      facts!(ctx.sk_conn, slug, 1, sha(1))
      claims!(ctx.sk_conn, slug, 1, sha(1), %{"cr" => 1})

      assert %{"verdict" => "mergeable", "items" => [], "pending" => [], "blocked" => []} =
               packet(ctx.sk_conn, slug, 1)
    end

    test "a missing workflow is a pending entry, never an item, and cannot be answered", ctx do
      slug = ctx.project.slug
      policy!(ctx.sk_conn, slug, %{"evidence" => %{"required_workflows" => ["ci"]}})
      _ = create_cr(ctx.sk_conn, slug)
      one_way!(ctx)

      packet = packet(ctx.sk_conn, slug, 1)

      assert [%{"rule" => "required_workflow_missing", "subject" => ["ci"]} = entry] =
               packet["pending"]

      refute Map.has_key?(entry, "id")
      assert Enum.map(packet["items"], & &1["kind"]) == ["one_way_door"]

      assert ctx.sk_conn
             |> answer(slug, 1, Items.id("required_workflow_missing", ["ci"]), %{
               "head" => sha(1),
               "answer" => "approve"
             })
             |> json_response(404)

      assert count(Answer) == 0
    end
  end

  describe "scenario set approval item" do
    setup ctx do
      policy!(ctx.sk_conn, ctx.project.slug, %{
        "scenarios" => %{"require_approved_intent" => true}
      })

      _ = create_cr(ctx.sk_conn, ctx.project.slug, %{"openspec_change" => "add-export"})
      :ok
    end

    test "no intent set: a pending entry with subject [] and no item", ctx do
      packet = packet(ctx.sk_conn, ctx.project.slug, 1)
      assert packet["items"] == []

      assert %{"subject" => []} =
               Enum.find(packet["pending"], &(&1["rule"] == "scenario_set_approval"))
    end

    test "before code: one item, approved with head null", ctx do
      slug = ctx.project.slug
      digest = intent_set!(ctx)
      packet = packet(ctx.sk_conn, slug, 1)

      assert %{"head" => nil, "base" => nil, "verdict" => "pending"} = packet
      assert [%{"rule" => "git_facts_missing"}] = packet["pending"]

      assert [
               %{"kind" => "scenario_set_approval", "subject" => [^digest], "answer" => nil} =
                 item
             ] =
               packet["items"]

      assert item["answers"] == ["approve", "reject"]
      assert %{"digest" => ^digest, "version" => 1, "approved_digest" => nil} = item["data"]
      assert Enum.map(item["data"]["changes"], & &1["change"]) == ["added", "added"]

      created =
        ctx.sk_conn
        |> answer(slug, 1, item["id"], %{"head" => nil, "answer" => "approve"})
        |> json_response(201)

      assert_schema(created, "ReviewAnswerResponse", ApiSpec.spec())
      assert created["data"]["head"] == nil
      assert [%Decision{decision: "approve", digest: ^digest}] = Repo.all(Decision)
      assert packet(ctx.sk_conn, slug, 1)["items"] == []

      # Still approved at a later head with the same intent set.
      one_way!(ctx)
      assert items(packet(ctx.sk_conn, slug, 1), "scenario_set_approval") == []
    end

    test "reject records the decision, unapproves, creates a task, keeps the item", ctx do
      slug = ctx.project.slug
      digest = intent_set!(ctx)
      item = item!(packet(ctx.sk_conn, slug, 1), "scenario_set_approval")

      _ =
        ctx.sk_conn
        |> answer(slug, 1, item["id"], %{"head" => nil, "answer" => "approve"})
        |> json_response(201)

      assert items(packet(ctx.sk_conn, slug, 1), "scenario_set_approval") == []

      # Reject through the decision call, then the item is back and the
      # answer path rejects it again with the same note twice.
      _ =
        ctx.sk_conn
        |> post_json(cr_path(slug, 1, "/scenario-sets/intent/rejections"), %{
          "digest" => digest,
          "note" => "first"
        })
        |> json_response(201)

      item = item!(packet(ctx.sk_conn, slug, 1), "scenario_set_approval")
      decisions = count(Decision)

      # A blank note is refused as by the rejection call.
      assert %{"errors" => %{"note" => ["can't be blank"]}} =
               ctx.sk_conn
               |> answer(slug, 1, item["id"], %{
                 "head" => nil,
                 "answer" => "reject",
                 "note" => " "
               })
               |> json_response(422)

      assert count(Decision) == decisions
      assert count(Task) == 0

      body = %{"head" => nil, "answer" => "reject", "note" => "S2 tests the wrong path"}
      first = ctx.sk_conn |> answer(slug, 1, item["id"], body) |> json_response(201)
      second = ctx.sk_conn |> answer(slug, 1, item["id"], body) |> json_response(201)

      rejects =
        Repo.all(from d in Decision, where: d.note == "S2 tests the wrong path")

      assert length(rejects) == 1

      list = ctx.sk_conn |> get(cr_path(slug, 1, "/scenario-sets")) |> json_response(200)
      assert [%{"approved" => false}] = list["data"]["intent"]["versions"]

      packet = packet(ctx.sk_conn, slug, 1)
      item = item!(packet, "scenario_set_approval")
      assert item["answer"]["id"] == second["data"]["id"]
      assert Repo.get!(Answer, first["data"]["id"]).superseded_at

      tasks = Repo.all(from t in Task, order_by: t.inserted_at)
      assert Enum.map(tasks, & &1.state) == ["stale", "open"]
      assert Enum.all?(tasks, &(&1.note == "S2 tests the wrong path"))

      types =
        ctx.sk_conn
        |> events(slug)
        |> Map.fetch!("data")
        |> Enum.filter(&(&1["type"] == "scenario_set_rejected"))

      assert length(types) == 2
    end

    test "three items; the set item is counted but cleared only by approval", ctx do
      slug = ctx.project.slug
      head = sha(1)
      one_way!(ctx, head)
      _ = intent_set!(ctx)

      # The unapproved intent set is not graded, so the Should failure comes
      # from a diff set at the head.
      diff =
        ctx.sk_conn
        |> post_json(
          cr_path(slug, 1, "/scenario-sets"),
          set_body(diff_fm(head, [scenario("D1"), scenario("D2", "should")]))
        )
        |> json_response(201)
        |> get_in(["data", "digest"])

      doc = run_doc(diff, "diff", head, [result("D1"), result("D2", "failed")])

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{slug}/verify-runs", doc)
        |> json_response(201)

      packet = packet(ctx.sk_conn, slug, 1)

      assert Enum.sort(Enum.map(packet["items"], & &1["kind"])) ==
               ["failed_scenario", "one_way_door", "scenario_set_approval"]

      for kind <- ~w(one_way_door failed_scenario) do
        ctx.sk_conn
        |> answer(slug, 1, item!(packet, kind)["id"], %{"head" => head, "answer" => "approve"})
        |> json_response(201)
      end

      assert %{"review" => %{"items" => 3, "cleared" => 2}} = verdict(ctx.sk_conn, slug, 1)

      set = item!(packet, "scenario_set_approval")

      _ =
        ctx.sk_conn
        |> answer(slug, 1, set["id"], %{"head" => head, "answer" => "approve"})
        |> json_response(201)

      packet = packet(ctx.sk_conn, slug, 1)
      assert items(packet, "scenario_set_approval") == []
      assert %{"review" => %{"items" => items}} = verdict(ctx.sk_conn, slug, 1)
      assert items == length(packet["items"])
    end

    test "approver other_member: the author is 403, another member is 201", ctx do
      slug = ctx.project.slug

      policy!(
        ctx.sk_conn,
        slug,
        %{"scenarios" => %{"require_approved_intent" => true, "approver" => "other_member"}},
        1
      )

      _ = intent_set!(ctx)
      item = item!(packet(ctx.sk_conn, slug, 1), "scenario_set_approval")
      body = %{"head" => nil, "answer" => "approve"}

      assert ctx.sk_conn |> answer(slug, 1, item["id"], body) |> json_response(403)
      assert count(Answer) == 0
      assert count(Decision) == 0

      assert ctx.member_sk_conn |> answer(slug, 1, item["id"], body) |> json_response(201)
    end

    test "on a closed change request every answer is 409 first", ctx do
      slug = ctx.project.slug

      policy!(
        ctx.sk_conn,
        slug,
        %{"scenarios" => %{"require_approved_intent" => true, "approver" => "other_member"}},
        1
      )

      _ = intent_set!(ctx)
      item = item!(packet(ctx.sk_conn, slug, 1), "scenario_set_approval")
      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/close")) |> json_response(200)

      assert ctx.sk_conn
             |> answer(slug, 1, item["id"], %{"head" => nil, "answer" => "approve"})
             |> json_response(409)

      assert ctx.sk_conn
             |> answer(slug, 1, item["id"], %{"head" => sha(9), "answer" => "nope", "x" => 1})
             |> json_response(409)

      assert ctx.sk_conn |> answer(slug, 1, "unknown", "{bad json") |> json_response(409)
      assert count(Answer) == 0
    end
  end

  describe "items" do
    setup ctx do
      _ = create_cr(ctx.sk_conn, ctx.project.slug, %{"openspec_change" => "add-export"})
      :ok
    end

    test "one-way door, size, sensitive path, unproven claim, questions and open items", ctx do
      slug = ctx.project.slug
      head = sha(1)
      migration = "app/priv/repo/migrations/1_add.exs"
      files = [file(migration, %{"additions" => 1_000}), file("lib/a.ex", %{"additions" => 600})]
      files = files ++ for(n <- 1..40, do: file("lib/f#{n}.ex"))
      facts!(ctx.sk_conn, slug, 1, head, files: files)

      claims!(ctx.sk_conn, slug, 1, head, %{
        "cr" => 1,
        "door" => "one_way",
        "safe_because" => [
          %{"fact" => "A", "location" => "lib/a.ex:1", "proof" => "stated"},
          %{
            "fact" => "B",
            "location" => "lib/a.ex:2",
            "proof" => "ran",
            "evidence" => ["test/a_test.exs"]
          }
        ],
        "questions" => [
          %{
            "id" => "q1",
            "text" => "Keep it?",
            "options" => ["keep", "drop"],
            "recommendation" => "keep"
          },
          %{
            "id" => "q2",
            "text" => "Rename?",
            "options" => ["yes", "no"],
            "recommendation" => "no"
          }
        ],
        "left_open" => [
          %{"risk" => "slow", "location" => "lib/a.ex", "affected" => "ops"},
          %{"risk" => "slow", "location" => "lib/b.ex", "affected" => "ops"}
        ],
        "decisions" => [
          %{"id" => "d1", "path" => migration, "hunk" => "@@ -0,0 +1 @@", "note" => "new table"},
          %{"id" => "d2", "path" => "lib/a.ex", "hunk" => "@@ -1 +1 @@", "note" => "rename"}
        ]
      })

      packet = packet(ctx.sk_conn, slug, 1)
      assert packet["verdict"] == "needs_review"

      kinds = packet["items"] |> Enum.map(& &1["kind"]) |> Enum.frequencies()

      assert kinds == %{
               "one_way_door" => 1,
               "size" => 2,
               "sensitive_path" => 1,
               "unproven_claim" => 1,
               "question" => 2,
               "open_item" => 2
             }

      door = item!(packet, "one_way_door")
      assert door["answers"] == ["approve", "request_change"]
      assert door["data"]["door_reason"] == "Reverting the commit undoes it"
      assert door["data"]["reach"] == "Only the change request API"
      assert Enum.map(door["data"]["decisions"], & &1["id"]) == ["d1", "d2"]
      assert hd(door["data"]["decisions"])["hunk"] == "@@ -0,0 +1 @@"

      sizes = items(packet, "size")
      assert Enum.map(sizes, & &1["rule"]) == ["max_changed_files", "max_changed_lines"]

      assert %{
               "limit" => "max_changed_files",
               "changed_files" => 42,
               "changed_lines" => 1_640,
               "max_changed_files" => 40,
               "max_changed_lines" => 1_500
             } = hd(sizes)["data"]

      sensitive = item!(packet, "sensitive_path")
      assert sensitive["rule"] == "path_match"
      assert sensitive["data"]["glob"] == "app/priv/repo/migrations/**"

      assert [%{"path" => ^migration, "additions" => 1_000, "deletions" => 0, "old_path" => nil}] =
               sensitive["data"]["files"]

      assert Enum.map(sensitive["data"]["decisions"], & &1["id"]) == ["d1"]

      unproven = item!(packet, "unproven_claim")
      assert unproven["rule"] == "proof_below_minimum"

      assert unproven["data"] == %{
               "min_proof_level" => "ran",
               "claims" => [
                 %{
                   "fact" => "A",
                   "location" => "lib/a.ex:1",
                   "proof" => "stated",
                   "evidence" => nil,
                   "covers" => nil
                 }
               ]
             }

      [q1, q2] = items(packet, "question")
      assert q1["answers"] == ["choose", "request_change"]
      assert q1["subject"] == ["q1"] and q2["subject"] == ["q2"]

      assert q1["data"] == %{
               "id" => "q1",
               "text" => "Keep it?",
               "options" => ["keep", "drop"],
               "recommendation" => "keep"
             }

      [o1, o2] = items(packet, "open_item")
      assert o1["subject"] == ["0", "slow"] and o2["subject"] == ["1", "slow"]
      assert o1["id"] != o2["id"]
      assert o2["data"] == %{"risk" => "slow", "location" => "lib/b.ex", "affected" => "ops"}

      assert packet(ctx.sk_conn, slug, 1)["items"] |> Enum.map(& &1["id"]) ==
               Enum.map(packet["items"], & &1["id"])

      for item <- packet["items"], do: assert(item["id"] =~ ~r/\A[a-z_]+:[0-9a-f]{64}\z/)
    end

    test "failed and not-run Should scenarios with presigned and expired artifacts", ctx do
      slug = ctx.project.slug
      head = sha(1)
      facts!(ctx.sk_conn, slug, 1, head)
      claims!(ctx.sk_conn, slug, 1, head, %{"cr" => 1})

      digest =
        intent_set!(
          ctx,
          intent_fm("add-export", [
            scenario("S1"),
            scenario("S2", "should"),
            scenario("S3", "should")
          ])
        )

      shot = "png bytes"

      doc =
        run_doc(
          digest,
          "intent",
          head,
          [result("S1"), result("S2", "failed", ["shot-1"]), result("S3", "not_run")],
          artifacts: [artifact("shot-1", shot)]
        )

      runs = "/api/v1/projects/#{slug}/verify-runs"
      ack = ctx.sk_conn |> post_json(runs, doc) |> json_response(201)
      [upload] = ack["data"]["uploads"]
      :ok = Fake.put(upload["upload_url"], upload["upload_headers"], shot)
      _ = ctx.sk_conn |> post_json(runs <> "/#{doc["run_id"]}/commit", %{}) |> json_response(200)

      before = DateTime.utc_now()
      packet = packet(ctx.sk_conn, slug, 1)
      failed = item!(packet, "failed_scenario")
      assert failed["rule"] == "should_failed"
      assert failed["subject"] == ["intent", "S2"]

      assert %{
               "id" => "S2",
               "priority" => "should",
               "digest" => ^digest,
               "commit" => ^head,
               "failed_step" => "step 2",
               "reason" => "it broke",
               "artifacts" => [artifact]
             } = failed["data"]

      assert failed["data"]["run_id"] == doc["run_id"]
      assert %{"id" => "shot-1", "content_type" => "image/png", "expired" => false} = artifact
      assert artifact["url"] =~ "fake-object-store"
      assert artifact["url"] =~ "X-Amz-Expires=900"
      {:ok, expires_at, 0} = DateTime.from_iso8601(artifact["expires_at"])
      assert DateTime.diff(expires_at, before) in 900..905

      # A later read presigns again, valid for 15 minutes from that read.
      second_before = DateTime.utc_now()
      [again] = item!(packet(ctx.sk_conn, slug, 1), "failed_scenario")["data"]["artifacts"]
      assert again["url"] =~ "X-Amz-Expires=900"
      {:ok, again_expires_at, 0} = DateTime.from_iso8601(again["expires_at"])
      assert DateTime.diff(again_expires_at, second_before, :millisecond) in 899_000..905_000
      assert DateTime.compare(again_expires_at, expires_at) in [:gt, :eq]

      not_run = item!(packet, "not_run")
      assert not_run["rule"] == "should_not_run"

      assert %{"id" => "S3", "priority" => "should", "digest" => ^digest, "reason" => "it broke"} =
               not_run["data"]

      Repo.update_all(Artifact, set: [expired: true])
      [expired] = item!(packet(ctx.sk_conn, slug, 1), "failed_scenario")["data"]["artifacts"]
      assert %{"expired" => true, "url" => nil, "expires_at" => nil} = expired
    end

    test "spec gap with the covering claim below the minimum", ctx do
      slug = ctx.project.slug
      policy!(ctx.sk_conn, slug, %{"scenarios" => %{"spec_gaps" => "needs_review"}})
      head = sha(1)
      facts!(ctx.sk_conn, slug, 1, head)
      row = %{"capability" => "export", "requirement" => "Export CSV", "scenario" => "Empty"}

      claims!(ctx.sk_conn, slug, 1, head, %{
        "cr" => 1,
        "safe_because" => [
          %{
            "fact" => "Empty works",
            "location" => "lib/a.ex:1",
            "proof" => "walked",
            "covers" => row
          }
        ]
      })

      coverage = [Map.merge(row, %{"status" => "no_check", "scenarios" => []})]

      digest =
        intent_set!(ctx, intent_fm("add-export", [scenario("S1")], %{"coverage" => coverage}))

      doc = run_doc(digest, "intent", head, [result("S1")])

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{slug}/verify-runs", doc)
        |> json_response(201)

      packet = packet(ctx.sk_conn, slug, 1)
      gap = item!(packet, "spec_gap")
      assert gap["rule"] == "spec_gap"

      assert gap["data"] == %{
               "capability" => "export",
               "requirement" => "Export CSV",
               "scenario" => "Empty",
               "digest" => digest,
               "version" => 1,
               "covering_claims" => [
                 %{"fact" => "Empty works", "proof" => "walked", "evidence" => nil}
               ]
             }
    end
  end

  test "diff-only set, unmapped area and undriven feature items", ctx do
    slug = ctx.project.slug

    policy!(ctx.sk_conn, slug, %{
      "scenarios" => %{"require_approved_intent" => true},
      "coverage" => %{"unmapped_areas" => "needs_review", "undriven_features" => "needs_review"}
    })

    _ = create_cr(ctx.sk_conn, slug)
    head = sha(1)
    facts!(ctx.sk_conn, slug, 1, head, files: [file("lib/a.ex"), file("priv/b.sql")])
    claims!(ctx.sk_conn, slug, 1, head, %{"cr" => 1})

    _ =
      ctx.sk_conn
      |> post_json("/api/v1/projects/#{slug}/feature-index", %{
        "features" => [feature("lib", ["lib/**"])]
      })
      |> json_response(201)

    digest =
      ctx.sk_conn
      |> post_json(cr_path(slug, 1, "/scenario-sets"), set_body(diff_fm(head)))
      |> json_response(201)
      |> get_in(["data", "digest"])

    doc = run_doc(digest, "diff", head, [result("D1")])

    _ =
      ctx.sk_conn |> post_json("/api/v1/projects/#{slug}/verify-runs", doc) |> json_response(201)

    packet = packet(ctx.sk_conn, slug, 1)

    assert %{"digest" => ^digest, "revision" => ^head, "scenarios" => [scenario]} =
             item!(packet, "diff_only_set")["data"]

    assert %{"id" => "D1", "priority" => "must", "result" => "passed"} = scenario

    assert item!(packet, "unmapped_area")["data"] == %{
             "paths" => ["priv/b.sql"],
             "feature_index_version" => 1
           }

    assert item!(packet, "undriven_feature")["data"] == %{
             "id" => "lib",
             "title" => "Feature lib",
             "paths" => ["lib/a.ex"]
           }
  end

  test "weakened diff set item: data, and the author is 403 under other_member", ctx do
    slug = ctx.project.slug

    policy!(ctx.sk_conn, slug, %{
      "scenarios" => %{
        "require_approved_intent" => true,
        "diff_only" => "weakening",
        "approver" => "other_member"
      }
    })

    _ = create_cr(ctx.sk_conn, slug)
    head = sha(1)
    facts!(ctx.sk_conn, slug, 1, head)
    claims!(ctx.sk_conn, slug, 1, head, %{"cr" => 1})

    upload = fn scenarios, salts ->
      ctx.sk_conn
      |> post_json(
        cr_path(slug, 1, "/scenario-sets"),
        set_body(diff_fm(head, scenarios), salts: salts)
      )
      |> json_response(201)
      |> get_in(["data", "digest"])
    end

    d1 = upload.([scenario("S1"), scenario("S3")], %{})
    d2 = upload.([scenario("S1"), scenario("S3", "should")], %{"S1" => "edited"})

    doc = run_doc(d2, "diff", head, [result("S1"), result("S3")])

    _ =
      ctx.sk_conn |> post_json("/api/v1/projects/#{slug}/verify-runs", doc) |> json_response(201)

    packet = packet(ctx.sk_conn, slug, 1)
    assert_schema(%{"data" => packet}, "ReviewPacketResponse", ApiSpec.spec())
    item = item!(packet, "diff_set_weakened")

    assert item["subject"] == ["diff", "S3"]
    assert item["answers"] == ["approve", "reject"]

    assert item["data"] == %{
             "id" => "S3",
             "change" => "demoted",
             "from_priority" => "must",
             "to_priority" => "should",
             "version" => 2,
             "digest" => d2,
             "baseline" => %{"version" => 1, "digest" => d1},
             "edited_musts" => ["S1"]
           }

    body = %{"head" => head, "answer" => "approve"}
    assert ctx.sk_conn |> answer(slug, 1, item["id"], body) |> json_response(403)
    assert count(Answer) == 0
    assert count(Decision) == 0

    assert ctx.member_sk_conn |> answer(slug, 1, item["id"], body) |> json_response(201)
  end

  describe "answers" do
    setup ctx do
      _ = create_cr(ctx.sk_conn, ctx.project.slug)
      one_way!(ctx)
      %{door: item!(packet(ctx.sk_conn, ctx.project.slug, 1), "one_way_door")}
    end

    test "approve clears the only item; the packet shows the answer", ctx do
      slug = ctx.project.slug

      created =
        ctx.sk_conn
        |> answer(slug, 1, ctx.door["id"], %{"head" => sha(1), "answer" => "approve"})
        |> json_response(201)

      assert %{"answer" => "approve", "channel" => "cli", "head" => head} = created["data"]
      assert head == sha(1)

      door = item!(packet(ctx.sk_conn, slug, 1), "one_way_door")
      assert door["answer"]["id"] == created["data"]["id"]

      verdict = verdict(ctx.sk_conn, slug, 1)
      assert verdict["state"] == "mergeable"
      assert verdict["review"] == %{"items" => 1, "cleared" => 1}
      assert [%{"rule" => "one_way_door"}] = verdict["reasons"]
    end

    test "invalid bodies are 422 and store nothing", ctx do
      slug = ctx.project.slug
      id = ctx.door["id"]
      head = sha(1)

      assert %{"errors" => %{"note" => _}} =
               ctx.sk_conn
               |> answer(slug, 1, id, %{"head" => head, "answer" => "request_change"})
               |> json_response(422)

      assert %{"errors" => %{"note" => ["can't be blank"]}} =
               ctx.sk_conn
               |> answer(slug, 1, id, %{
                 "head" => head,
                 "answer" => "request_change",
                 "note" => "   "
               })
               |> json_response(422)

      assert %{"errors" => %{"option" => _}} =
               ctx.sk_conn
               |> answer(slug, 1, id, %{"head" => head, "answer" => "approve", "option" => "a"})
               |> json_response(422)

      assert %{"errors" => %{"body" => ["has an unknown field"]}} =
               ctx.sk_conn
               |> answer(slug, 1, id, %{"head" => head, "answer" => "approve", "channel" => "web"})
               |> json_response(422)

      assert %{"errors" => %{"answer" => _}} =
               ctx.sk_conn
               |> answer(slug, 1, id, %{"head" => head, "answer" => "reject", "note" => "no"})
               |> json_response(422)

      assert %{"errors" => %{"note" => _}} =
               ctx.sk_conn
               |> answer(slug, 1, id, %{
                 "head" => head,
                 "answer" => "approve",
                 "note" => String.duplicate("a", 10_001)
               })
               |> json_response(422)

      assert count(Answer) == 0
    end

    test "a stale head is 409 with the current head", ctx do
      slug = ctx.project.slug
      one_way!(ctx, sha(2))

      assert %{"errors" => %{"head" => current}} =
               ctx.sk_conn
               |> answer(slug, 1, ctx.door["id"], %{"head" => sha(1), "answer" => "approve"})
               |> json_response(409)

      assert current == sha(2)
      assert count(Answer) == 0
    end

    test "an unknown item is 404", ctx do
      assert ctx.sk_conn
             |> answer(ctx.project.slug, 1, "one_way_door:00", %{
               "head" => sha(1),
               "answer" => "approve"
             })
             |> json_response(404)
    end

    test "a non-admin member answers a one-way door under approver admin", ctx do
      slug = ctx.project.slug
      policy!(ctx.sk_conn, slug, %{"scenarios" => %{"approver" => "admin"}})

      assert ctx.member_sk_conn
             |> answer(slug, 1, ctx.door["id"], %{"head" => sha(1), "answer" => "approve"})
             |> json_response(201)
    end

    test "change of mind: the later answer counts and the first task goes stale", ctx do
      slug = ctx.project.slug
      id = ctx.door["id"]

      first =
        ctx.sk_conn
        |> answer(slug, 1, id, %{
          "head" => sha(1),
          "answer" => "request_change",
          "note" => "add a down migration"
        })
        |> json_response(201)

      [task] =
        ctx.sk_conn |> get(cr_path(slug, 1, "/tasks")) |> json_response(200) |> Map.fetch!("data")

      assert %{
               "state" => "open",
               "note" => "add a down migration",
               "item_id" => ^id,
               "answer" => "request_change",
               "kind" => "one_way_door",
               "number" => 1
             } = task

      assert task["head"] == sha(1)
      assert verdict(ctx.sk_conn, slug, 1)["state"] == "needs_review"

      _ =
        ctx.sk_conn
        |> answer(slug, 1, id, %{"head" => sha(1), "answer" => "approve"})
        |> json_response(201)

      assert item!(packet(ctx.sk_conn, slug, 1), "one_way_door")["answer"]["answer"] == "approve"
      assert verdict(ctx.sk_conn, slug, 1)["state"] == "mergeable"
      assert Repo.get!(Task, task["id"]).state == "stale"
      assert Repo.get!(Answer, first["data"]["id"]).superseded_at
    end

    test "a new head starts a full review; the earlier head's answers count again", ctx do
      slug = ctx.project.slug

      _ =
        ctx.sk_conn
        |> answer(slug, 1, ctx.door["id"], %{"head" => sha(1), "answer" => "approve"})
        |> json_response(201)

      assert verdict(ctx.sk_conn, slug, 1)["state"] == "mergeable"

      one_way!(ctx, sha(2))
      door = item!(packet(ctx.sk_conn, slug, 1), "one_way_door")
      assert door["id"] == ctx.door["id"]
      assert door["answer"] == nil

      assert %{"state" => "needs_review", "review" => %{"items" => 1, "cleared" => 0}} =
               verdict(ctx.sk_conn, slug, 1)

      facts!(ctx.sk_conn, slug, 1, sha(1))
      assert item!(packet(ctx.sk_conn, slug, 1), "one_way_door")["answer"]["answer"] == "approve"
      assert verdict(ctx.sk_conn, slug, 1)["state"] == "mergeable"
    end
  end

  describe "packet consistency" do
    setup ctx do
      _ = create_cr(ctx.sk_conn, ctx.project.slug, %{"openspec_change" => "add-export"})
      one_way!(ctx, sha(1))
      :ok
    end

    test "a change request loaded before a new head gives the new head's packet", ctx do
      loaded =
        Repo.get_by!(GoodFlows.ChangeRequests.ChangeRequest,
          project_id: ctx.project.id,
          number: 1
        )

      assert loaded.head == sha(1)

      one_way!(ctx, sha(2))

      packet = GoodFlows.Review.packet(loaded)
      verdict = Repo.get!(GoodFlows.ChangeRequests.Verdict, loaded.id)
      assert packet.head == sha(2)
      assert packet.head == verdict.head
    end
  end

  describe "verdict integration" do
    setup ctx do
      _ = create_cr(ctx.sk_conn, ctx.project.slug, %{"openspec_change" => "add-export"})
      :ok
    end

    test "progress counts and a question cleared only by choose", ctx do
      slug = ctx.project.slug

      one_way!(ctx, sha(1), %{
        "questions" => [
          %{
            "id" => "q1",
            "text" => "Keep?",
            "options" => ["keep", "drop"],
            "recommendation" => "keep"
          },
          %{"id" => "q2", "text" => "Name?", "options" => ["a", "b"], "recommendation" => "a"}
        ]
      })

      packet = packet(ctx.sk_conn, slug, 1)
      [q1, q2] = items(packet, "question")
      door = item!(packet, "one_way_door")
      head = sha(1)

      assert %{"errors" => %{"option" => _}} =
               ctx.sk_conn
               |> answer(slug, 1, q1["id"], %{
                 "head" => head,
                 "answer" => "choose",
                 "option" => "maybe"
               })
               |> json_response(422)

      stored =
        ctx.sk_conn
        |> answer(slug, 1, q1["id"], %{
          "head" => head,
          "answer" => "choose",
          "option" => "keep",
          "note" => "fine for v1"
        })
        |> json_response(201)

      answer = Repo.get!(Answer, stored["data"]["id"])

      assert %{answer: "choose", option: "keep", note: "fine for v1", channel: "cli", head: ^head} =
               answer

      assert answer.api_key_id == ctx.sk_key.id
      assert answer.account_user_id == ctx.sk_key.account_user_id
      assert answer.item_id == q1["id"]

      assert verdict(ctx.sk_conn, slug, 1)["state"] == "needs_review"

      _ =
        ctx.sk_conn
        |> answer(slug, 1, door["id"], %{"head" => head, "answer" => "approve"})
        |> json_response(201)

      _ =
        ctx.sk_conn
        |> answer(slug, 1, q2["id"], %{
          "head" => head,
          "answer" => "request_change",
          "note" => "x"
        })
        |> json_response(201)

      assert %{"state" => "needs_review", "review" => %{"items" => 3, "cleared" => 2}} =
               verdict(ctx.sk_conn, slug, 1)

      _ =
        ctx.sk_conn
        |> answer(slug, 1, q2["id"], %{"head" => head, "answer" => "choose", "option" => "b"})
        |> json_response(201)

      assert %{"state" => "mergeable", "review" => %{"items" => 3, "cleared" => 3}} =
               verdict(ctx.sk_conn, slug, 1)
    end

    test "blocked stays blocked with every item approved", ctx do
      slug = ctx.project.slug
      head = sha(1)
      one_way!(ctx, head)
      digest = intent_set!(ctx, intent_fm("add-export", [scenario("S1")]))
      doc = run_doc(digest, "intent", head, [result("S1", "failed")])

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{slug}/verify-runs", doc)
        |> json_response(201)

      packet = packet(ctx.sk_conn, slug, 1)
      assert [%{"rule" => "must_failed", "subject" => ["intent", "S1"]}] = packet["blocked"]
      door = item!(packet, "one_way_door")

      _ =
        ctx.sk_conn
        |> answer(slug, 1, door["id"], %{"head" => head, "answer" => "approve"})
        |> json_response(201)

      assert verdict(ctx.sk_conn, slug, 1)["state"] == "blocked"
    end

    test "pending clears at the same head without new answers", ctx do
      slug = ctx.project.slug
      policy!(ctx.sk_conn, slug, %{"evidence" => %{"required_workflows" => ["ci"]}})
      head = sha(1)
      one_way!(ctx, head)
      door = item!(packet(ctx.sk_conn, slug, 1), "one_way_door")

      _ =
        ctx.sk_conn
        |> answer(slug, 1, door["id"], %{"head" => head, "answer" => "approve"})
        |> json_response(201)

      assert verdict(ctx.sk_conn, slug, 1)["state"] == "pending"

      assert ctx.sk_conn
             |> post_json("/api/v1/projects/#{slug}/workflow-runs", run_document(head, "passed"))
             |> json_response(201)

      assert verdict(ctx.sk_conn, slug, 1)["state"] == "mergeable"
    end
  end

  describe "tasks" do
    setup ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)

      one_way!(ctx, sha(1), %{
        "questions" => [
          %{"id" => "q1", "text" => "?", "options" => ["a"], "recommendation" => "a"}
        ]
      })

      packet = packet(ctx.sk_conn, slug, 1)

      for item <- packet["items"] do
        ctx.sk_conn
        |> answer(slug, 1, item["id"], %{
          "head" => sha(1),
          "answer" => "request_change",
          "note" => item["kind"]
        })
        |> json_response(201)
      end

      :ok
    end

    test "list, filter, complete idempotently, and refuse bad input", ctx do
      slug = ctx.project.slug
      body = ctx.sk_conn |> get(cr_path(slug, 1, "/tasks")) |> json_response(200)
      assert_schema(body, "ReviewTaskListResponse", ApiSpec.spec())
      [first, second] = body["data"]

      done =
        ctx.sk_conn |> post(cr_path(slug, 1, "/tasks/#{first["id"]}/done")) |> json_response(200)

      assert_schema(done, "ReviewTaskResponse", ApiSpec.spec())
      assert %{"state" => "done", "done_at" => done_at} = done["data"]
      assert done_at

      again =
        ctx.sk_conn |> post(cr_path(slug, 1, "/tasks/#{first["id"]}/done")) |> json_response(200)

      assert again["data"]["done_at"] == done_at

      # A new head makes the other task stale and keeps its head.
      one_way!(ctx, sha(2))
      task = Repo.get!(Task, second["id"])
      assert task.state == "stale"
      assert task.head == sha(1)

      _ =
        ctx.sk_conn
        |> answer(slug, 1, item!(packet(ctx.sk_conn, slug, 1), "one_way_door")["id"], %{
          "head" => sha(2),
          "answer" => "request_change",
          "note" => "third"
        })
        |> json_response(201)

      # Without `state`: the open and stale tasks, oldest first, not the done one.
      assert [%{"id" => stale_id, "state" => "stale"}, %{"state" => "open", "note" => "third"}] =
               ctx.sk_conn
               |> get(cr_path(slug, 1, "/tasks"))
               |> json_response(200)
               |> Map.fetch!("data")

      assert stale_id == second["id"]

      assert [%{"state" => "done"}] =
               ctx.sk_conn
               |> get(cr_path(slug, 1, "/tasks"), %{"state" => "done"})
               |> json_response(200)
               |> Map.fetch!("data")

      assert %{"errors" => %{"state" => _}} =
               ctx.sk_conn
               |> get(cr_path(slug, 1, "/tasks"), %{"state" => "closed"})
               |> json_response(422)

      assert ctx.sk_conn
             |> post(cr_path(slug, 1, "/tasks/#{Ecto.UUID.generate()}/done"))
             |> json_response(404)

      assert ctx.sk_conn |> post(cr_path(slug, 1, "/tasks/nope/done")) |> json_response(404)

      assert ctx.pk_conn
             |> post(cr_path(slug, 1, "/tasks/#{first["id"]}/done"))
             |> json_response(403)

      assert ctx.sk_conn |> get(cr_path(slug, 999, "/tasks")) |> json_response(404)
    end
  end
end
