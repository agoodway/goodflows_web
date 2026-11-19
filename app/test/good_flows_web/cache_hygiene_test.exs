defmodule GoodFlowsWeb.CacheHygieneTest do
  # Changes global Logger level and object store config.
  use GoodFlowsWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import GoodFlows.CacheFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Caches.{Entry, ObjectStore, Sweep}
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlowsWeb.SentryScrubber

  setup :api_setup

  setup ctx do
    %{project: project_fixture(ctx.account, %{"slug" => "alpha"})}
  end

  defp queued?(object_key) do
    GoodFlows.Repo.exists?(from d in "cache_object_deletions", where: d.object_key == ^object_key)
  end

  defp at_debug(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end

  test "a lookup and a reservation at :debug never log the signature or URL", ctx do
    entry = entry_fixture(ctx.project)

    log =
      at_debug(fn ->
        body =
          ctx.sk_conn
          |> get("/api/v1/projects/alpha/caches/entries/#{entry.key}", %{"scope" => "main"})
          |> json_response(200)

        assert body["data"]["download_url"] =~ Fake.signature()

        body =
          ctx.sk_conn
          |> put_req_header("content-type", "application/json")
          |> post(
            "/api/v1/projects/alpha/caches/entries/#{hex(:k)}",
            Jason.encode!(reservation_body("x"))
          )
          |> json_response(201)

        assert body["data"]["upload_url"] =~ Fake.signature()
        send(self(), {:sentry, Sentry.Context.get_all()})
      end)

    assert log =~ "GET /api/v1/projects/alpha/caches/entries"
    refute log =~ Fake.signature()
    refute log =~ "fake-object-store.invalid"

    assert_received {:sentry, sentry}
    refute inspect(sentry) =~ Fake.signature()
  end

  test "Sentry gets no request body for cache routes" do
    conn = %{
      build_conn(:post, "/api/v1/projects/alpha/caches/entries/#{hex(:k)}")
      | body_params: %{"name" => "deps"}
    }

    assert SentryScrubber.scrub(conn) == %{}
    assert SentryScrubber.cache_route?(conn)
    refute SentryScrubber.cache_route?(build_conn(:post, "/api/v1/projects/alpha/cache-keys"))
  end

  describe "without a bucket" do
    setup do
      original = Application.get_env(:good_flows, ObjectStore)
      Application.put_env(:good_flows, ObjectStore, Keyword.put(original, :bucket, nil))
      on_exit(fn -> Application.put_env(:good_flows, ObjectStore, original) end)
    end

    test "cache routes are 503 after auth and project resolution", ctx do
      body =
        ctx.sk_conn
        |> get("/api/v1/projects/alpha/caches/entries/#{hex(:k)}")
        |> json_response(503)

      assert body["errors"]["detail"] =~ "not configured"

      assert ctx.sk_conn |> get("/api/v1/projects/alpha/caches") |> json_response(503)

      assert ctx.pk_conn
             |> get("/api/v1/projects/alpha/caches/entries/#{hex(:k)}")
             |> json_response(403)

      assert ctx.sk_conn
             |> get("/api/v1/projects/missing/caches/entries/#{hex(:k)}")
             |> json_response(404)

      assert build_conn()
             |> put_req_header("accept", "application/json")
             |> get("/api/v1/projects/alpha/caches/entries/#{hex(:k)}")
             |> json_response(401)
    end

    test "cache-key routes keep working", ctx do
      body =
        ctx.sk_conn
        |> post("/api/v1/projects/alpha/cache-keys", %{"access" => "read"})
        |> json_response(201)

      assert ctx.sk_conn |> get("/api/v1/projects/alpha/cache-keys") |> json_response(200)

      assert ctx.sk_conn
             |> delete("/api/v1/projects/alpha/cache-keys/#{body["data"]["id"]}")
             |> response(204)
    end

    test "the sweep deletes rows as usual and leaves queued objects for later", ctx do
      thirty_days_ago = DateTime.add(DateTime.utc_now(), -30, :day)
      stale = entry_fixture(ctx.project, last_accessed_at: thirty_days_ago)
      recent = entry_fixture(ctx.project)
      reservation = reservation_fixture(ctx.project, expires_at: thirty_days_ago)
      {old_key, _token} = cache_key_fixture(ctx.account, ctx.project)
      {live_key, _token} = cache_key_fixture(ctx.account, ctx.project)

      old_key
      |> Ecto.Changeset.change(
        status: :revoked,
        updated_at: DateTime.truncate(thirty_days_ago, :second)
      )
      |> GoodFlows.Repo.update!()

      assert %{
               keys_deleted: 1,
               reservations_expired: 1,
               entries_evicted: 1,
               objects_deleted: 0,
               objects_failed: 0
             } = Sweep.run()

      refute GoodFlows.Repo.get(GoodFlows.Accounts.ApiKey, old_key.id)
      assert GoodFlows.Repo.get(GoodFlows.Accounts.ApiKey, live_key.id)
      refute GoodFlows.Repo.get(Entry, stale.id)
      refute GoodFlows.Repo.get(Entry, reservation.id)
      assert GoodFlows.Repo.get(Entry, recent.id)

      # The stale entry's object stays in the store and in the queue.
      assert Fake.exists?(stale.object_key)
      assert queued?(stale.object_key)
    end
  end
end
