defmodule GoodFlows.MergeLeasesTest do
  use GoodFlowsWeb.ConnCase, async: true

  import Ecto.Query
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.MergeFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.ChangeRequests
  alias GoodFlows.MergeLeases
  alias GoodFlows.MergeLeases.{ExpiryJob, Lease}
  alias GoodFlows.ProjectEvents.Event
  alias GoodFlows.Repo

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    %{project: project, slug: project.slug}
  end

  defp cr!(ctx, number) do
    {:ok, change_request} = ChangeRequests.get(ctx.project, number)
    change_request
  end

  defp body(head, base \\ sha(0)), do: %{"head" => head, "base" => base}

  defp acquire_ctx(ctx, number, head, base \\ sha(0)),
    do: MergeLeases.acquire(cr!(ctx, number), ctx.sk_key, body(head, base))

  defp other_key(ctx) do
    owner = Repo.preload(ctx.sk_key, :account_user).account_user
    {key, _token} = GoodFlows.AccountsFixtures.api_key_fixture(owner, %{type: :private})
    key
  end

  defp move_expiry!(lease_id, seconds_from_now) do
    at = DateTime.add(DateTime.utc_now(), seconds_from_now, :second)
    {1, _} = Repo.update_all(from(l in Lease, where: l.id == ^lease_id), set: [expires_at: at])
    at
  end

  defp events(type), do: Repo.all(from e in Event, where: e.type == ^type, order_by: e.id)

  describe "Lease.acquire_changeset/2" do
    test "accepts 40 and 64 hex and rejects a malformed base or head" do
      valid = %Lease{
        project_id: Ecto.UUID.generate(),
        change_request_id: Ecto.UUID.generate(),
        target_branch: "main",
        ttl_seconds: 600,
        acquired_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now()
      }

      assert Lease.acquire_changeset(valid, %{head: sha(1), base: String.duplicate("a", 64)}).valid?

      for base <- ["main", String.duplicate("AB", 20), "abc123", String.duplicate("a", 41)] do
        changeset = Lease.acquire_changeset(valid, %{head: sha(1), base: base})
        refute changeset.valid?
        assert {_message, _} = changeset.errors[:base]
      end

      refute Lease.acquire_changeset(valid, %{head: "HEAD", base: sha(0)}).valid?
    end
  end

  describe "acquire/3" do
    test "an open, mergeable change request at its head gets a lease for the default TTL",
         ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))

      assert {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1), sha(9))
      assert %Lease{state: "active", target_branch: "main", head: head, base: base} = lease
      assert head == sha(1) and base == sha(9)
      assert lease.ttl_seconds == 600
      assert DateTime.diff(lease.expires_at, lease.acquired_at, :second) == 600
      assert lease.api_key_id == ctx.sk_key.id
      assert lease.account_user_id == ctx.sk_key.account_user_id
    end

    test "the TTL comes from the policy current at acquire", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"merge" => %{"lease_ttl" => "3m"}})
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))

      assert {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1))
      assert DateTime.diff(lease.expires_at, lease.acquired_at, :microsecond) == 180_000_000
    end

    test "a draft or closed change request is not_open", ctx do
      number = create_cr(ctx.sk_conn, ctx.slug)["number"]
      facts!(ctx.sk_conn, ctx.slug, number, sha(1))
      claims!(ctx.sk_conn, ctx.slug, number, sha(1), %{"cr" => number})
      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "mergeable"

      assert {:error, {:coded_conflict, "not_open", %{}}} = acquire_ctx(ctx, number, sha(1))

      _ = ctx.sk_conn |> post(cr_path(ctx.slug, number, "/close")) |> json_response(200)
      assert {:error, {:coded_conflict, "not_open", %{}}} = acquire_ctx(ctx, number, sha(1))
      assert Repo.aggregate(Lease, :count) == 0
    end

    test "a head that is not the last reported head is stale_head with the current head", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(2))

      assert {:error, {:coded_conflict, "stale_head", %{head: head}}} =
               acquire_ctx(ctx, number, sha(1))

      assert head == sha(2)
    end

    test "a verdict other than mergeable is not_mergeable with its state", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{
        "paths" => [%{"glob" => "app/priv/repo/migrations/**", "outcome" => "needs_review"}]
      })

      number =
        mergeable!(ctx.sk_conn, ctx.slug, sha(1), files: [file("app/priv/repo/migrations/1.exs")])

      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "needs_review"

      assert {:error, {:coded_conflict, "not_mergeable", %{state: "needs_review"}}} =
               acquire_ctx(ctx, number, sha(1))

      assert Repo.aggregate(Lease, :count) == 0
    end

    test "a taken slot is slot_taken with the holder's number and expiry and no lease id", ctx do
      a = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      b = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      {:ok, :created, lease} = acquire_ctx(ctx, a, sha(1))

      assert {:error, {:coded_conflict, "slot_taken", %{holder: holder} = extra}} =
               acquire_ctx(ctx, b, sha(2))

      assert holder == %{change_request: a, expires_at: DateTime.to_iso8601(lease.expires_at)}
      refute Map.has_key?(extra, :id)
      refute inspect(extra) =~ lease.id
    end

    test "the holding key asking again gets the same lease and records nothing", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1))
      acquired = length(events("lease_acquired"))

      assert {:ok, :retry, again} = acquire_ctx(ctx, number, sha(1))
      assert again.id == lease.id
      assert again.expires_at == lease.expires_at
      assert length(events("lease_acquired")) == acquired
    end

    test "another key asking for the holding change request is slot_taken", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, :created, _lease} = acquire_ctx(ctx, number, sha(1))

      assert {:error, {:coded_conflict, "slot_taken", %{holder: %{change_request: ^number}}}} =
               MergeLeases.acquire(cr!(ctx, number), other_key(ctx), body(sha(1)))
    end

    test "a lease past expires_at frees the slot before the expiry job runs", ctx do
      a = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      b = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      {:ok, :created, l1} = acquire_ctx(ctx, a, sha(1))
      move_expiry!(l1.id, -5)

      assert {:ok, :created, l2} = acquire_ctx(ctx, b, sha(2))
      assert Repo.get!(Lease, l1.id).state == "expired"
      assert Repo.get!(Lease, l2.id).state == "active"
      assert [%Event{actor_key_id: nil, change_request_number: ^a}] = events("lease_expired")
      assert cr!(ctx, a).state == "open"

      # The expiry job finds nothing left to expire.
      assert MergeLeases.expire_due() == 0
      assert length(events("lease_expired")) == 1
    end

    test "the holder of an expired lease on a moved base reacquires before the job runs", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, :created, l1} = acquire_ctx(ctx, number, sha(1), sha(200))
      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "pending"
      move_expiry!(l1.id, -5)

      assert {:ok, :created, l2} = acquire_ctx(ctx, number, sha(1))
      assert Repo.get!(Lease, l1.id).state == "expired"
      assert Repo.get!(Lease, l2.id).state == "active"
      assert [%Event{change_request_number: ^number}] = events("lease_expired")
      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "mergeable"
    end

    test "a child acquiring over its parent's expired lease locks both and rolls back", ctx do
      parent = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      child = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      {:ok, :created, l1} = acquire_ctx(ctx, parent, sha(1))
      assert ctx.sk_conn |> put_parent(ctx.slug, child, parent) |> json_response(200)
      move_expiry!(l1.id, -5)

      # The child is pending on its open parent, so the acquire is refused
      # after both rows are locked, and the parent's lease expiry rolls back.
      assert {:error, {:coded_conflict, "not_mergeable", %{state: "pending"}}} =
               acquire_ctx(ctx, child, sha(2))

      assert Repo.get!(Lease, l1.id).state == "active"
      assert events("lease_expired") == []
    end

    test "a malformed body is 422 on the field", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))

      assert {:error, {:invalid_body, %{"base" => _}}} =
               MergeLeases.acquire(cr!(ctx, number), ctx.sk_key, body(sha(1), "main"))

      assert {:error, {:invalid_body, %{"head" => _}}} =
               MergeLeases.acquire(cr!(ctx, number), ctx.sk_key, %{"base" => sha(0)})
    end
  end

  describe "heartbeat/3 and release/3" do
    setup ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1))
      %{number: number, lease: lease}
    end

    test "a heartbeat sets expires_at to now plus the TTL", ctx do
      before = DateTime.utc_now()
      assert {:ok, lease} = MergeLeases.heartbeat(ctx.project, ctx.sk_key, ctx.lease.id)
      assert DateTime.diff(lease.expires_at, before, :second) in 599..600
      assert DateTime.after?(lease.expires_at, ctx.lease.expires_at)

      assert [%Event{data: %{"expires_at" => expires_at}, actor_key_id: key_id}] =
               events("lease_renewed")

      assert expires_at == DateTime.to_iso8601(lease.expires_at)
      assert key_id == ctx.sk_key.id
    end

    test "heartbeats keep a lease past the first hour", ctx do
      two_hours_ago = DateTime.add(DateTime.utc_now(), -7_200, :second)

      Repo.update_all(from(l in Lease, where: l.id == ^ctx.lease.id),
        set: [acquired_at: two_hours_ago]
      )

      assert {:ok, %Lease{state: "active"}} =
               MergeLeases.heartbeat(ctx.project, ctx.sk_key, ctx.lease.id)
    end

    test "a heartbeat after expiry is lease_not_active and records nothing", ctx do
      at = move_expiry!(ctx.lease.id, -30)

      assert {:error, {:coded_conflict, "lease_not_active", %{}}} =
               MergeLeases.heartbeat(ctx.project, ctx.sk_key, ctx.lease.id)

      assert Repo.get!(Lease, ctx.lease.id).expires_at == at
      assert events("lease_renewed") == []
    end

    test "unknown, malformed and other projects' lease IDs are lease_not_active", ctx do
      other = project_fixture(ctx.account)

      for {project, id} <- [
            {ctx.project, "7c0e5a1e-0000-4000-8000-000000000000"},
            {ctx.project, "not-a-uuid"},
            {other, ctx.lease.id}
          ] do
        assert {:error, {:coded_conflict, "lease_not_active", %{}}} =
                 MergeLeases.heartbeat(project, ctx.sk_key, id)

        assert {:error, {:coded_conflict, "lease_not_active", %{}}} =
                 MergeLeases.release(project, ctx.sk_key, id)
      end

      assert Repo.get!(Lease, ctx.lease.id).state == "active"
    end

    test "release frees the slot, keeps the change request open, and works once", ctx do
      assert :ok = MergeLeases.release(ctx.project, other_key(ctx), ctx.lease.id)

      assert %Lease{state: "released", release_reason: "released"} =
               Repo.get!(Lease, ctx.lease.id)

      assert cr!(ctx, ctx.number).state == "open"

      assert [%Event{data: %{"release_reason" => "released"}}] = events("lease_released")

      assert {:error, {:coded_conflict, "lease_not_active", %{}}} =
               MergeLeases.release(ctx.project, ctx.sk_key, ctx.lease.id)

      assert {:error, {:coded_conflict, "lease_not_active", %{}}} =
               MergeLeases.heartbeat(ctx.project, ctx.sk_key, ctx.lease.id)

      other = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      assert {:ok, :created, _lease} = acquire_ctx(ctx, other, sha(2))
    end

    test "an expired lease cannot be released", ctx do
      move_expiry!(ctx.lease.id, -1)

      assert {:error, {:coded_conflict, "lease_not_active", %{}}} =
               MergeLeases.release(ctx.project, ctx.sk_key, ctx.lease.id)
    end
  end

  describe "expire_due/1" do
    test "expires a lease once, with one event and the change request still open", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1))
      move_expiry!(lease.id, -60)

      assert MergeLeases.expire_due() == 1
      assert MergeLeases.expire_due() == 0
      assert Repo.get!(Lease, lease.id).state == "expired"
      assert cr!(ctx, number).state == "open"

      assert [%Event{actor_key_id: nil, actor_membership_id: nil} = event] =
               events("lease_expired")

      assert event.change_request_number == number

      assert event.data == %{
               "lease_id" => lease.id,
               "target_branch" => "main",
               "expires_at" => DateTime.to_iso8601(Repo.get!(Lease, lease.id).expires_at)
             }
    end

    test "leaves unexpired leases alone", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1))

      assert MergeLeases.expire_due() == 0
      assert Repo.get!(Lease, lease.id).state == "active"
    end

    test "recomputes the verdict without the merge-result check", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1), sha(77))

      assert %{"state" => "pending"} = v = verdict(ctx.sk_conn, ctx.slug, number)
      assert rules(v) == ["merge_result_ungraded"]

      move_expiry!(lease.id, -1)
      assert MergeLeases.expire_due() == 1

      assert %{"state" => "mergeable", "reasons" => []} = verdict(ctx.sk_conn, ctx.slug, number)
      assert cr!(ctx, number).state == "open"
    end

    test "ExpiryJob runs expire_due", ctx do
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1))
      move_expiry!(lease.id, -1)

      pgflow_ctx = %PgFlow.Context{
        run_id: Ecto.UUID.generate(),
        step_slug: :expire,
        task_index: 0,
        attempt: 1,
        repo: Repo
      }

      assert ExpiryJob.perform(%{}, pgflow_ctx) == %{"expired" => 1}
    end
  end

  describe "a held lease survives a verdict change" do
    test "a failed required workflow blocks the verdict; the lease stays active", ctx do
      policy!(ctx.sk_conn, ctx.slug, %{"evidence" => %{"required_workflows" => ["ci"]}})
      number = mergeable!(ctx.sk_conn, ctx.slug, sha(1))

      ctx.sk_conn
      |> post_json("/api/v1/projects/#{ctx.slug}/workflow-runs", run_document(sha(1), "passed"))
      |> json_response(201)

      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "mergeable"
      {:ok, :created, lease} = acquire_ctx(ctx, number, sha(1))

      failed = run_document(sha(1), "failed", started_at: "2026-11-05T13:00:00Z")

      ctx.sk_conn
      |> post_json("/api/v1/projects/#{ctx.slug}/workflow-runs", failed)
      |> json_response(201)

      assert verdict(ctx.sk_conn, ctx.slug, number)["state"] == "blocked"
      assert Repo.get!(Lease, lease.id).state == "active"

      assert {:ok, %Lease{state: "active"}} =
               MergeLeases.heartbeat(ctx.project, ctx.sk_key, lease.id)
    end
  end
end
