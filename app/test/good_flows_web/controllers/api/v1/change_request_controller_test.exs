defmodule GoodFlowsWeb.Api.V1.ChangeRequestControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.ChangeRequests.{ChangeRequest, Claims, GitFacts}
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account)}
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  defp facts!(ctx, number, head, opts \\ []) do
    ctx.sk_conn
    |> post_json(cr_path(ctx.project.slug, number, "/git-facts"), git_facts(head, opts))
    |> json_response(201)
  end

  defp claims!(ctx, number, raw) do
    ctx.sk_conn
    |> post_markdown(cr_path(ctx.project.slug, number, "/claims"), raw)
    |> json_response(201)
  end

  describe "auth and resolution" do
    test "sk_ creates, pk_ reads, pk_ and ck_ cannot write", ctx do
      slug = ctx.project.slug

      created =
        ctx.sk_conn
        |> post_json(crs_path(slug), %{"title" => "t", "source_branch" => "b"})
        |> json_response(201)

      assert_schema(created, "ChangeRequestResponse", ApiSpec.spec())

      list = ctx.pk_conn |> get(crs_path(slug)) |> json_response(200)
      assert_schema(list, "ChangeRequestListResponse", ApiSpec.spec())

      for {method, suffix, body} <- [
            {:post, "", "{"},
            {:post, "/1/git-facts", "{"},
            {:post, "/1/claims", "x"},
            {:post, "/1/ready", ""},
            {:post, "/1/close", ""},
            {:post, "/1/ready", "{"},
            {:post, "/1/draft", "{"},
            {:post, "/1/close", "{"},
            {:post, "/1/reopen", "{"},
            {:post, "/1/merged", "{"}
          ] do
        conn =
          ctx.pk_conn
          |> put_req_header("content-type", "application/json")
          |> dispatch(@endpoint, method, crs_path(slug) <> suffix, body)

        assert json_response(conn, 403), suffix
      end

      assert count(ChangeRequest) == 1

      owner = Repo.preload(ctx.sk_key, :account_user).account_user
      {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read_write"})
      assert api_conn(ck) |> get(crs_path(slug)) |> json_response(403)
      assert api_conn(ck) |> get(cr_path(slug, 1)) |> json_response(403)
      assert api_conn(ck) |> post_json(crs_path(slug), %{}) |> json_response(403)
    end

    test "missing, expired or revoked keys are 401; other accounts' projects 404", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)

      assert build_conn()
             |> put_req_header("accept", "application/json")
             |> get(cr_path(slug, 1))
             |> json_response(401)

      assert api_conn("sk_unknown") |> get(cr_path(slug, 1)) |> json_response(401)

      au = account_user_fixture(ctx.account, user_fixture(), :member)
      {key, token} = api_key_fixture(au, %{type: :private})
      key |> Ecto.Changeset.change(status: :revoked) |> Repo.update!()
      assert api_conn(token) |> get(cr_path(slug, 1)) |> json_response(401)

      assert ctx.other_conn |> get(crs_path(slug)) |> json_response(404)
      assert ctx.sk_conn |> get(crs_path("Bad Slug")) |> json_response(422)
    end

    test "numbers resolve before the body is read; Accept must allow JSON", ctx do
      slug = ctx.project.slug
      for _ <- 1..3, do: create_cr(ctx.sk_conn, slug)

      conn = ctx.sk_conn |> post_json(cr_path(slug, 999, "/git-facts"), "{")
      assert json_response(conn, 404)

      for bad <- ["abc", "0", "-1", "01"] do
        assert %{"errors" => %{"number" => _}} =
                 ctx.sk_conn |> get(cr_path(slug, bad)) |> json_response(422)
      end

      assert_raise Phoenix.NotAcceptableError, fn ->
        ctx.sk_conn |> put_req_header("accept", "text/plain") |> get(cr_path(slug, 1))
      end

      {status, _headers, _body} =
        assert_error_sent(406, fn ->
          ctx.sk_conn |> put_req_header("accept", "text/plain") |> get(cr_path(slug, 1))
        end)

      assert status == 406
    end
  end

  describe "create and list" do
    test "defaults, record fields and validation keys", ctx do
      project = project_fixture(ctx.account, %{default_branch: "trunk"})

      body = %{
        "title" => "Add login",
        "source_branch" => "feat/login",
        "openspec_change" => "add-login",
        "links" => %{"tickets" => ["GOO-291"]}
      }

      data =
        ctx.sk_conn
        |> post_json(crs_path(project.slug), body)
        |> json_response(201)
        |> Map.fetch!("data")

      assert %{
               "number" => 1,
               "state" => "draft",
               "target_branch" => "trunk",
               "openspec_change" => "add-login",
               "links" => %{"tickets" => ["GOO-291"]},
               "head" => nil,
               "merge" => nil,
               "description" => nil,
               "history" => [],
               "verdict" => %{
                 "state" => "pending",
                 "head" => nil,
                 "reasons" => [%{"rule" => "git_facts_missing"}]
               }
             } = data

      refute Map.has_key?(data, "account_id") or Map.has_key?(data, "project_id")
      owner = Repo.preload(ctx.sk_key, :account_user).account_user
      assert data["opened_by"]["user_id"] == owner.user_id

      for {bad, key} <- [
            {%{"title" => "t", "source_branch" => "b", "openspec_change" => ["a", "b"]},
             "openspec_change"},
            {%{"title" => "t", "source_branch" => "b", "state" => "open"}, "body"},
            {%{"title" => "", "source_branch" => "b"}, "title"},
            {%{"title" => "t", "source_branch" => "b", "links" => %{}}, "links"}
          ] do
        assert %{"errors" => errors} =
                 ctx.sk_conn |> post_json(crs_path(project.slug), bad) |> json_response(422)

        assert Map.has_key?(errors, key), inspect(errors)
      end

      assert %{"errors" => %{"body" => ["has an unknown field"]}} =
               ctx.sk_conn
               |> post_json(crs_path(project.slug), %{
                 "title" => "t",
                 "source_branch" => "b",
                 "state" => "x"
               })
               |> json_response(422)

      assert ctx.sk_conn |> post_json(crs_path(project.slug), "{") |> json_response(400)
      assert count(ChangeRequest) == 1
    end

    test "pages and filters", ctx do
      slug = ctx.project.slug
      for _ <- 1..3, do: create_cr(ctx.sk_conn, slug)
      assert ctx.sk_conn |> post(cr_path(slug, 2, "/ready")) |> json_response(200)

      page = ctx.sk_conn |> get(crs_path(slug) <> "?limit=2") |> json_response(200)
      assert Enum.map(page["data"], & &1["number"]) == [3, 2]

      rest =
        ctx.sk_conn
        |> get(crs_path(slug) <> "?limit=2&cursor=#{page["next_cursor"]}")
        |> json_response(200)

      assert %{"data" => [%{"number" => 1}], "next_cursor" => nil} = rest

      assert %{"data" => [%{"number" => 2}]} =
               ctx.sk_conn |> get(crs_path(slug) <> "?state=open") |> json_response(200)

      assert %{"errors" => %{"state" => _}} =
               ctx.sk_conn |> get(crs_path(slug) <> "?state=approved") |> json_response(422)
    end
  end

  describe "states" do
    test "transitions, history and conflicts", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)

      assert %{"data" => %{"state" => "open"}} =
               ctx.sk_conn |> post(cr_path(slug, 1, "/ready")) |> json_response(200)

      assert %{"data" => %{"state" => "open", "history" => [_]}} =
               ctx.sk_conn |> post(cr_path(slug, 1, "/ready")) |> json_response(200)

      assert %{"data" => %{"state" => "draft"}} =
               ctx.sk_conn |> post(cr_path(slug, 1, "/draft")) |> json_response(200)

      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/ready")) |> json_response(200)

      assert %{"data" => %{"state" => "closed"}} =
               ctx.member_sk_conn |> post(cr_path(slug, 1, "/close")) |> json_response(200)

      assert ctx.sk_conn |> post(cr_path(slug, 1, "/ready")) |> json_response(409)

      assert %{"data" => %{"state" => "open", "history" => history}} =
               ctx.sk_conn |> post(cr_path(slug, 1, "/reopen")) |> json_response(200)

      assert Enum.map(history, &{&1["from_state"], &1["to_state"]}) == [
               {"draft", "open"},
               {"open", "draft"},
               {"draft", "open"},
               {"open", "closed"},
               {"closed", "open"}
             ]

      member_id = Enum.at(history, 3)["user_id"]
      refute member_id == hd(history)["user_id"]
    end

    test "state changes ignore any body", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)

      for {action, state} <- [{"/ready", "open"}, {"/close", "closed"}, {"/reopen", "open"}] do
        assert %{"data" => %{"state" => ^state}} =
                 ctx.sk_conn
                 |> put_req_header("content-type", "application/json")
                 |> post(cr_path(slug, 1, action), "{")
                 |> json_response(200),
               action
      end

      assert %{"data" => %{"state" => "draft"}} =
               ctx.sk_conn
               |> put_req_header("content-type", "text/plain")
               |> post(cr_path(slug, 1, "/draft"), "x")
               |> json_response(200)
    end

    test "merge reports", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)
      report = %{"merged_commit" => sha(0xC1), "target_branch" => "main"}

      assert %{"errors" => %{"merged_commit" => _}} =
               ctx.sk_conn
               |> post_json(cr_path(slug, 1, "/merged"), %{report | "merged_commit" => "ABC123"})
               |> json_response(422)

      first = ctx.sk_conn |> post_json(cr_path(slug, 1, "/merged"), report) |> json_response(200)
      assert_schema(first, "ChangeRequestResponse", ApiSpec.spec())

      assert %{
               "state" => "merged",
               "merge" => %{
                 "head" => nil,
                 "verdict_state" => "pending",
                 "merged_without_mergeable_verdict" => true
               }
             } =
               first["data"]

      again = ctx.sk_conn |> post_json(cr_path(slug, 1, "/merged"), report) |> json_response(200)
      assert again["data"]["merge"]["merged_at"] == first["data"]["merge"]["merged_at"]

      assert ctx.sk_conn
             |> post_json(cr_path(slug, 1, "/merged"), %{report | "merged_commit" => sha(0xC2)})
             |> json_response(409)

      for action <- ~w(close reopen ready draft) do
        assert ctx.sk_conn |> post(cr_path(slug, 1, "/" <> action)) |> json_response(409), action
      end

      _ = create_cr(ctx.sk_conn, slug)
      _ = ctx.sk_conn |> post(cr_path(slug, 2, "/close")) |> json_response(200)
      assert ctx.sk_conn |> post_json(cr_path(slug, 2, "/merged"), report) |> json_response(409)
    end
  end

  describe "Git facts" do
    test "201, retry 200, conflict 409, reads, totals and 404", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)

      files = [
        file("lib/a.ex", additions: 10, deletions: 2),
        file("lib/b.ex", additions: 5, deletions: 0)
      ]

      doc = git_facts(sha(1), files: files)

      assert %{"data" => %{"head" => head}} =
               ctx.sk_conn |> post_json(cr_path(slug, 1, "/git-facts"), doc) |> json_response(201)

      assert head == sha(1)

      reordered =
        doc
        |> Jason.encode!()
        |> Jason.decode!(objects: :ordered_objects)
        |> then(&Jason.encode!(%{&1 | values: Enum.reverse(&1.values)}))

      assert ctx.sk_conn
             |> post_json(cr_path(slug, 1, "/git-facts"), reordered)
             |> json_response(200)

      assert ctx.sk_conn
             |> post_json(cr_path(slug, 1, "/git-facts"), git_facts(sha(1), merge_base: sha(9)))
             |> json_response(409)

      read = ctx.sk_conn |> get(cr_path(slug, 1, "/git-facts/#{sha(1)}")) |> json_response(200)
      assert_schema(read, "GitFactsResponse", ApiSpec.spec())
      assert read["data"]["totals"] == %{"files" => 2, "additions" => 15, "deletions" => 2}
      assert read["data"]["user_id"]

      assert ctx.sk_conn |> get(cr_path(slug, 1, "/git-facts/#{sha(2)}")) |> json_response(404)

      assert %{"errors" => %{"head" => _}} =
               ctx.sk_conn |> get(cr_path(slug, 1, "/git-facts/ABC")) |> json_response(422)

      assert count(GitFacts) == 1
    end

    test "a second report for the same head on another target branch", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug, %{"target_branch" => "a"})
      _ = facts!(ctx, 1, sha(1), target: "a")

      Repo.update_all(ChangeRequest, set: [target_branch: "main"])

      assert ctx.sk_conn
             |> post_json(
               cr_path(slug, 1, "/git-facts"),
               git_facts(sha(1), files: [file("lib/m.ex")])
             )
             |> json_response(201)

      main = ctx.sk_conn |> get(cr_path(slug, 1, "/git-facts/#{sha(1)}")) |> json_response(200)
      assert main["data"]["target"]["branch"] == "main"

      a =
        ctx.sk_conn
        |> get(cr_path(slug, 1, "/git-facts/#{sha(1)}?target=a"))
        |> json_response(200)

      assert a["data"]["target"]["branch"] == "a"
      assert count(GitFacts) == 2
    end

    test "validation, body limits and closed change requests", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)

      assert %{"errors" => %{"target.branch" => _}} =
               ctx.sk_conn
               |> post_json(cr_path(slug, 1, "/git-facts"), git_facts(sha(1), target: "release"))
               |> json_response(422)

      head_key = "\"head\":"
      duplicate_head = head_key <> "\"" <> sha(2) <> "\"," <> head_key

      dup =
        String.replace(Jason.encode!(git_facts(sha(1))), head_key, duplicate_head, global: false)

      assert %{"errors" => %{"body" => ["has a duplicate key"]}} =
               ctx.sk_conn |> post_json(cr_path(slug, 1, "/git-facts"), dup) |> json_response(422)

      too_big =
        ctx.sk_conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", "16777217")
        |> post(cr_path(slug, 1, "/git-facts"), "{}")

      assert json_response(too_big, 413)

      assert ctx.sk_conn
             |> post_markdown(cr_path(slug, 1, "/git-facts"), "{}", "text/plain")
             |> json_response(415)

      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/close")) |> json_response(200)

      assert ctx.sk_conn
             |> post_json(cr_path(slug, 1, "/git-facts"), git_facts(sha(1)))
             |> json_response(409)

      assert count(GitFacts) == 0
    end
  end

  describe "claims" do
    test "upload, retry, conflict, reads and description after the head moves", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)

      assert %{"errors" => %{"head" => _}} =
               ctx.sk_conn
               |> post_markdown(cr_path(slug, 1, "/claims"), claims(front_matter(sha(1))))
               |> json_response(422)

      _ = facts!(ctx, 1, sha(1))
      raw = claims(front_matter(sha(1), %{"cr" => 1}))
      created = claims!(ctx, 1, raw)
      assert created["data"]["description"] == raw
      assert ctx.sk_conn |> post_markdown(cr_path(slug, 1, "/claims"), raw) |> json_response(200)

      other = claims(front_matter(sha(1), %{"cr" => 1, "reach" => "Everything"}))

      assert ctx.sk_conn
             |> post_markdown(cr_path(slug, 1, "/claims"), other)
             |> json_response(409)

      read = ctx.sk_conn |> get(cr_path(slug, 1, "/claims/#{sha(1)}")) |> json_response(200)
      assert_schema(read, "ClaimsResponse", ApiSpec.spec())
      assert %{"document" => ^raw, "front_matter" => %{"head" => head}} = read["data"]
      assert head == sha(1)

      _ = facts!(ctx, 1, sha(2))
      shown = ctx.sk_conn |> get(cr_path(slug, 1)) |> json_response(200)
      assert %{"description" => nil, "head" => moved} = shown["data"]
      assert moved == sha(2)
      assert ctx.sk_conn |> get(cr_path(slug, 1, "/claims/#{sha(1)}")) |> json_response(200)
      assert ctx.sk_conn |> get(cr_path(slug, 1, "/claims/#{sha(2)}")) |> json_response(404)
    end

    test "content type, size, YAML and closed change requests", ctx do
      slug = ctx.project.slug
      _ = create_cr(ctx.sk_conn, slug)
      _ = facts!(ctx, 1, sha(1))
      raw = claims(front_matter(sha(1)))

      assert ctx.sk_conn
             |> post_markdown(cr_path(slug, 1, "/claims"), raw, "application/json")
             |> json_response(415)

      assert ctx.sk_conn
             |> post_markdown(cr_path(slug, 1, "/claims"), raw, "text/markdown; charset=utf-8")
             |> json_response(201)

      big =
        ctx.sk_conn
        |> put_req_header("content-type", "text/markdown")
        |> put_req_header("content-length", "1048577")
        |> post(cr_path(slug, 1, "/claims"), raw)

      assert json_response(big, 413)

      _ = facts!(ctx, 1, sha(2))
      alias_yaml = "---\nformat: &a change-claims/2\nx: *a\n---\n"

      assert %{"errors" => %{"front_matter" => _}} =
               ctx.sk_conn
               |> post_markdown(cr_path(slug, 1, "/claims"), alias_yaml)
               |> json_response(422)

      for {yaml, message} <- [
            {"x: " <> String.duplicate("[", 8_000) <> String.duplicate("]", 8_000),
             "must not nest collections more than 16 levels deep"},
            {"door: two_way\ndoor: one_way", "has a duplicate key"},
            {"door: two_way\n...\n--- \ndoor: one_way", "must be a single YAML document"},
            {"x: " <> String.duplicate("9", 200_000),
             "must not have an integer of more than 32 digits"},
            {"x: a\u0000b", "is not valid YAML"}
          ] do
        assert %{"errors" => %{"front_matter" => [^message]}} =
                 ctx.sk_conn
                 |> post_markdown(cr_path(slug, 1, "/claims"), "---\n" <> yaml <> "\n---\n")
                 |> json_response(422)
      end

      assert %{"errors" => %{"front_matter" => _}} =
               ctx.sk_conn
               |> post_markdown(cr_path(slug, 1, "/claims"), "# no front matter")
               |> json_response(422)

      assert %{"errors" => %{"format" => _}} =
               ctx.sk_conn
               |> post_markdown(
                 cr_path(slug, 1, "/claims"),
                 claims(front_matter(sha(2), %{"format" => "change-claims/1"}))
               )
               |> json_response(422)

      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/close")) |> json_response(200)

      assert ctx.sk_conn
             |> post_markdown(cr_path(slug, 1, "/claims"), claims(front_matter(sha(2))))
             |> json_response(409)

      assert count(Claims) == 1
    end
  end

  describe "public key redaction" do
    setup ctx do
      slug = ctx.project.slug
      links = %{"tickets" => ["GOO-1"], "threads" => ["https://ampcode.com/threads/T-1"]}
      _ = create_cr(ctx.sk_conn, slug, %{"links" => links})
      _ = facts!(ctx, 1, sha(1), files: [file("app/priv/repo/migrations/1.exs")])
      _ = claims!(ctx, 1, claims(front_matter(sha(1), %{"cr" => 1, "door" => "one_way"})))
      _ = ctx.sk_conn |> post(cr_path(slug, 1, "/ready")) |> json_response(200)
      :ok
    end

    test "show", ctx do
      data =
        ctx.pk_conn
        |> get(cr_path(ctx.project.slug, 1))
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{
               "description" => nil,
               "opened_by" => %{"user_id" => nil},
               "links" => %{"threads" => nil, "tickets" => ["GOO-1"]}
             } = data

      assert [%{"user_id" => nil}] = data["history"]

      assert Enum.all?(
               data["verdict"]["reasons"],
               &(&1["subject"] == nil and &1["message"] == nil)
             )

      sk =
        ctx.sk_conn
        |> get(cr_path(ctx.project.slug, 1))
        |> json_response(200)
        |> Map.fetch!("data")

      assert sk["description"] && sk["opened_by"]["user_id"] && hd(sk["history"])["user_id"]
      assert sk["links"]["threads"] == ["https://ampcode.com/threads/T-1"]
    end

    test "a change request without threads gains no threads key", ctx do
      _ = create_cr(ctx.sk_conn, ctx.project.slug, %{"links" => %{"tickets" => ["GOO-2"]}})

      data =
        ctx.pk_conn
        |> get(cr_path(ctx.project.slug, 2))
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["links"] == %{"tickets" => ["GOO-2"]}
      list = ctx.pk_conn |> get(crs_path(ctx.project.slug)) |> json_response(200)
      assert Enum.all?(list["data"], &(&1["opened_by"]["user_id"] == nil))
    end

    test "claims", ctx do
      data =
        ctx.pk_conn
        |> get(cr_path(ctx.project.slug, 1, "/claims/#{sha(1)}"))
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["document"] == nil
      assert data["user_id"] == nil

      assert data["front_matter"] == %{
               "format" => "change-claims/2",
               "cr" => 1,
               "head" => sha(1),
               "door" => "one_way"
             }
    end

    test "Git facts", ctx do
      data =
        ctx.pk_conn
        |> get(cr_path(ctx.project.slug, 1, "/git-facts/#{sha(1)}"))
        |> json_response(200)
        |> Map.fetch!("data")

      assert %{
               "head" => _,
               "target" => %{"branch" => "main"},
               "totals" => %{"files" => 1},
               "diff" => %{"files" => nil},
               "user_id" => nil
             } = data

      assert [%{"sha" => _, "parents" => [_], "changed_files" => nil}] = data["commits"]
    end

    test "verdict and merge", ctx do
      verdict = ctx.pk_conn |> get(cr_path(ctx.project.slug, 1, "/verdict")) |> json_response(200)
      assert_schema(verdict, "VerdictResponse", ApiSpec.spec())
      assert %{"head" => _, "policy_version" => 0, "reasons" => reasons} = verdict["data"]

      assert %{
               "rule" => "path_match",
               "outcome" => "needs_review",
               "subject" => nil,
               "message" => nil
             } in reasons

      sk = ctx.sk_conn |> get(cr_path(ctx.project.slug, 1, "/verdict")) |> json_response(200)

      assert Enum.find(sk["data"]["reasons"], &(&1["rule"] == "path_match"))["subject"] ==
               ["app/priv/repo/migrations/**", "app/priv/repo/migrations/1.exs"]

      _ =
        ctx.sk_conn
        |> post_json(cr_path(ctx.project.slug, 1, "/merged"), %{
          "merged_commit" => sha(5),
          "target_branch" => "main"
        })
        |> json_response(200)

      merge =
        ctx.pk_conn
        |> get(cr_path(ctx.project.slug, 1))
        |> json_response(200)
        |> get_in(["data", "merge"])

      assert merge["verdict_state"] == "needs_review"
      assert Enum.all?(merge["reasons"], &(&1["subject"] == nil and &1["message"] == nil))

      assert ctx.sk_conn
             |> get(cr_path(ctx.project.slug, 1))
             |> json_response(200)
             |> get_in(["data", "merge", "reasons"])
             |> hd()
             |> Map.fetch!("message")
    end
  end
end
