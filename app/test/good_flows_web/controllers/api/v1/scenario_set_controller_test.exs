defmodule GoodFlowsWeb.Api.V1.ScenarioSetControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.Repo
  alias GoodFlows.ScenarioSets.{Decision, Version}
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    cr = create_cr(ctx.sk_conn, project.slug, %{"change_id" => "add-export"})
    %{project: project, number: cr["number"]}
  end

  defp sets_path(ctx, suffix \\ ""),
    do: cr_path(ctx.project.slug, ctx.number, "/scenario-sets" <> suffix)

  defp upload(conn, ctx, body), do: post_json(conn, sets_path(ctx), body)

  defp count(schema), do: Repo.aggregate(schema, :count)

  test "sk_ uploads and approves, pk_ reads, pk_ and ck_ are refused", ctx do
    body = set_body(intent_fm("add-export"))

    assert ctx.pk_conn |> upload(ctx, body) |> json_response(403)
    assert count(Version) == 0

    created = ctx.sk_conn |> upload(ctx, body) |> json_response(201)
    assert_schema(created, "ScenarioSetVersionResponse", ApiSpec.spec())

    assert %{"version" => 1, "source" => "intent", "approved" => false, "duplicate" => false} =
             created["data"]

    digest = created["data"]["digest"]
    assert digest == digest_of(body)

    assert ctx.pk_conn
           |> post_json(sets_path(ctx, "/intent/approvals"), %{"digest" => digest})
           |> json_response(403)

    list = ctx.pk_conn |> get(sets_path(ctx)) |> json_response(200)
    assert_schema(list, "ScenarioSetListResponse", ApiSpec.spec())

    assert [%{"version" => 1, "digest" => ^digest, "approved" => false}] =
             list["data"]["intent"]["versions"]

    assert list["data"]["diff"] == %{"current" => nil, "versions" => []}

    owner = Repo.preload(ctx.sk_key, :account_user).account_user
    {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read_write"})
    assert api_conn(ck) |> get(sets_path(ctx)) |> json_response(403)
    assert api_conn(ck) |> upload(ctx, body) |> json_response(403)

    assert build_conn()
           |> put_req_header("accept", "application/json")
           |> get(sets_path(ctx))
           |> json_response(401)
  end

  test "unknown change request is 404 before the body is read", ctx do
    path = cr_path(ctx.project.slug, 999, "/scenario-sets")
    assert ctx.sk_conn |> post_json(path, "{") |> json_response(404)
    assert ctx.sk_conn |> get(path) |> json_response(404)
  end

  test "body rules: 413, 415, 400, unknown key 422", ctx do
    big = Jason.encode!(%{"content" => String.duplicate("a", 1_048_577 - 28), "sections" => []})
    assert byte_size(big) == 1_048_577
    assert ctx.sk_conn |> upload(ctx, big) |> json_response(413)

    conn =
      ctx.sk_conn
      |> put_req_header("content-type", "text/plain")
      |> post(sets_path(ctx), "x")

    assert json_response(conn, 415)
    assert ctx.sk_conn |> upload(ctx, "{") |> json_response(400)

    body = Map.put(set_body(intent_fm("add-export")), "digest", "x")

    assert %{"errors" => %{"body" => ["has an unknown field"]}} =
             ctx.sk_conn |> upload(ctx, body) |> json_response(422)

    assert count(Version) == 0
  end

  test "closed change requests: upload and approve are 409; reads work", ctx do
    body = set_body(intent_fm("add-export"))
    digest = ctx.sk_conn |> upload(ctx, body) |> json_response(201) |> get_in(["data", "digest"])

    ctx.sk_conn
    |> post_json(cr_path(ctx.project.slug, ctx.number, "/close"), %{})
    |> json_response(200)

    edited = set_body(intent_fm("add-export"), body: "edited\n")
    assert ctx.sk_conn |> upload(ctx, edited) |> json_response(409)

    assert ctx.sk_conn
           |> post_json(sets_path(ctx, "/intent/approvals"), %{"digest" => digest})
           |> json_response(409)

    assert count(Decision) == 0
    assert ctx.sk_conn |> get(sets_path(ctx, "/intent/versions/1")) |> json_response(200)
  end

  test "accepted: intent equals approved; a diff version is accepted through answers", ctx do
    intent = ctx.sk_conn |> upload(ctx, set_body(intent_fm("add-export"))) |> json_response(201)
    assert %{"approved" => false, "accepted" => false} = intent["data"]
    d1 = intent["data"]["digest"]

    _ =
      ctx.sk_conn
      |> post_json(sets_path(ctx, "/intent/approvals"), %{"digest" => d1})
      |> json_response(201)

    assert %{"approved" => true, "accepted" => true} =
             ctx.sk_conn
             |> get(sets_path(ctx, "/intent/versions/1"))
             |> json_response(200)
             |> Map.fetch!("data")

    slug = ctx.project.slug

    _ =
      ctx.sk_conn
      |> put_json("/api/v1/projects/#{slug}/review-policy", %{
        "previous_version" => 0,
        "policy" => %{
          "format" => "review-policy/1",
          "scenarios" => %{"require_approved_intent" => true, "diff_only" => "weakening"}
        }
      })
      |> json_response(201)

    diff = create_cr(ctx.sk_conn, slug)
    dctx = %{ctx | number: diff["number"]}
    head = sha(1)

    _ =
      ctx.sk_conn
      |> post_json(cr_path(slug, dctx.number, "/git-facts"), git_facts(head))
      |> json_response(201)

    _ =
      ctx.sk_conn
      |> post_markdown(cr_path(slug, dctx.number, "/claims"), claims(front_matter(head)))
      |> json_response(201)

    _ =
      ctx.sk_conn
      |> upload(dctx, set_body(diff_fm(head, [scenario("S1"), scenario("S3")])))
      |> json_response(201)

    v2 =
      ctx.sk_conn
      |> upload(dctx, set_body(diff_fm(head, [scenario("S1"), scenario("S3", "should")])))
      |> json_response(201)

    assert_schema(v2, "ScenarioSetVersionResponse", ApiSpec.spec())
    assert %{"approved" => false, "accepted" => false, "source" => "diff"} = v2["data"]
    d2 = v2["data"]["digest"]

    run = run_doc(d2, "diff", head, [result("S1"), result("S3")])

    _ =
      ctx.sk_conn |> post_json("/api/v1/projects/#{slug}/verify-runs", run) |> json_response(201)

    assert ctx.sk_conn
           |> post_json(sets_path(dctx, "/diff/approvals"), %{"digest" => d2})
           |> json_response(404)

    assert count(Decision) == 1

    [item] =
      ctx.sk_conn
      |> get(cr_path(slug, dctx.number, "/review"))
      |> json_response(200)
      |> get_in(["data", "items"])

    _ =
      ctx.sk_conn
      |> post_json(cr_path(slug, dctx.number, "/review/items/#{item["id"]}/answers"), %{
        "head" => head,
        "answer" => "approve"
      })
      |> json_response(201)

    docs_only = %{
      "format" => "git-facts/1",
      "head" => sha(2),
      "target" => %{"branch" => "main", "merge_base" => sha(0)},
      "commits" => [
        %{"sha" => head, "parents" => [sha(0)], "changed_files" => [file("lib/a.ex")]},
        %{"sha" => sha(2), "parents" => [head], "changed_files" => [file("docs/usage.md")]}
      ],
      "diff" => %{"files" => [file("lib/a.ex"), file("docs/usage.md")]}
    }

    _ =
      ctx.sk_conn
      |> post_json(cr_path(slug, dctx.number, "/git-facts"), docs_only)
      |> json_response(201)

    shown = ctx.sk_conn |> get(sets_path(dctx, "/diff/versions/2")) |> json_response(200)
    assert_schema(shown, "ScenarioSetVersionResponse", ApiSpec.spec())

    assert %{"approved" => false, "accepted" => true, "decisions" => [decision]} = shown["data"]
    assert %{"decision" => "approve", "channel" => "cli", "digest" => ^d2} = decision

    list = ctx.pk_conn |> get(sets_path(dctx)) |> json_response(200)
    assert_schema(list, "ScenarioSetListResponse", ApiSpec.spec())

    assert [%{"version" => 2, "accepted" => true, "approved" => false}, %{"accepted" => false}] =
             list["data"]["diff"]["versions"]

    assert %{"accepted" => true, "content" => nil} = list["data"]["diff"]["current"]
  end

  test "duplicate upload is 200; versions; missing version 404", ctx do
    body = set_body(intent_fm("add-export"), body: "# A\r\n  \r\n")
    ctx.sk_conn |> upload(ctx, body) |> json_response(201)

    assert %{"data" => %{"duplicate" => true, "version" => 1}} =
             ctx.sk_conn |> upload(ctx, body) |> json_response(200)

    shown = ctx.sk_conn |> get(sets_path(ctx, "/intent/versions/1")) |> json_response(200)
    assert shown["data"]["content"] == body["content"]
    assert ctx.sk_conn |> get(sets_path(ctx, "/intent/versions/2")) |> json_response(404)
    assert ctx.sk_conn |> get(sets_path(ctx, "/diff/versions/1")) |> json_response(404)
    assert ctx.sk_conn |> get(sets_path(ctx, "/other/versions/1")) |> json_response(404)
  end

  test "approve, repeat, reject, stale; pk_ redaction; diff decisions 404", ctx do
    body = set_body(intent_fm("add-export"))
    d1 = ctx.sk_conn |> upload(ctx, body) |> json_response(201) |> get_in(["data", "digest"])

    approval =
      ctx.sk_conn
      |> post_json(sets_path(ctx, "/intent/approvals"), %{"digest" => d1})
      |> json_response(201)

    assert_schema(approval, "ScenarioSetDecisionResponse", ApiSpec.spec())
    user_id = Repo.preload(ctx.sk_key, :account_user).account_user.user_id

    assert %{
             "decision" => "approve",
             "digest" => ^d1,
             "note" => nil,
             "decided_by" => %{"user_id" => ^user_id},
             "channel" => "cli"
           } = approval["data"]

    assert ctx.sk_conn
           |> post_json(sets_path(ctx, "/intent/approvals"), %{"digest" => d1})
           |> json_response(200)

    assert count(Decision) == 1

    assert %{"errors" => %{"note" => _}} =
             ctx.sk_conn
             |> post_json(sets_path(ctx, "/intent/rejections"), %{"digest" => d1})
             |> json_response(422)

    rejection =
      ctx.member_sk_conn
      |> post_json(sets_path(ctx, "/intent/rejections"), %{"digest" => d1, "note" => "wrong path"})
      |> json_response(201)

    assert rejection["data"]["note"] == "wrong path"

    assert ctx.sk_conn
           |> post_json(sets_path(ctx, "/intent/approvals"), %{
             "digest" => String.duplicate("b", 64)
           })
           |> json_response(409)

    for action <- ~w(approvals rejections) do
      assert ctx.sk_conn
             |> post_json(sets_path(ctx, "/diff/#{action}"), %{"digest" => d1, "note" => "n"})
             |> json_response(404)
    end

    pk = ctx.pk_conn |> get(sets_path(ctx, "/intent/versions/1")) |> json_response(200)
    assert_schema(pk, "ScenarioSetVersionResponse", ApiSpec.spec())

    assert %{
             "content" => nil,
             "sections" => nil,
             "front_matter" => nil,
             "approved" => false,
             "version" => 1,
             "digest" => ^d1,
             "scenarios" => [
               %{"id" => "S1", "priority" => "must"},
               %{"id" => "S2", "priority" => "should"}
             ],
             "decisions" => [first, second]
           } = pk["data"]

    assert first["decided_by"] == %{"user_id" => nil}
    assert second["note"] == nil

    sk = ctx.sk_conn |> get(sets_path(ctx, "/intent/versions/1")) |> json_response(200)
    assert sk["data"]["content"] == body["content"]
    assert length(sk["data"]["sections"]) == 2
    assert Enum.at(sk["data"]["decisions"], 1)["note"] == "wrong path"
  end

  test "compare lists changes", ctx do
    ctx.sk_conn
    |> upload(ctx, set_body(intent_fm("add-export", [scenario("S1")])))
    |> json_response(201)

    cmp = ctx.pk_conn |> get(sets_path(ctx, "/intent/compare")) |> json_response(200)
    assert_schema(cmp, "ScenarioSetCompareResponse", ApiSpec.spec())

    assert %{"from" => nil, "to" => 1, "changes" => [%{"id" => "S1", "change" => "added"}]} =
             cmp["data"]

    assert ctx.sk_conn |> get(sets_path(ctx, "/intent/compare?to=abc")) |> json_response(422)
  end

  test "approver other_member is enforced through the API", ctx do
    admin_key = ctx.sk_key
    owner = Repo.preload(admin_key, :account_user).account_user

    {:ok, :created, _} =
      GoodFlows.ReviewPolicies.write(ctx.project, owner, admin_key, %{
        "previous_version" => 0,
        "policy" => %{
          "format" => "review-policy/1",
          "scenarios" => %{"approver" => "other_member"}
        }
      })

    d1 =
      ctx.sk_conn
      |> upload(ctx, set_body(intent_fm("add-export")))
      |> json_response(201)
      |> get_in(["data", "digest"])

    assert ctx.sk_conn
           |> post_json(sets_path(ctx, "/intent/approvals"), %{"digest" => d1})
           |> json_response(403)

    assert ctx.member_sk_conn
           |> post_json(sets_path(ctx, "/intent/approvals"), %{"digest" => d1})
           |> json_response(201)
  end
end
