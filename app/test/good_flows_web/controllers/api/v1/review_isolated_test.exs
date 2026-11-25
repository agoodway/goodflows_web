defmodule GoodFlowsWeb.Api.V1.ReviewIsolatedTest do
  # Not async: these tests add a trigger and change the object store config.
  use GoodFlowsWeb.ConnCase, async: false

  import Ecto.Query
  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.GradingFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures

  alias GoodFlows.Caches.ObjectStore
  alias GoodFlows.Caches.ObjectStore.Fake
  alias GoodFlows.ProjectEvents.Event
  alias GoodFlows.Repo
  alias GoodFlows.Review.{Answer, Task}

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    _ = create_cr(ctx.sk_conn, project.slug, %{"change_id" => "add-export"})
    facts!(ctx.sk_conn, project.slug, 1, sha(1))
    %{project: project}
  end

  test "an answer that fails after its row is written leaves no answer and no event", ctx do
    slug = ctx.project.slug
    claims!(ctx.sk_conn, slug, 1, sha(1), %{"cr" => 1, "door" => "one_way"})
    door = item!(packet(ctx.sk_conn, slug, 1), "one_way_door")

    # The task insert comes after the answer row and its `answer_recorded`
    # event; failing it rolls the whole answer back.
    Repo.query!("""
    CREATE FUNCTION review_test_fail() RETURNS trigger AS $$
    BEGIN RAISE EXCEPTION 'forced failure'; END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER review_test_fail BEFORE INSERT ON review_tasks
    FOR EACH ROW EXECUTE FUNCTION review_test_fail()
    """)

    assert_raise Postgrex.Error, ~r/forced failure/, fn ->
      answer(ctx.sk_conn, slug, 1, door["id"], %{
        "head" => sha(1),
        "answer" => "request_change",
        "note" => "add a down migration"
      })
    end

    assert Repo.aggregate(Answer, :count) == 0
    assert Repo.aggregate(Task, :count) == 0
    assert Repo.all(from e in Event, where: e.type == "answer_recorded") == []
    assert item!(packet(ctx.sk_conn, slug, 1), "one_way_door")["answer"] == nil
  end

  test "without object storage an artifact has url and expires_at null", ctx do
    slug = ctx.project.slug
    claims!(ctx.sk_conn, slug, 1, sha(1), %{"cr" => 1})

    digest =
      ctx.sk_conn
      |> post_json(
        cr_path(slug, 1, "/scenario-sets"),
        set_body(intent_fm("add-export", [scenario("S1"), scenario("S2", "should")]))
      )
      |> json_response(201)
      |> get_in(["data", "digest"])

    shot = "png bytes"

    doc =
      run_doc(digest, "intent", sha(1), [result("S1"), result("S2", "failed", ["shot-1"])],
        artifacts: [artifact("shot-1", shot)]
      )

    runs = "/api/v1/projects/#{slug}/verify-runs"
    ack = ctx.sk_conn |> post_json(runs, doc) |> json_response(201)
    [upload] = ack["data"]["uploads"]
    :ok = Fake.put(upload["upload_url"], upload["upload_headers"], shot)
    _ = ctx.sk_conn |> post_json(runs <> "/#{doc["run_id"]}/commit", %{}) |> json_response(200)

    config = Application.get_env(:good_flows, ObjectStore)
    on_exit(fn -> Application.put_env(:good_flows, ObjectStore, config) end)
    Application.put_env(:good_flows, ObjectStore, Keyword.put(config, :bucket, nil))

    [artifact] = item!(packet(ctx.sk_conn, slug, 1), "failed_scenario")["data"]["artifacts"]
    assert %{"id" => "shot-1", "url" => nil, "expires_at" => nil, "expired" => false} = artifact
  end
end
