defmodule GoodFlowsWeb.Api.V1.MergeLeaseControllerTest do
  use GoodFlowsWeb.ConnCase, async: true

  import Ecto.Query
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.MergeFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.Accounts
  alias GoodFlows.Caches.Keys
  alias GoodFlows.MergeLeases.Lease
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    %{project: project, slug: project.slug}
  end

  defp lease!(id), do: Repo.get!(Lease, id)
  defp count_leases, do: Repo.aggregate(Lease, :count)

  defp expire!(id, seconds \\ -30) do
    at = DateTime.add(DateTime.utc_now(), seconds, :second)
    {1, _} = Repo.update_all(from(l in Lease, where: l.id == ^id), set: [expires_at: at])
    at
  end

  defp ck_conn(ctx) do
    owner = Repo.preload(ctx.sk_key, :account_user).account_user
    {:ok, {_key, ck}} = Keys.mint(owner, ctx.project, %{"access" => "read_write"})
    api_conn(ck)
  end

  defp show(conn, slug, number),
    do: conn |> get(cr_path(slug, number)) |> json_response(200) |> Map.fetch!("data")

  defp feed_types(conn, slug), do: Enum.map(events(conn, slug)["data"], & &1["type"])

  describe "access" do
    setup ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      %{number: number}
    end

    test "pk_ and ck_ cannot acquire; no key is 401; unknown numbers and accounts are 404",
         ctx do
      assert ctx.pk_conn |> acquire(ctx.slug, ctx.number, sha(1), sha(0)) |> json_response(403)
      assert ck_conn(ctx) |> acquire(ctx.slug, ctx.number, sha(1), sha(0)) |> json_response(403)
      assert build_conn() |> acquire(ctx.slug, ctx.number, sha(1), sha(0)) |> json_response(401)
      assert ctx.sk_conn |> acquire(ctx.slug, 999, sha(1), sha(0)) |> json_response(404)
      assert ctx.other_conn |> acquire(ctx.slug, ctx.number, sha(1), sha(0)) |> json_response(404)
      assert ctx.sk_conn |> acquire("Bad Slug", 1, sha(1), sha(0)) |> json_response(422)
      assert count_leases() == 0

      assert_error_sent(406, fn ->
        ctx.sk_conn |> accept("text/plain") |> acquire(ctx.slug, ctx.number, sha(1), sha(0))
      end)
    end

    test "pk_, ck_ and revoked keys cannot heartbeat or release; expires_at is unchanged", ctx do
      lease = acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(0))
      expires_at = lease!(lease["id"]).expires_at

      owner = Repo.preload(ctx.sk_key, :account_user).account_user
      {revoked, token} = GoodFlows.AccountsFixtures.api_key_fixture(owner, %{type: :private})
      {:ok, _} = Accounts.revoke_api_key(revoked)

      for {conn, status} <- [{ctx.pk_conn, 403}, {ck_conn(ctx), 403}, {api_conn(token), 401}] do
        assert conn |> heartbeat(ctx.slug, lease["id"]) |> json_response(status)
        assert conn |> release(ctx.slug, lease["id"]) |> json_response(status)
      end

      assert ctx.other_conn |> heartbeat(ctx.slug, lease["id"]) |> json_response(404)
      assert %Lease{state: "active", expires_at: ^expires_at} = lease!(lease["id"])
    end

    test "another member's key of the account releases a lease", ctx do
      lease = acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(0))
      assert ctx.member_sk_conn |> release(ctx.slug, lease["id"]) |> response(204)
      assert lease!(lease["id"]).state == "released"
    end
  end

  describe "acquire" do
    test "201 with the lease, 200 for the holder's retry", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      body = ctx.sk_conn |> acquire(ctx.slug, number, sha(1), sha(9)) |> json_response(201)
      assert_schema(body, "MergeLeaseResponse", ApiSpec.spec())

      data = body["data"]

      assert %{
               "change_request" => ^number,
               "target_branch" => "main",
               "state" => "active",
               "release_reason" => nil
             } = data

      assert data["head"] == sha(1) and data["base"] == sha(9)
      {:ok, acquired, _} = DateTime.from_iso8601(data["acquired_at"])
      {:ok, expires, _} = DateTime.from_iso8601(data["expires_at"])
      assert DateTime.diff(expires, acquired, :second) == 600

      retry = ctx.sk_conn |> acquire(ctx.slug, number, sha(1), sha(9)) |> json_response(200)
      assert retry["data"]["id"] == data["id"]
      assert retry["data"]["expires_at"] == data["expires_at"]
    end

    test "409 bodies: not_open, stale_head, not_mergeable, slot_taken", ctx do
      draft = create_cr(ctx.sk_conn, ctx.slug)["number"]
      facts!(ctx.sk_conn, ctx.slug, draft, sha(1))
      claims!(ctx.sk_conn, ctx.slug, draft, sha(1), %{"cr" => draft})

      assert %{"errors" => %{"error" => "not_open"}} =
               body =
               ctx.sk_conn |> acquire(ctx.slug, draft, sha(1), sha(0)) |> json_response(409)

      assert_schema(body, "CodedConflictResponse", ApiSpec.spec())

      moved = mergeable!(ctx.sk_conn, ctx.slug, sha(2))

      assert %{"errors" => %{"error" => "stale_head", "head" => head}} =
               ctx.sk_conn |> acquire(ctx.slug, moved, sha(1), sha(0)) |> json_response(409)

      assert head == sha(2)

      policy!(ctx.sk_conn, ctx.slug, %{
        "paths" => [%{"glob" => "app/priv/repo/migrations/**", "outcome" => "needs_review"}]
      })

      review =
        mergeable!(ctx.sk_conn, ctx.slug, sha(3), files: [file("app/priv/repo/migrations/x.exs")])

      assert %{"errors" => %{"error" => "not_mergeable", "state" => "needs_review"}} =
               ctx.sk_conn |> acquire(ctx.slug, review, sha(3), sha(0)) |> json_response(409)

      holder = acquire!(ctx.sk_conn, ctx.slug, moved, sha(2), sha(0))
      other = mergeable!(ctx.sk_conn, ctx.slug, sha(4))

      body = ctx.sk_conn |> acquire(ctx.slug, other, sha(4), sha(0)) |> json_response(409)
      assert_schema(body, "CodedConflictResponse", ApiSpec.spec())

      assert %{"error" => "slot_taken", "holder" => %{"change_request" => ^moved}} =
               body["errors"]

      {:ok, holder_expiry, _} = DateTime.from_iso8601(holder["expires_at"])
      {:ok, shown_expiry, _} = DateTime.from_iso8601(body["errors"]["holder"]["expires_at"])
      assert DateTime.compare(holder_expiry, shown_expiry) == :eq
      refute Map.has_key?(body["errors"], "id")
      refute Map.has_key?(body["errors"]["holder"], "id")
      refute Jason.encode!(body) =~ holder["id"]
      assert count_leases() == 1
    end

    test "a malformed base is 422 on base", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))

      assert %{"errors" => %{"base" => _}} =
               ctx.sk_conn
               |> post_json(cr_path(ctx.slug, number, "/merge-lease"), %{
                 "head" => sha(1),
                 "base" => "main"
               })
               |> json_response(422)

      assert count_leases() == 0
    end

    test "different branches and projects each get a lease", ctx do
      main = mergeable!(ctx.sk_conn, ctx.slug, sha(1))

      release =
        mergeable!(ctx.sk_conn, ctx.slug, sha(2),
          attrs: %{"target_branch" => "release/1.2"},
          target: "release/1.2"
        )

      other = project_fixture(ctx.account)
      elsewhere = mergeable!(ctx.sk_conn, other.slug, sha(3))

      assert acquire!(ctx.sk_conn, ctx.slug, main, sha(1), sha(0))
      assert acquire!(ctx.sk_conn, ctx.slug, release, sha(2), sha(0))
      assert acquire!(ctx.sk_conn, other.slug, elsewhere, sha(3), sha(0))
    end
  end

  describe "heartbeat and release" do
    setup ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      %{number: number, lease: acquire!(ctx.sk_conn, ctx.slug, number, sha(1), sha(0))}
    end

    test "heartbeat 200 extends; after expiry and for unknown ids 409 lease_not_active", ctx do
      body = ctx.sk_conn |> heartbeat(ctx.slug, ctx.lease["id"]) |> json_response(200)
      assert_schema(body, "MergeLeaseResponse", ApiSpec.spec())
      assert body["data"]["expires_at"] >= ctx.lease["expires_at"]

      for id <- ["7c0e5a1e-0000-4000-8000-000000000000", "nope"] do
        assert %{"errors" => %{"error" => "lease_not_active"}} =
                 ctx.sk_conn |> heartbeat(ctx.slug, id) |> json_response(409)
      end

      at = expire!(ctx.lease["id"])
      renewed = length(Enum.filter(feed_types(ctx.sk_conn, ctx.slug), &(&1 == "lease_renewed")))

      assert %{"errors" => %{"error" => "lease_not_active"}} =
               ctx.sk_conn |> heartbeat(ctx.slug, ctx.lease["id"]) |> json_response(409)

      assert lease!(ctx.lease["id"]).expires_at == at
      assert Enum.count(feed_types(ctx.sk_conn, ctx.slug), &(&1 == "lease_renewed")) == renewed
    end

    test "release 204 frees the slot; a second release is 409", ctx do
      assert ctx.sk_conn |> release(ctx.slug, ctx.lease["id"]) |> response(204)
      assert show(ctx.sk_conn, ctx.slug, ctx.number)["state"] == "open"

      assert %{"errors" => %{"error" => "lease_not_active"}} =
               ctx.sk_conn |> release(ctx.slug, ctx.lease["id"]) |> json_response(409)

      other = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      assert ctx.sk_conn |> acquire(ctx.slug, other, sha(2), sha(0)) |> json_response(201)
    end
  end

  describe "merge report" do
    setup ctx do
      %{number: mergeable!(ctx.sk_conn, ctx.slug, sha(1))}
    end

    test "naming the held lease: leased merge, lease released as merged, slot free", ctx do
      lease = acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(0))

      body =
        ctx.sk_conn
        |> merged(ctx.slug, ctx.number, sha(500), %{"lease_id" => lease["id"]})
        |> json_response(200)

      assert_schema(body, "ChangeRequestResponse", ApiSpec.spec())

      assert %{"merged_without_lease" => false, "merged_without_mergeable_verdict" => false} =
               body["data"]["merge"]

      assert %Lease{state: "released", release_reason: "merged"} = lease!(lease["id"])

      feed = events(ctx.sk_conn, ctx.slug)["data"]
      types = Enum.map(feed, & &1["type"])

      state_at =
        Enum.find_index(
          feed,
          &(&1["type"] == "cr_state_changed" and &1["data"]["to"] == "merged")
        )

      released_at = Enum.find_index(types, &(&1 == "lease_released"))
      assert state_at < released_at
      assert Enum.at(feed, released_at)["data"]["release_reason"] == "merged"

      assert Enum.count(
               feed,
               &(&1["type"] == "cr_state_changed" and &1["data"]["to"] == "merged")
             ) == 1

      other = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      assert ctx.sk_conn |> acquire(ctx.slug, other, sha(2), sha(0)) |> json_response(201)
    end

    test "omitting the held lease: flagged, and the lease is still released", ctx do
      lease = acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(0))

      assert %{"data" => %{"merge" => %{"merged_without_lease" => true}}} =
               ctx.sk_conn |> merged(ctx.slug, ctx.number, sha(500)) |> json_response(200)

      assert %Lease{state: "released", release_reason: "merged"} = lease!(lease["id"])
    end

    test "naming an expired lease: flagged, the lease expires", ctx do
      lease = acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(0))
      expire!(lease["id"], -120)

      assert %{"data" => %{"merge" => %{"merged_without_lease" => true}}} =
               ctx.sk_conn
               |> merged(ctx.slug, ctx.number, sha(500), %{"lease_id" => lease["id"]})
               |> json_response(200)

      assert lease!(lease["id"]).state == "expired"
    end

    test "never leased: flagged; a retry naming a real lease is 200 and still flagged", ctx do
      assert %{"data" => %{"merge" => %{"merged_without_lease" => true}}} =
               ctx.sk_conn |> merged(ctx.slug, ctx.number, sha(500)) |> json_response(200)

      # A merged change request cannot hold a lease, so the retry names the
      # active lease of another change request.
      other = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      lease = acquire!(ctx.sk_conn, ctx.slug, other, sha(2), sha(500))

      assert %{"data" => %{"merge" => %{"merged_without_lease" => true}}} =
               ctx.sk_conn
               |> merged(ctx.slug, ctx.number, sha(500), %{"lease_id" => lease["id"]})
               |> json_response(200)

      assert %Lease{state: "active"} = lease!(lease["id"])
    end

    test "a non-string lease_id is 422 on lease_id and changes nothing", ctx do
      assert %{"errors" => %{"lease_id" => _}} =
               ctx.sk_conn
               |> merged(ctx.slug, ctx.number, sha(500), %{"lease_id" => 42})
               |> json_response(422)

      assert show(ctx.sk_conn, ctx.slug, ctx.number)["state"] == "open"
    end

    test "both flags; the merge's release keeps the frozen merged verdict", ctx do
      lease = acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(77))
      assert rules(verdict(ctx.sk_conn, ctx.slug, ctx.number)) == ["merge_result_ungraded"]

      merge =
        ctx.sk_conn
        |> merged(ctx.slug, ctx.number, sha(500))
        |> json_response(200)
        |> get_in(["data", "merge"])

      assert %{
               "merged_without_lease" => true,
               "merged_without_mergeable_verdict" => true,
               "verdict_state" => "pending"
             } = merge

      assert Enum.map(merge["reasons"], & &1["rule"]) == ["merge_result_ungraded"]
      assert lease!(lease["id"]).release_reason == "merged"

      stored = verdict(ctx.sk_conn, ctx.slug, ctx.number)
      assert stored["state"] == "pending"
      assert rules(stored) == ["merge_result_ungraded"]
    end
  end

  describe "close" do
    test "closing releases the lease as closed and a later acquire on the branch is 201", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      lease = acquire!(ctx.sk_conn, ctx.slug, number, sha(1), sha(0))

      _ = ctx.sk_conn |> post(cr_path(ctx.slug, number, "/close")) |> json_response(200)
      assert %Lease{state: "released", release_reason: "closed"} = lease!(lease["id"])

      released =
        Enum.filter(events(ctx.sk_conn, ctx.slug)["data"], &(&1["type"] == "lease_released"))

      assert [%{"number" => ^number, "data" => %{"release_reason" => "closed"}}] = released

      other = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      assert ctx.sk_conn |> acquire(ctx.slug, other, sha(2), sha(0)) |> json_response(201)
    end
  end

  describe "merge-result grading" do
    # An open change request linked to `add-export` with an intent set,
    # graded at `sha(1)` by a passing branch run: mergeable.
    setup ctx do
      number =
        mergeable!(ctx.sk_conn, ctx.slug, sha(1),
          attrs: %{"openspec_change" => "add-export"},
          merge_base: sha(100)
        )

      digest =
        ctx.sk_conn
        |> post_json(
          cr_path(ctx.slug, number, "/scenario-sets"),
          set_body(intent_fm("add-export"))
        )
        |> json_response(201)
        |> get_in(["data", "digest"])

      upload_run!(ctx, run_doc(digest, "intent", sha(1), [result("S1"), result("S2")]))
      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "mergeable"
      %{number: number, digest: digest}
    end

    defp upload_run!(ctx, doc) do
      ctx.sk_conn
      |> post_json("/api/v1/projects/#{ctx.slug}/verify-runs", doc)
      |> json_response(201)
    end

    defp mr_run(ctx, base, results, opts \\ []) do
      opts = Keyword.put(opts, :merge_result, %{"base" => base, "commit" => sha(900)})
      upload_run!(ctx, run_doc(ctx.digest, "intent", sha(900), results, opts))
    end

    test "base moved: pending merge_result_ungraded with the lease base as subject", ctx do
      acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(200))
      v = verdict(ctx.sk_conn, ctx.slug, ctx.number)
      assert v["state"] == "pending"
      assert [%{"subject" => [base]}] = reasons(v, "merge_result_ungraded")
      assert base == sha(200)
    end

    test "base unchanged: mergeable", ctx do
      acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(100))
      assert verdict(ctx.sk_conn, ctx.slug, ctx.number)["state"] == "mergeable"
    end

    test "regrading off: mergeable", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"merge" => %{"regrade_merge_result" => false}})
      acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(200))
      assert verdict(ctx.sk_conn, ctx.slug, ctx.number)["state"] == "mergeable"
    end

    test "a passing merge-result run clears the check; release recomputes without it", ctx do
      lease = acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(200))
      mr_run(ctx, sha(200), [result("S1"), result("S2", "failed")])
      assert verdict(ctx.sk_conn, ctx.slug, ctx.number)["state"] == "mergeable"

      assert ctx.sk_conn |> release(ctx.slug, lease["id"]) |> response(204)
      assert verdict(ctx.sk_conn, ctx.slug, ctx.number)["state"] == "mergeable"
    end

    test "failed and not_run Musts block with merge_result_failed", ctx do
      acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(200))
      mr_run(ctx, sha(200), [result("S1", "failed"), result("S2")])

      v = verdict(ctx.sk_conn, ctx.slug, ctx.number)
      assert v["state"] == "blocked"

      assert [%{"subject" => ["intent", "S1"], "outcome" => "blocked"}] =
               reasons(v, "merge_result_failed")

      mr_run(ctx, sha(200), [result("S1", "not_run"), result("S2")],
        finished_at: "2026-11-20T11:00:00Z"
      )

      assert [%{"subject" => ["intent", "S1"]}] =
               reasons(verdict(ctx.sk_conn, ctx.slug, ctx.number), "merge_result_failed")

      mr_run(ctx, sha(200), [result("S1"), result("S2")], finished_at: "2026-11-20T12:00:00Z")
      assert verdict(ctx.sk_conn, ctx.slug, ctx.number)["state"] == "mergeable"
    end

    test "dirty runs and runs on an older base do not count", ctx do
      acquire!(ctx.sk_conn, ctx.slug, ctx.number, sha(1), sha(200))
      mr_run(ctx, sha(200), [result("S1"), result("S2")], dirty: true)
      mr_run(ctx, sha(100), [result("S1"), result("S2")])

      v = verdict(ctx.sk_conn, ctx.slug, ctx.number)
      assert v["state"] == "pending"
      assert [%{"subject" => [base]}] = reasons(v, "merge_result_ungraded")
      assert base == sha(200)
    end

    test "a merge-result run does not grade the branch", ctx do
      other =
        mergeable!(ctx.sk_conn, ctx.slug, sha(2),
          attrs: %{"openspec_change" => "add-export"},
          merge_base: sha(100)
        )

      ctx.sk_conn
      |> post_json(cr_path(ctx.slug, other, "/scenario-sets"), set_body(intent_fm("add-export")))
      |> json_response(201)

      before = verdict(ctx.sk_conn, ctx.slug, other)
      assert rules(before) == ["scenario_results_missing"]

      upload_run!(
        ctx,
        run_doc(ctx.digest, "intent", sha(2), [result("S1"), result("S2")],
          merge_result: %{"base" => sha(200), "commit" => sha(901)}
        )
      )

      after_run = verdict(ctx.sk_conn, ctx.slug, other)
      assert rules(after_run) == ["scenario_results_missing"]
      assert after_run["counted_runs"] == []
    end
  end
end
