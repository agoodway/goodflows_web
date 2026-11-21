defmodule GoodFlowsWeb.Api.V1.ChangeRequestFlowTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.WorkflowRunFixtures

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  test "create, facts, claims, a passing ci run, policy, ready, mergeable, merge", ctx do
    slug = ctx.project.slug
    head = sha(1)

    cr = create_cr(ctx.sk_conn, slug)
    assert %{"number" => 1, "state" => "draft", "head" => nil, "merge" => nil} = cr

    assert ctx.sk_conn
           |> post_json(cr_path(slug, 1, "/git-facts"), git_facts(head))
           |> json_response(201)
           |> get_in(["data", "head"]) == head

    claims = claims(front_matter(head, %{"cr" => 1}))

    assert ctx.sk_conn
           |> post_markdown(cr_path(slug, 1, "/claims"), claims)
           |> json_response(201)
           |> get_in(["data", "description"]) == claims

    run =
      minimal()
      |> Map.put("workflow", "ci")
      |> Map.put("source", %{"commit" => head})

    assert ctx.sk_conn
           |> post_json("/api/v1/projects/#{slug}/workflow-runs", run)
           |> json_response(201)

    policy = %{
      "previous_version" => 0,
      "policy" => %{
        "format" => "review-policy/1",
        "evidence" => %{"required_workflows" => ["ci"]}
      },
      "note" => "Require ci"
    }

    assert %{"data" => %{"version" => 1}} =
             ctx.sk_conn
             |> put_json("/api/v1/projects/#{slug}/review-policy", policy)
             |> json_response(201)

    assert ctx.sk_conn
           |> post(cr_path(slug, 1, "/ready"))
           |> json_response(200)
           |> get_in(["data", "state"]) == "open"

    verdict = ctx.sk_conn |> get(cr_path(slug, 1, "/verdict")) |> json_response(200)

    assert %{"state" => "mergeable", "reasons" => [], "head" => ^head, "policy_version" => 1} =
             verdict["data"]

    merged =
      ctx.sk_conn
      |> post_json(cr_path(slug, 1, "/merged"), %{
        "merged_commit" => sha(2),
        "target_branch" => "main"
      })
      |> json_response(200)

    assert %{
             "state" => "merged",
             "merge" => %{
               "verdict_state" => "mergeable",
               "merged_without_mergeable_verdict" => false,
               "head" => ^head,
               "policy_version" => 1
             }
           } = merged["data"]

    assert [%{"to_state" => "open"}, %{"to_state" => "merged"}] = merged["data"]["history"]
  end
end
