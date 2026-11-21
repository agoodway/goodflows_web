defmodule GoodFlowsWeb.Api.V1.ChangeRequestGradingFlowTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  defp policy!(ctx, settings) do
    policy = %{
      "previous_version" => 0,
      "policy" => Map.merge(%{"format" => "review-policy/1"}, settings)
    }

    ctx.sk_conn
    |> put_json("/api/v1/projects/#{ctx.project.slug}/review-policy", policy)
    |> json_response(201)
  end

  defp verdict(conn, ctx),
    do: conn |> get(cr_path(ctx.project.slug, 1, "/verdict")) |> json_response(200)

  test "open, facts, claims, approved set, index, run with artifact, mergeable", ctx do
    slug = ctx.project.slug
    head = sha(1)

    policy!(ctx, %{
      "scenarios" => %{"require_approved_intent" => true},
      "coverage" => %{"unmapped_areas" => "needs_review", "undriven_features" => "needs_review"}
    })

    _ = create_cr(ctx.sk_conn, slug, %{"openspec_change" => "add-export"})

    _ =
      ctx.sk_conn
      |> post_json(cr_path(slug, 1, "/git-facts"), git_facts(head))
      |> json_response(201)

    _ =
      ctx.sk_conn
      |> post_markdown(cr_path(slug, 1, "/claims"), claims(front_matter(head, %{"cr" => 1})))
      |> json_response(201)

    digest =
      ctx.sk_conn
      |> post_json(cr_path(slug, 1, "/scenario-sets"), set_body(intent_fm("add-export")))
      |> json_response(201)
      |> get_in(["data", "digest"])

    _ =
      ctx.sk_conn
      |> post_json(cr_path(slug, 1, "/scenario-sets/intent/approvals"), %{"digest" => digest})
      |> json_response(201)

    _ =
      ctx.sk_conn
      |> post_json("/api/v1/projects/#{slug}/feature-index", %{
        "features" => [feature("export", ["lib/**"])]
      })
      |> json_response(201)

    _ = ctx.sk_conn |> post(cr_path(slug, 1, "/ready")) |> json_response(200)

    pending = verdict(ctx.sk_conn, ctx)["data"]
    assert %{"rule" => "scenario_results_missing"} = hd(pending["reasons"])
    assert pending["counted_runs"] == []

    shot = "png bytes"

    doc =
      run_doc(digest, "intent", head, [result("S1"), result("S2", "passed")],
        features: [%{"id" => "export", "entry_point" => "/export", "result" => "passed"}],
        artifacts: [artifact("shot-1", shot)]
      )

    runs = "/api/v1/projects/#{slug}/verify-runs"
    ack = ctx.sk_conn |> post_json(runs, doc) |> json_response(201)
    assert %{"status" => "uploading", "uploads" => [upload]} = ack["data"]
    assert verdict(ctx.sk_conn, ctx)["data"]["counted_runs"] == []

    :ok = Fake.put(upload["upload_url"], upload["upload_headers"], shot)

    assert ctx.sk_conn
           |> post_json(runs <> "/#{doc["run_id"]}/commit", %{})
           |> json_response(200)
           |> get_in(["data", "status"]) == "final"

    sk = verdict(ctx.sk_conn, ctx)
    assert_schema(sk, "VerdictResponse", ApiSpec.spec())

    assert %{"state" => state, "counted_runs" => [run_id], "head" => ^head} = sk["data"]
    assert state in ["mergeable", "needs_review"]
    assert run_id == doc["run_id"]
    assert sk["data"]["scenarios"]["intent"]["digest"] == digest

    assert sk["data"]["coverage"] == %{
             "version" => 1,
             "unmapped_areas" => [],
             "features" => [%{"id" => "export", "driven" => true}]
           }
  end

  describe "diff-only weakening" do
    setup ctx do
      policy!(ctx, %{
        "scenarios" => %{"require_approved_intent" => true, "diff_only" => "weakening"}
      })

      _ = create_cr(ctx.sk_conn, ctx.project.slug)
      :ok
    end

    defp upload_diff!(ctx, scenarios, body \\ "# QA scenarios\n") do
      ctx.sk_conn
      |> post_json(
        cr_path(ctx.project.slug, 1, "/scenario-sets"),
        set_body(diff_fm(sha(1), scenarios), body: body)
      )
      |> json_response(201)
      |> get_in(["data", "digest"])
    end

    test "the verdict reads the diff baseline and acceptance", ctx do
      slug = ctx.project.slug
      head = sha(1)

      _ =
        ctx.sk_conn
        |> post_json(cr_path(slug, 1, "/git-facts"), git_facts(head))
        |> json_response(201)

      _ =
        ctx.sk_conn
        |> post_markdown(cr_path(slug, 1, "/claims"), claims(front_matter(head, %{"cr" => 1})))
        |> json_response(201)

      d1 = upload_diff!(ctx, [scenario("S1"), scenario("S3")])
      d2 = upload_diff!(ctx, [scenario("S1"), scenario("S3", "should")])

      sk = verdict(ctx.sk_conn, ctx)
      assert_schema(sk, "VerdictResponse", ApiSpec.spec())
      reasons = Enum.map(sk["data"]["reasons"], &{&1["rule"], &1["subject"]})
      assert {"diff_set_weakened", ["diff", "S3"]} in reasons
      refute Enum.any?(reasons, &match?({"diff_only_set", _}, &1))

      assert %{"version" => 2, "accepted" => false, "baseline_version" => 1, "approved" => false} =
               sk["data"]["scenarios"]["diff"]

      assert sk["data"]["inputs"]["diff_baseline_digest"] == d1

      cr =
        GoodFlows.Repo.get_by!(GoodFlows.ChangeRequests.ChangeRequest, project_id: ctx.project.id)

      GoodFlows.Repo.insert!(%GoodFlows.ScenarioSets.Decision{
        change_request_id: cr.id,
        digest: d2,
        decision: "approve",
        channel: "cli",
        account_user_id: ctx.sk_key.account_user_id,
        api_key_id: ctx.sk_key.id
      })

      _ = upload_diff!(ctx, [scenario("S1"), scenario("S3", "should")], "# v3\n")
      _ = upload_diff!(ctx, [scenario("S1"), scenario("S3", "should")], "# v4\n")

      sk = verdict(ctx.sk_conn, ctx)
      assert_schema(sk, "VerdictResponse", ApiSpec.spec())

      assert %{"version" => 4, "accepted" => false, "baseline_version" => 2} =
               sk["data"]["scenarios"]["diff"]

      assert sk["data"]["inputs"]["diff_baseline_digest"] == d2
      refute Enum.any?(sk["data"]["reasons"], &(&1["rule"] == "diff_set_weakened"))
    end

    defp new_head!(ctx, head) do
      slug = ctx.project.slug

      _ =
        ctx.sk_conn
        |> post_json(cr_path(slug, 1, "/git-facts"), git_facts(head))
        |> json_response(201)

      _ =
        ctx.sk_conn
        |> post_markdown(cr_path(slug, 1, "/claims"), claims(front_matter(head, %{"cr" => 1})))
        |> json_response(201)
    end

    defp diff_run!(ctx, revision, scenarios, commit) do
      digest =
        ctx.sk_conn
        |> post_json(
          cr_path(ctx.project.slug, 1, "/scenario-sets"),
          set_body(diff_fm(revision, scenarios))
        )
        |> json_response(201)
        |> get_in(["data", "digest"])

      doc = run_doc(digest, "diff", commit, Enum.map(scenarios, &result(&1["id"])))

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{ctx.project.slug}/verify-runs", doc)
        |> json_response(201)

      {digest, doc["run_id"]}
    end

    test "end to end: pass, demote and accept, then push without new answers", ctx do
      slug = ctx.project.slug

      new_head!(ctx, sha(1))
      {_d1, r1} = diff_run!(ctx, sha(1), [scenario("S1"), scenario("S3")], sha(1))
      v1 = verdict(ctx.sk_conn, ctx)["data"]
      assert v1["state"] == "mergeable"
      assert v1["counted_runs"] == [r1]

      new_head!(ctx, sha(2))
      demoted = [scenario("S1"), scenario("S3", "should")]
      {d2, _r2} = diff_run!(ctx, sha(2), demoted, sha(2))
      v2 = verdict(ctx.sk_conn, ctx)["data"]
      assert v2["state"] == "needs_review"
      assert v2["scenarios"]["diff"]["baseline_version"] == 1

      packet = ctx.sk_conn |> get(cr_path(slug, 1, "/review")) |> json_response(200)
      assert [item] = packet["data"]["items"]
      assert %{"kind" => "diff_set_weakened", "subject" => ["diff", "S3"]} = item
      assert item["data"]["digest"] == d2

      _ =
        ctx.member_sk_conn
        |> post_json(cr_path(slug, 1, "/review/items/#{item["id"]}/answers"), %{
          "head" => sha(2),
          "answer" => "approve"
        })
        |> json_response(201)

      accepted = verdict(ctx.sk_conn, ctx)["data"]
      assert accepted["state"] == "mergeable"
      assert %{"accepted" => true, "baseline_version" => 2} = accepted["scenarios"]["diff"]

      new_head!(ctx, sha(3))
      assert verdict(ctx.sk_conn, ctx)["data"]["state"] == "pending"

      {_d3, r3} = diff_run!(ctx, sha(3), demoted, sha(3))
      v3 = verdict(ctx.sk_conn, ctx)
      assert_schema(v3, "VerdictResponse", ApiSpec.spec())

      assert %{"state" => "mergeable", "head" => head, "counted_runs" => [^r3]} = v3["data"]
      assert head == sha(3)

      assert %{"version" => 3, "accepted" => false, "baseline_version" => 2, "graded" => true} =
               v3["data"]["scenarios"]["diff"]

      assert v3["data"]["reasons"] == []
      assert v3["data"]["review"] == %{"items" => 0, "cleared" => 0}
    end
  end

  describe "verdict response" do
    setup ctx do
      policy!(ctx, %{
        "coverage" => %{"unmapped_areas" => "needs_review", "undriven_features" => "needs_review"}
      })

      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug, %{"openspec_change" => "add-export"})

      files = [file("lib/a.ex"), file("priv/b.sql")]

      _ =
        ctx.sk_conn
        |> post_json(cr_path(slug, 1, "/git-facts"), git_facts(sha(1), files: files))
        |> json_response(201)

      _ =
        ctx.sk_conn
        |> post_json("/api/v1/projects/#{slug}/feature-index", %{
          "features" => [feature("lib", ["lib/**"])]
        })
        |> json_response(201)

      :ok
    end

    test "sk_ sees coverage subjects and feature ids", ctx do
      sk = verdict(ctx.sk_conn, ctx)
      assert_schema(sk, "VerdictResponse", ApiSpec.spec())

      assert %{
               "scenarios" => %{"intent" => nil, "diff" => nil},
               "counted_runs" => [],
               "coverage" => %{
                 "version" => 1,
                 "unmapped_areas" => ["priv/b.sql"],
                 "features" => [%{"id" => "lib", "driven" => false}]
               }
             } = sk["data"]

      reasons = Enum.map(sk["data"]["reasons"], &{&1["rule"], &1["subject"]})
      assert {"unmapped_area", ["priv/b.sql"]} in reasons
      assert {"undriven_feature", ["lib"]} in reasons
      assert %{"feature_index_version" => 1} = sk["data"]["inputs"]
    end

    test "pk_ sees coverage redacted, keeping driven", ctx do
      pk = verdict(ctx.pk_conn, ctx)
      assert_schema(pk, "VerdictResponse", ApiSpec.spec())

      assert %{
               "version" => 1,
               "unmapped_areas" => nil,
               "features" => [%{"id" => nil, "driven" => false}]
             } = pk["data"]["coverage"]

      assert pk["data"]["counted_runs"] == []
      assert Enum.all?(pk["data"]["reasons"], &(&1["subject"] == nil and &1["message"] == nil))
    end
  end
end
