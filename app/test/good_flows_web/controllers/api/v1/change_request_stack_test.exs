defmodule GoodFlowsWeb.Api.V1.ChangeRequestStackTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.MergeFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.ChangeRequests
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    %{project: project, slug: project.slug}
  end

  defp show(ctx, number),
    do: ctx.sk_conn |> get(cr_path(ctx.slug, number)) |> json_response(200) |> Map.fetch!("data")

  defp move(ctx, number, action),
    do: ctx.sk_conn |> post(cr_path(ctx.slug, number, "/#{action}")) |> json_response(200)

  describe "parent routes" do
    setup ctx do
      for _ <- 1..3, do: create_cr(ctx.sk_conn, ctx.slug)
      :ok
    end

    test "set, replace and clear", ctx do
      body = ctx.sk_conn |> put_parent(ctx.slug, 3, 1) |> json_response(200)
      assert_schema(body, "ChangeRequestResponse", ApiSpec.spec())
      assert body["data"]["parent"] == 1

      assert ctx.sk_conn |> put_parent(ctx.slug, 3, 2) |> json_response(200)
      assert show(ctx, 3)["parent"] == 2

      list = ctx.sk_conn |> get(crs_path(ctx.slug)) |> json_response(200)
      assert Enum.find(list["data"], &(&1["number"] == 3))["parent"] == 2

      body = ctx.sk_conn |> delete(cr_path(ctx.slug, 3, "/parent")) |> json_response(200)
      assert body["data"]["parent"] == nil
      assert show(ctx, 1)["parent"] == nil
    end

    test "higher, equal and unknown numbers are 422 on number", ctx do
      for parent <- [3, 2, 7] do
        assert %{"errors" => %{"number" => _}} =
                 ctx.sk_conn |> put_parent(ctx.slug, 2, parent) |> json_response(422)
      end

      assert %{"errors" => %{"number" => _}} =
               ctx.sk_conn
               |> put_json(cr_path(ctx.slug, 2, "/parent"), %{"number" => "1"})
               |> json_response(422)

      assert show(ctx, 2)["parent"] == nil
    end

    test "a merged or closed child is 409 not_editable", ctx do
      assert ctx.sk_conn |> merged(ctx.slug, 3, sha(500)) |> json_response(200)

      body = ctx.sk_conn |> put_parent(ctx.slug, 3, 1) |> json_response(409)
      assert_schema(body, "CodedConflictResponse", ApiSpec.spec())
      assert body["errors"]["error"] == "not_editable"

      assert %{"errors" => %{"error" => "not_editable"}} =
               ctx.sk_conn |> delete(cr_path(ctx.slug, 3, "/parent")) |> json_response(409)

      assert show(ctx, 3)["parent"] == nil
    end

    test "pk_ and ck_ keys are 403, no key 401, unknown 404, other accounts 404", ctx do
      owner = Repo.preload(ctx.sk_key, :account_user).account_user
      {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read_write"})

      for conn <- [ctx.pk_conn, api_conn(ck)] do
        assert conn |> put_parent(ctx.slug, 3, 1) |> json_response(403)
        assert conn |> delete(cr_path(ctx.slug, 3, "/parent")) |> json_response(403)
        assert conn |> retarget(ctx.slug, 3, "dev") |> json_response(403)
      end

      assert build_conn() |> put_parent(ctx.slug, 3, 1) |> json_response(401)
      assert ctx.sk_conn |> put_parent(ctx.slug, 99, 1) |> json_response(404)
      assert ctx.other_conn |> retarget(ctx.slug, 3, "dev") |> json_response(404)

      assert_error_sent(406, fn ->
        ctx.sk_conn |> accept("text/plain") |> put_parent(ctx.slug, 3, 1)
      end)

      assert show(ctx, 3)["parent"] == nil
    end
  end

  describe "parent verdict rules" do
    setup ctx do
      parent = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      child = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      assert ctx.sk_conn |> put_parent(ctx.slug, child, parent) |> json_response(200)
      %{parent: parent, child: child}
    end

    test "open parent: pending parent_not_merged with the number as a string", ctx do
      v = verdict(ctx.sk_conn, ctx.slug, ctx.child)
      assert v["state"] == "pending"
      assert [%{"subject" => [subject]}] = reasons(v, "parent_not_merged")
      assert subject == Integer.to_string(ctx.parent)
    end

    test "other reasons are kept", ctx do
      facts!(ctx.sk_conn, ctx.slug, ctx.child, sha(3),
        files: [file("app/priv/repo/migrations/1.exs")]
      )

      claims!(ctx.sk_conn, ctx.slug, ctx.child, sha(3), %{"cr" => ctx.child})
      v = verdict(ctx.sk_conn, ctx.slug, ctx.child)
      assert "parent_not_merged" in rules(v)
      assert "path_match" in rules(v)
    end

    test "closed, reopened, merged and cleared", ctx do
      move(ctx, ctx.parent, "close")
      v = verdict(ctx.sk_conn, ctx.slug, ctx.child)
      assert rules(v) == ["parent_closed"]
      assert [%{"subject" => [_number]}] = reasons(v, "parent_closed")

      move(ctx, ctx.parent, "reopen")
      assert rules(verdict(ctx.sk_conn, ctx.slug, ctx.child)) == ["parent_not_merged"]

      move(ctx, ctx.parent, "close")
      assert ctx.sk_conn |> delete(cr_path(ctx.slug, ctx.child, "/parent")) |> json_response(200)
      assert verdict(ctx.sk_conn, ctx.slug, ctx.child)["state"] == "mergeable"

      move(ctx, ctx.parent, "reopen")
      assert ctx.sk_conn |> put_parent(ctx.slug, ctx.child, ctx.parent) |> json_response(200)
      assert ctx.sk_conn |> merged(ctx.slug, ctx.parent, sha(500)) |> json_response(200)
      assert verdict(ctx.sk_conn, ctx.slug, ctx.child)["state"] == "mergeable"
    end
  end

  describe "retarget" do
    test "after the parent merges, to its target: 200, head unchanged, facts missing", ctx do
      parent = mergeable!(ctx.sk_conn, ctx.slug, sha(1))

      child =
        mergeable!(ctx.sk_conn, ctx.slug, sha(2),
          attrs: %{"target_branch" => "feat/a"},
          target: "feat/a"
        )

      assert ctx.sk_conn |> put_parent(ctx.slug, child, parent) |> json_response(200)

      assert %{"errors" => %{"error" => "parent_not_merged"}} =
               ctx.sk_conn |> retarget(ctx.slug, child, "main") |> json_response(409)

      assert show(ctx, child)["target_branch"] == "feat/a"

      assert ctx.sk_conn |> merged(ctx.slug, parent, sha(500)) |> json_response(200)

      assert %{"errors" => %{"target_branch" => _}} =
               ctx.sk_conn |> retarget(ctx.slug, child, "develop") |> json_response(422)

      body = ctx.sk_conn |> retarget(ctx.slug, child, "main") |> json_response(200)
      assert_schema(body, "ChangeRequestResponse", ApiSpec.spec())
      assert %{"target_branch" => "main", "head" => head} = body["data"]
      assert head == sha(2)

      v = verdict(ctx.sk_conn, ctx.slug, child)
      assert v["state"] == "pending" and v["head"] == sha(2)
      assert [%{"subject" => [subject]}] = reasons(v, "git_facts_missing")
      assert subject == sha(2)

      conn = post_json(ctx.sk_conn, cr_path(ctx.slug, child, "/git-facts"), git_facts(sha(2)))
      assert json_response(conn, 201)
      assert verdict(ctx.sk_conn, ctx.slug, child)["state"] == "mergeable"
    end

    test "without a parent any branch; a held lease is lease_held; merged is not_editable",
         ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      lease = acquire!(ctx.sk_conn, ctx.slug, number, sha(1), sha(0))

      assert %{"errors" => %{"error" => "lease_held"}} =
               ctx.sk_conn |> retarget(ctx.slug, number, "release/1.2") |> json_response(409)

      assert show(ctx, number)["target_branch"] == "main"
      assert ctx.sk_conn |> release(ctx.slug, lease["id"]) |> response(204)

      assert %{"data" => %{"target_branch" => "release/1.2"}} =
               ctx.sk_conn |> retarget(ctx.slug, number, "release/1.2") |> json_response(200)

      assert %{"errors" => %{"target_branch" => _}} =
               ctx.sk_conn
               |> post_json(cr_path(ctx.slug, number, "/retarget"), %{"target_branch" => ""})
               |> json_response(422)

      assert ctx.sk_conn |> merged(ctx.slug, number, sha(500)) |> json_response(200)

      assert %{"errors" => %{"error" => "not_editable"}} =
               ctx.sk_conn |> retarget(ctx.slug, number, "main") |> json_response(409)
    end

    test "a parent link changed after the read restarts the transaction on fresh rows", ctx do
      parent = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      child = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      {:ok, stale} = ChangeRequests.get(ctx.project, child)

      assert ctx.sk_conn |> put_parent(ctx.slug, child, parent) |> json_response(200)

      assert {:error, {:coded_conflict, "parent_not_merged", %{}}} =
               ChangeRequests.retarget(stale, ctx.sk_key, %{"target_branch" => "main"})

      {:ok, stale} = ChangeRequests.get(ctx.project, child)
      assert ctx.sk_conn |> delete(cr_path(ctx.slug, child, "/parent")) |> json_response(200)

      assert {:ok, %{target_branch: "develop", parent_id: nil}} =
               ChangeRequests.retarget(stale, ctx.sk_key, %{"target_branch" => "develop"})
    end

    test "answers at the head survive; a new item needs its own answer", ctx do
      number = create_cr(ctx.sk_conn, ctx.slug, %{"target_branch" => "feat/a"})["number"]
      move(ctx, number, "ready")
      facts!(ctx.sk_conn, ctx.slug, number, sha(1), target: "feat/a")
      claims!(ctx.sk_conn, ctx.slug, number, sha(1), %{"cr" => number, "door" => "one_way"})

      door = item!(packet(ctx.sk_conn, ctx.slug, number), "one_way_door")

      assert ctx.sk_conn
             |> answer(ctx.slug, number, door["id"], %{"head" => sha(1), "answer" => "approve"})
             |> json_response(201)

      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "mergeable"

      assert ctx.sk_conn |> retarget(ctx.slug, number, "main") |> json_response(200)
      facts!(ctx.sk_conn, ctx.slug, number, sha(1))
      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "mergeable"
      assert item!(packet(ctx.sk_conn, ctx.slug, number), "one_way_door")["answer"]

      many = for i <- 1..41, do: file("lib/f#{i}.ex")
      assert ctx.sk_conn |> retarget(ctx.slug, number, "develop") |> json_response(200)
      facts!(ctx.sk_conn, ctx.slug, number, sha(1), target: "develop", files: many)

      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "needs_review"
      size = item!(packet(ctx.sk_conn, ctx.slug, number), "size")
      assert size["answer"] == nil

      assert ctx.sk_conn
             |> answer(ctx.slug, number, size["id"], %{"head" => sha(1), "answer" => "approve"})
             |> json_response(201)

      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "mergeable"
    end
  end
end
