defmodule GoodFlowsWeb.Api.V1.ChangeRequestDependenciesTest do
  use GoodFlowsWeb.ConnCase, async: true
  use Mimic

  import GoodFlows.ChangeRequestFixtures
  import GoodFlows.MergeFixtures
  import GoodFlows.ReviewFixtures
  import GoodFlows.SpryFixtures
  import OpenApiSpex.TestAssertions

  alias GoodFlows.ChangeRequests.RecomputeJob
  alias GoodFlows.Repo
  alias GoodFlowsWeb.ApiSpec

  setup :api_setup

  setup ctx do
    project = project_fixture(ctx.account)
    test_pid = self()

    stub(PgFlow, :enqueue, fn RecomputeJob, input ->
      send(test_pid, {:enqueued, input})
      {:ok, Ecto.UUID.generate()}
    end)

    %{project: project, slug: project.slug}
  end

  defp put_dependencies(ctx, number, change_ids),
    do:
      put_json(ctx.sk_conn, cr_path(ctx.slug, number, "/dependencies"), %{
        "change_ids" => change_ids
      })

  defp show(ctx, number),
    do: ctx.sk_conn |> get(cr_path(ctx.slug, number)) |> json_response(200) |> Map.fetch!("data")

  defp move(ctx, number, action),
    do: ctx.sk_conn |> post(cr_path(ctx.slug, number, "/#{action}")) |> json_response(200)

  defp link(ctx, change),
    do: create_cr(ctx.sk_conn, ctx.slug, %{"change_id" => change})["number"]

  defp dependency_reasons(ctx, number),
    do: ctx.sk_conn |> verdict(ctx.slug, number) |> reasons("dependency_not_merged")

  defp run_job(input) do
    job_ctx = %PgFlow.Context{
      run_id: Ecto.UUID.generate(),
      step_slug: :recompute,
      task_index: 0,
      attempt: 1,
      repo: Repo
    }

    RecomputeJob.perform(input, job_ctx)
  end

  describe "dependencies route" do
    test "set, replace and clear; list and show carry the list; one event per change", ctx do
      number = create_cr(ctx.sk_conn, ctx.slug)["number"]
      assert show(ctx, number)["dependencies"] == []

      body = ctx |> put_dependencies(number, ["add-sessions", "add-login"]) |> json_response(200)
      assert_schema(body, "ChangeRequestResponse", ApiSpec.spec())
      assert body["data"]["dependencies"] == ["add-sessions", "add-login"]

      list = ctx.sk_conn |> get(crs_path(ctx.slug)) |> json_response(200)
      assert hd(list["data"])["dependencies"] == ["add-sessions", "add-login"]

      assert ctx |> put_dependencies(number, ["add-sessions", "add-login"]) |> json_response(200)
      assert ctx |> put_dependencies(number, ["add-login"]) |> json_response(200)
      assert ctx |> put_dependencies(number, []) |> json_response(200)
      assert show(ctx, number)["dependencies"] == []

      changes =
        for %{"type" => "cr_dependencies_changed"} = event <-
              events(ctx.sk_conn, ctx.slug)["data"] do
          assert event["number"] == number
          event["data"]
        end

      assert changes == [
               %{"from" => [], "to" => ["add-sessions", "add-login"]},
               %{"from" => ["add-sessions", "add-login"], "to" => ["add-login"]},
               %{"from" => ["add-login"], "to" => []}
             ]
    end

    test "invalid bodies are 422 on change_ids and change nothing", ctx do
      number = link(ctx, "add-login")
      assert ctx |> put_dependencies(number, ["add-sessions"]) |> json_response(200)

      for ids <- [
            ["Add_Login"],
            [""],
            [String.duplicate("a", 65)],
            ["add-sessions", "add-sessions"],
            ["add-login"],
            Enum.map(1..51, &"change-#{&1}"),
            "add-sessions",
            [1]
          ] do
        body = ctx |> put_dependencies(number, ids) |> json_response(422)
        assert [key] = Map.keys(body["errors"])
        assert key =~ ~r/^change_ids/
      end

      assert ctx.sk_conn
             |> put_json(cr_path(ctx.slug, number, "/dependencies"), %{
               "change_ids" => [],
               "extra" => 1
             })
             |> json_response(422)

      assert show(ctx, number)["dependencies"] == ["add-sessions"]
    end

    test "merged is 409 not_editable; pk_ is 403; unknown number 404", ctx do
      number = create_cr(ctx.sk_conn, ctx.slug)["number"]
      assert ctx.sk_conn |> merged(ctx.slug, number, sha(500)) |> json_response(200)

      body = ctx |> put_dependencies(number, ["add-login"]) |> json_response(409)
      assert_schema(body, "CodedConflictResponse", ApiSpec.spec())
      assert body["errors"]["error"] == "not_editable"

      assert ctx.pk_conn
             |> put_json(cr_path(ctx.slug, number, "/dependencies"), %{"change_ids" => []})
             |> json_response(403)

      assert ctx |> put_dependencies(99, []) |> json_response(404)
      assert show(ctx, number)["dependencies"] == []
    end
  end

  describe "dependency_not_merged" do
    setup ctx do
      %{dependent: mergeable!(ctx.sk_conn, ctx.slug, sha(1))}
    end

    test "no linking change request, then an open one, then only a closed one", ctx do
      assert ctx |> put_dependencies(ctx.dependent, ["add-login"]) |> json_response(200)

      v = verdict(ctx.sk_conn, ctx.slug, ctx.dependent)
      assert v["state"] == "pending"
      assert v["inputs"]["dependencies"] == ["add-login"]

      assert [%{"subject" => ["add-login"], "message" => message}] =
               reasons(v, "dependency_not_merged")

      assert message =~ "No change request links change add-login"

      linked = link(ctx, "add-login")
      assert_received {:enqueued, %{"change_id" => "add-login"}}
      run_job(%{"project_id" => ctx.project.id, "change_id" => "add-login"})

      assert [%{"message" => message}] = dependency_reasons(ctx, ctx.dependent)
      assert message =~ "change request #{linked} links it"

      move(ctx, linked, "close")
      run_job(%{"project_id" => ctx.project.id, "change_id" => "add-login"})
      assert [%{"message" => message}] = dependency_reasons(ctx, ctx.dependent)
      assert message =~ "Every change request linking change add-login is closed (#{linked})"
    end

    test "a merged linking change request in the same project satisfies it", ctx do
      linked = link(ctx, "add-login")
      assert ctx.sk_conn |> merged(ctx.slug, linked, sha(500)) |> json_response(200)
      assert ctx |> put_dependencies(ctx.dependent, ["add-login"]) |> json_response(200)
      assert verdict(ctx.sk_conn, ctx.slug, ctx.dependent)["state"] == "mergeable"
    end

    test "another project's merged change request does not", ctx do
      other = project_fixture(ctx.account)
      number = create_cr(ctx.sk_conn, other.slug, %{"change_id" => "add-login"})["number"]
      assert ctx.sk_conn |> merged(other.slug, number, sha(500)) |> json_response(200)

      assert ctx |> put_dependencies(ctx.dependent, ["add-login"]) |> json_response(200)
      assert [%{"subject" => ["add-login"]}] = dependency_reasons(ctx, ctx.dependent)
    end

    test "clearing the list removes the reason", ctx do
      assert ctx |> put_dependencies(ctx.dependent, ["add-login"]) |> json_response(200)
      assert ctx |> put_dependencies(ctx.dependent, []) |> json_response(200)
      assert verdict(ctx.sk_conn, ctx.slug, ctx.dependent)["state"] == "mergeable"
    end
  end

  describe "dependents are recomputed when a linking change request merges" do
    test "a dependent with a lower number turns mergeable through the job", ctx do
      dependent = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      other = mergeable!(ctx.sk_conn, ctx.slug, sha(2))
      assert ctx |> put_dependencies(dependent, ["add-login"]) |> json_response(200)
      assert ctx |> put_dependencies(other, ["add-sessions"]) |> json_response(200)

      linked = link(ctx, "add-login")
      assert linked > dependent
      assert_received {:enqueued, _create}
      move(ctx, linked, "ready")
      assert_received {:enqueued, _ready}

      assert ctx.sk_conn |> merged(ctx.slug, linked, sha(500)) |> json_response(200)
      project_id = ctx.project.id
      input = %{"project_id" => project_id, "change_id" => "add-login"}
      assert_received {:enqueued, ^input}

      # Not recomputed in the merge transaction: only the job clears it.
      assert verdict(ctx.sk_conn, ctx.slug, dependent)["state"] == "pending"

      assert run_job(input) == %{"recomputed" => 1}
      assert verdict(ctx.sk_conn, ctx.slug, dependent)["state"] == "mergeable"
      assert [%{"subject" => ["add-sessions"]}] = dependency_reasons(ctx, other)
    end

    test "a merge with no dependents enqueues nothing", ctx do
      linked = link(ctx, "add-login")
      unlinked = create_cr(ctx.sk_conn, ctx.slug)["number"]
      assert ctx.sk_conn |> merged(ctx.slug, linked, sha(500)) |> json_response(200)
      assert ctx.sk_conn |> merged(ctx.slug, unlinked, sha(501)) |> json_response(200)
      refute_received {:enqueued, _input}
    end

    test "merged and closed dependents are not recomputed", ctx do
      closed = mergeable!(ctx.sk_conn, ctx.slug, sha(1))
      assert ctx |> put_dependencies(closed, ["add-login"]) |> json_response(200)
      move(ctx, closed, "close")

      assert run_job(%{"project_id" => ctx.project.id, "change_id" => "add-login"}) ==
               %{"recomputed" => 0}
    end
  end
end
