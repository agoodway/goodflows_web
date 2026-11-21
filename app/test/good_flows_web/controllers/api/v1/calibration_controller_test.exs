defmodule GoodFlowsWeb.Api.V1.CalibrationControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.MergeFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Caches.Keys
  alias GoodFlows.Calibration.Defect
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    owner = Repo.preload(ctx.sk_key, :account_user).account_user
    {:ok, {_key, ck}} = Keys.mint(owner, project, %{"access" => "read_write"})
    %{project: project, slug: project.slug, ck_conn: api_conn(ck)}
  end

  describe "defects" do
    test "sk_ records a defect: 201 with the defect", ctx do
      number = create_cr(ctx.sk_conn, ctx.slug)["number"]

      body =
        ctx.sk_conn
        |> post_defect(ctx.slug, %{
          "change_request" => number,
          "severity" => "high",
          "ticket" => "GOO-512"
        })
        |> json_response(201)

      assert_schema(body, "DefectResponse", ApiSpec.spec())

      assert %{
               "change_request" => ^number,
               "commit" => nil,
               "severity" => "high",
               "ticket" => "GOO-512",
               "attribution" => "change_request",
               "id" => _,
               "recorded_at" => _
             } = body["data"]

      assert %{"data" => %{"severity" => nil, "ticket" => nil}} =
               ctx.sk_conn
               |> post_defect(ctx.slug, %{"change_request" => number})
               |> json_response(201)
    end

    test "pk_ and ck_ cannot record; ck_ cannot list; 401, 404 and 406", ctx do
      body = %{"commit" => sha(1)}
      assert ctx.pk_conn |> post_defect(ctx.slug, body) |> json_response(403)
      assert ctx.ck_conn |> post_defect(ctx.slug, body) |> json_response(403)
      assert ctx.ck_conn |> get(defects_path(ctx.slug)) |> json_response(403)
      assert build_conn() |> post_defect(ctx.slug, body) |> json_response(401)
      assert build_conn() |> get(defects_path(ctx.slug)) |> json_response(401)
      assert ctx.other_conn |> post_defect(ctx.slug, body) |> json_response(404)
      assert ctx.sk_conn |> post_defect("nope", body) |> json_response(404)

      assert_error_sent(406, fn ->
        ctx.sk_conn |> accept("text/plain") |> get(defects_path(ctx.slug))
      end)

      assert Repo.aggregate(Defect, :count) == 0
    end

    test "a 422 stores nothing and records no event", ctx do
      assert %{"errors" => %{"body" => _}} =
               ctx.sk_conn
               |> post_defect(ctx.slug, %{"severity" => "low"})
               |> json_response(422)

      assert %{"errors" => %{"severity" => _}} =
               ctx.sk_conn
               |> post_defect(ctx.slug, %{"commit" => sha(1), "severity" => "blocker"})
               |> json_response(422)

      assert Repo.aggregate(Defect, :count) == 0
      refute "defect_recorded" in Enum.map(events(ctx.sk_conn, ctx.slug)["data"], & &1["type"])
    end

    test "list pages newest first; pk_ sees ticket null", ctx do
      for i <- 1..60 do
        ctx.sk_conn
        |> post_defect(ctx.slug, %{"commit" => sha(i), "ticket" => "GOO-#{i}"})
        |> json_response(201)
      end

      page = ctx.sk_conn |> get(defects_path(ctx.slug), %{"limit" => "50"}) |> json_response(200)
      assert_schema(page, "DefectListResponse", ApiSpec.spec())
      assert length(page["data"]) == 50
      assert hd(page["data"])["commit"] == sha(60)
      assert hd(page["data"])["ticket"] == "GOO-60"

      rest =
        ctx.sk_conn
        |> get(defects_path(ctx.slug), %{"cursor" => page["next_cursor"]})
        |> json_response(200)

      assert length(rest["data"]) == 10
      assert rest["next_cursor"] == nil
      ids = Enum.map(page["data"] ++ rest["data"], & &1["id"])
      assert length(Enum.uniq(ids)) == 60

      public = ctx.pk_conn |> get(defects_path(ctx.slug)) |> json_response(200)
      assert Enum.all?(public["data"], &(&1["ticket"] == nil))

      assert ctx.sk_conn
             |> get(defects_path(ctx.slug), %{"cursor" => "garbage"})
             |> json_response(422)

      assert ctx.sk_conn |> get(defects_path(ctx.slug), %{"limit" => "201"}) |> json_response(422)
    end
  end

  describe "events" do
    test "defect_recorded redacts ticket and actor for pk_; sk_ sees them", ctx do
      number = create_cr(ctx.sk_conn, ctx.slug)["number"]

      ctx.sk_conn
      |> post_defect(ctx.slug, %{
        "change_request" => number,
        "severity" => "high",
        "ticket" => "GOO-512"
      })
      |> json_response(201)

      find = fn conn ->
        Enum.find(events(conn, ctx.slug)["data"], &(&1["type"] == "defect_recorded"))
      end

      private = find.(ctx.sk_conn)

      assert %{"number" => ^number, "data" => %{"ticket" => "GOO-512", "severity" => "high"}} =
               private

      assert private["actor"]["key_id"] == ctx.sk_key.id

      public = find.(ctx.pk_conn)

      assert %{
               "number" => ^number,
               "actor" => nil,
               "data" => %{
                 "ticket" => nil,
                 "severity" => "high",
                 "attribution" => "change_request"
               }
             } = public

      assert Map.keys(public["data"]) == Map.keys(private["data"])
    end

    test "lease events: number and actor at the top level; pk_ sees actor null", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      lease = acquire!(ctx.sk_conn, ctx.slug, number, sha(1), sha(0))

      acquired =
        Enum.find(events(ctx.sk_conn, ctx.slug)["data"], &(&1["type"] == "lease_acquired"))

      assert acquired["number"] == number
      assert acquired["actor"]["key_id"] == ctx.sk_key.id

      assert acquired["data"] == %{
               "lease_id" => lease["id"],
               "target_branch" => "main",
               "expires_at" => acquired["data"]["expires_at"]
             }

      public = Enum.find(events(ctx.pk_conn, ctx.slug)["data"], &(&1["type"] == "lease_acquired"))
      assert public["actor"] == nil
      assert public["number"] == number
      assert public["data"] == acquired["data"]
    end
  end

  describe "calibration" do
    test "sk_ and pk_ read it; ck_ is 403; reversed window 422; no key 401", ctx do
      for conn <- [ctx.sk_conn, ctx.pk_conn] do
        body =
          conn
          |> get(calibration_path(ctx.slug), %{"to" => "2026-11-21T00:00:00Z"})
          |> json_response(200)

        assert_schema(body, "CalibrationResponse", ApiSpec.spec())
        assert body["data"]["from"] == "2026-08-23T00:00:00Z"
        assert body["data"]["to"] == "2026-11-21T00:00:00Z"
        assert body["data"]["lanes"]["auto"]["defect_rate"] == nil
      end

      assert ctx.ck_conn |> get(calibration_path(ctx.slug)) |> json_response(403)
      assert build_conn() |> get(calibration_path(ctx.slug)) |> json_response(401)
      assert ctx.other_conn |> get(calibration_path(ctx.slug)) |> json_response(404)

      assert %{"errors" => %{"from" => _}} =
               ctx.sk_conn
               |> get(calibration_path(ctx.slug), %{
                 "from" => "2026-11-10T00:00:00Z",
                 "to" => "2026-11-01T00:00:00Z"
               })
               |> json_response(422)
    end

    test "a merged change request and its defect show in the report", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      lease = acquire!(ctx.sk_conn, ctx.slug, number, sha(1), sha(0))

      ctx.sk_conn
      |> merged(ctx.slug, number, sha(500), %{"lease_id" => lease["id"]})
      |> json_response(200)

      ctx.sk_conn |> post_defect(ctx.slug, %{"commit" => sha(1)}) |> json_response(201)

      policy_before =
        ctx.sk_conn |> get("/api/v1/projects/#{ctx.slug}/review-policy") |> json_response(200)

      report = ctx.sk_conn |> get(calibration_path(ctx.slug)) |> json_response(200)

      assert %{
               "merged_count" => 1,
               "defect_count" => 1,
               "defective_count" => 1,
               "defect_rate" => 1.0
             } =
               report["data"]["lanes"]["auto"]

      assert ctx.sk_conn
             |> get("/api/v1/projects/#{ctx.slug}/review-policy")
             |> json_response(200) ==
               policy_before
    end
  end
end
