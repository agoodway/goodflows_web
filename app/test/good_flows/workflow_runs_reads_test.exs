defmodule GoodFlows.WorkflowRunsReadsTest do
  use GoodFlows.DataCase, async: true

  import GoodFlows.AccountsFixtures
  import GoodFlows.SpryFixtures
  import GoodFlows.TestReportFixtures
  import GoodFlows.WorkflowRunFixtures

  alias GoodFlows.WorkflowRuns
  alias GoodFlows.WorkflowRuns.Run

  @early "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @mid "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @late "ffffffff-ffff-4fff-8fff-ffffffffffff"
  @extra "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @yesterday "2026-11-05T12:00:00Z"
  @today "2026-11-06T12:00:00Z"
  @same "2026-11-05T15:00:00Z"
  @graph_a String.duplicate("ab", 32)
  @graph_b String.duplicate("cd", 32)
  @commit_a String.duplicate("ab", 20)
  @commit_b String.duplicate("cd", 32)

  setup do
    account = account_fixture()
    other = account_fixture()

    %{
      account: account,
      other: other,
      project: project_fixture(account),
      other_project: project_fixture(other)
    }
  end

  defp doc(attrs), do: Map.merge(minimal(), attrs)

  defp store!(ctx, attrs) do
    {:ok, ack} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, doc(attrs))
    ack
  end

  defp page(ctx, params \\ %{}) do
    assert {:ok, page} = WorkflowRuns.list_runs(ctx.account, ctx.project, params)
    page
  end

  defp ids(ctx, params \\ %{}) do
    page = page(ctx, params)
    {Enum.map(page.runs, & &1.run_id), page.next_cursor}
  end

  describe "list_runs/3" do
    test "a late upload of an older run sorts below a newer one", ctx do
      store!(ctx, %{"run_id" => @late, "started_at" => @today})
      store!(ctx, %{"run_id" => @early, "started_at" => @yesterday})

      assert ids(ctx) == {[@late, @early], nil}
    end

    test "equal started_at values break ties by run_id descending", ctx do
      store!(ctx, %{"run_id" => @early, "started_at" => @same})
      store!(ctx, %{"run_id" => @late, "started_at" => @same})

      assert ids(ctx) == {[@late, @early], nil}
    end

    test "pages with limit 2 and does not repeat or skip a run inserted onto the first page",
         ctx do
      store!(ctx, %{"run_id" => @early, "started_at" => "2026-11-05T12:00:01Z"})
      store!(ctx, %{"run_id" => @mid, "started_at" => "2026-11-05T12:00:02Z"})
      store!(ctx, %{"run_id" => @late, "started_at" => "2026-11-05T12:00:03Z"})

      assert {[@late, @mid], cursor} = ids(ctx, %{"limit" => "2"})
      assert is_binary(cursor)

      # Sorts onto the first page: same start as @late, smaller run_id.
      store!(ctx, %{"run_id" => @extra, "started_at" => "2026-11-05T12:00:03Z"})

      assert {[@early], nil} == ids(ctx, %{"limit" => "2", "cursor" => cursor})
    end

    test "each filter matches alone, and workflow plus graph_sha256 combine", ctx do
      store!(ctx, %{
        "run_id" => @early,
        "workflow" => "ci",
        "environment" => "ci",
        "outcome" => "passed",
        "graph_sha256" => @graph_a,
        "source" => %{"commit" => @commit_a}
      })

      store!(ctx, %{
        "run_id" => @late,
        "started_at" => @today,
        "workflow" => "other",
        "environment" => "prod",
        "outcome" => "cancelled",
        "graph_sha256" => @graph_b,
        "source" => %{"commit" => @commit_b, "dirty" => false}
      })

      assert ids(ctx, %{"workflow" => "ci"}) == {[@early], nil}
      assert ids(ctx, %{"environment" => "prod"}) == {[@late], nil}
      assert ids(ctx, %{"outcome" => "cancelled"}) == {[@late], nil}
      assert ids(ctx, %{"commit" => @commit_a}) == {[@early], nil}
      assert ids(ctx, %{"graph_sha256" => @graph_b}) == {[@late], nil}

      assert ids(ctx, %{"workflow" => "ci", "graph_sha256" => @graph_a}) == {[@early], nil}
      assert ids(ctx, %{"workflow" => "ci", "graph_sha256" => @graph_b}) == {[], nil}
    end

    test "an unknown query parameter is ignored", ctx do
      store!(ctx, %{"run_id" => @early})
      assert ids(ctx, %{"color" => "blue"}) == {[@early], nil}
    end

    test "a commit without dirty keeps source_dirty unset, and summaries omit payload", ctx do
      store!(ctx, %{"run_id" => @early, "source" => %{"commit" => @commit_a}})
      store!(ctx, %{"run_id" => @late, "started_at" => @today})

      page = page(ctx)
      assert Enum.all?(page.runs, &(&1.payload == nil))

      with_source = Enum.find(page.runs, &(&1.run_id == @early))
      assert with_source.source_commit == @commit_a
      assert with_source.source_dirty == nil
      assert with_source.host == %{"os" => "linux", "arch" => "x86_64", "logical_cpus" => 1}
      refute Map.has_key?(with_source.host, "mem_total_bytes")

      without_source = Enum.find(page.runs, &(&1.run_id == @late))
      assert without_source.environment == nil
      assert without_source.source_commit == nil
    end

    test "bad filters, limit and cursor are 422 on that parameter", ctx do
      long = String.duplicate("a", 65)

      for {params, field} <- [
            {%{"outcome" => "green"}, :outcome},
            {%{"workflow" => long}, :workflow},
            {%{"environment" => "   "}, :environment},
            {%{"commit" => "ABC"}, :commit},
            {%{"graph_sha256" => "abc"}, :graph_sha256},
            {%{"limit" => "0"}, :limit},
            {%{"limit" => "201"}, :limit},
            {%{"limit" => "nope"}, :limit},
            {%{"cursor" => "not-a-cursor"}, :cursor}
          ] do
        case WorkflowRuns.list_runs(ctx.account, ctx.project, params) do
          {:error, changeset} ->
            assert errors_on(changeset)[field], "#{field} for #{inspect(params)}"

          other ->
            flunk("expected error for #{inspect(params)}, got #{inspect(other)}")
        end
      end
    end

    test "a project from another account is not found", ctx do
      assert WorkflowRuns.list_runs(ctx.other, ctx.project, %{}) == {:error, :not_found}
    end
  end

  describe "get_run/3" do
    test "returns the stored document and 404s for another project, account or uppercase id",
         ctx do
      document = Map.put(full(), "run_id", "abcdefab-cdef-4abc-8def-abcdefabcdef")
      {:ok, %{id: id}} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, document)

      assert {:ok, %{run: %Run{id: ^id, payload: payload}}} =
               WorkflowRuns.get_run(ctx.account, ctx.project, document["run_id"])

      assert payload == document

      other = project_fixture(ctx.account)
      assert WorkflowRuns.get_run(ctx.account, other, document["run_id"]) == {:error, :not_found}

      assert WorkflowRuns.get_run(ctx.other, ctx.other_project, document["run_id"]) ==
               {:error, :not_found}

      upper = String.upcase(document["run_id"])
      assert WorkflowRuns.get_run(ctx.account, ctx.project, upper) == {:error, :not_found}
    end

    test "lists test reports stored earlier, ignores another project, and omits contents", ctx do
      run_id = minimal()["run_id"]

      first =
        "complete"
        |> report()
        |> Map.put("workflow_run_id", run_id)
        |> Map.put("job", "zzz")
        |> with_report_id("aaa-report")

      second =
        "complete"
        |> report()
        |> Map.put("workflow_run_id", run_id)
        |> Map.put("job", "aaa")
        |> with_report_id("zzz-report")

      stored_report_fixture(ctx.account, ctx.project, first)
      stored_report_fixture(ctx.account, ctx.project, second)

      elsewhere = project_fixture(ctx.account)

      "complete"
      |> report()
      |> Map.put("workflow_run_id", run_id)
      |> Map.put("job", "mmm")
      |> with_report_id("mmm-report")
      |> then(&stored_report_fixture(ctx.account, elsewhere, &1))

      {:ok, _} = WorkflowRuns.ingest(ctx.account, ctx.project, nil, minimal())

      assert {:ok, %{test_reports: [alpha, zed]}} =
               WorkflowRuns.get_run(ctx.account, ctx.project, run_id)

      assert alpha.job == "aaa"
      assert alpha.report_id == "zzz-report"
      assert zed.job == "zzz"
      assert zed.report_id == "aaa-report"

      for report <- [alpha, zed] do
        assert report.payload == nil
        assert report.payload_digest == nil
        assert report.workflow_run_id == nil
        assert report.account_id == nil
        refute inspect(report) =~ "adds numbers"
        assert report.job_status
        assert report.suite_id
        assert report.status in ["complete", "incomplete"]
      end
    end
  end
end
