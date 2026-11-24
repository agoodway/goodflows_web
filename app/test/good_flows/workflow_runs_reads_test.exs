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
  @thread "https://ampcode.com/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"
  @thread_path "/threads/T-3bb6cad7-8c04-413a-b23c-5fca67cd4f7b"

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
            {%{"cursor" => "not-a-cursor"}, :cursor},
            {%{"ticket" => "GOO 1"}, :ticket},
            {%{"ticket" => ""}, :ticket},
            {%{"ticket" => "GOO-1,GOO-2"}, :ticket},
            {%{"ticket" => String.duplicate("T", 65)}, :ticket},
            {%{"thread_url" => @thread <> "?token=secret"}, :thread_url},
            {%{"thread_url" => @thread <> "#"}, :thread_url},
            {%{"thread_url" => "http://ampcode.com" <> @thread_path}, :thread_url},
            {%{"thread_url" => "https://ampcode.com:080" <> @thread_path}, :thread_url},
            {%{"thread_url" => "https://ampcode.com/a/../threads/T-1"}, :thread_url},
            {%{"thread_url" => "https://ampcode.com/threads/T-1%zz"}, :thread_url},
            {%{"thread_url" => "https://ex%61mple.com/threads/T-1"}, :thread_url},
            {%{"thread_url" => "ampcode.com/threads/T-1"}, :thread_url},
            {%{"thread_url" => ""}, :thread_url}
          ] do
        case WorkflowRuns.list_runs(ctx.account, ctx.project, params) do
          {:error, changeset} ->
            assert errors_on(changeset)[field], "#{field} for #{inspect(params)}"
            refute inspect(errors_on(changeset)) =~ "secret"

          other ->
            flunk("expected error for #{inspect(params)}, got #{inspect(other)}")
        end
      end
    end

    test "a project from another account is not found", ctx do
      assert WorkflowRuns.list_runs(ctx.other, ctx.project, %{}) == {:error, :not_found}
    end
  end

  describe "link filters" do
    test "ticket matches ignoring ASCII case and nothing else", ctx do
      store!(ctx, %{"run_id" => @early, "links" => %{"tickets" => ["GOO-291"]}})

      store!(ctx, %{
        "run_id" => @late,
        "started_at" => @today,
        "links" => %{"tickets" => ["GOO-2910", "GOO-0291"]}
      })

      for ticket <- ~w(GOO-291 goo-291 gOo-291) do
        assert ids(ctx, %{"ticket" => ticket}) == {[@early], nil}, ticket
      end

      assert ids(ctx, %{"ticket" => "GOO-29"}) == {[], nil}
      assert ids(ctx, %{"ticket" => "goo-0291"}) == {[@late], nil}
    end

    test "one ticket search returns the PR run and the main run, newest first", ctx do
      store!(ctx, %{
        "run_id" => @early,
        "started_at" => @yesterday,
        "ci" => %{"provider" => "github_actions", "event" => "pull_request", "pull_request" => 7},
        "links" => %{"threads" => [@thread], "tickets" => ["GOO-291"]}
      })

      store!(ctx, %{
        "run_id" => @mid,
        "started_at" => @today,
        "source" => %{"commit" => @commit_a, "branch" => "main"},
        "ci" => %{"provider" => "github_actions", "event" => "push"},
        "links" => %{"tickets" => ["goo-291"]}
      })

      store!(ctx, %{
        "run_id" => @late,
        "started_at" => @same,
        "source" => %{"commit" => @commit_a, "branch" => "main"},
        "links" => %{"tickets" => ["GOO-300"]}
      })

      assert ids(ctx, %{"ticket" => "GOO-291"}) == {[@mid, @early], nil}
      assert {[@mid], cursor} = ids(ctx, %{"ticket" => "GOO-291", "limit" => "1"})

      assert ids(ctx, %{"ticket" => "GOO-291", "limit" => "1", "cursor" => cursor}) ==
               {[@early], nil}

      assert ids(ctx, %{"ticket" => "GOO-291", "branch" => "main"}) == {[@mid], nil}
      assert ids(ctx, %{"ticket" => "GOO-300", "branch" => "main"}) == {[@late], nil}
      assert ids(ctx, %{"thread_url" => @thread, "branch" => "main"}) == {[], nil}
      assert ids(ctx, %{"thread_url" => @thread, "event" => "pull_request"}) == {[@early], nil}
      assert ids(ctx, %{"thread_url" => @thread, "ticket" => "goo-291"}) == {[@early], nil}

      page = page(ctx, %{"ticket" => "GOO-291"})
      assert Enum.all?(page.runs, &(&1.payload == nil))
    end

    test "thread_url matches after lowercasing scheme and host and dropping a 443 port", ctx do
      store!(ctx, %{"run_id" => @early, "links" => %{"threads" => [@thread]}})

      store!(ctx, %{
        "run_id" => @late,
        "started_at" => @today,
        "links" => %{"threads" => ["https://ampcode.com/"]}
      })

      for url <- [
            @thread,
            "HTTPS://AmpCode.com" <> @thread_path,
            "https://AMPCODE.COM:443" <> @thread_path,
            "https://ampcode.com:0443" <> @thread_path,
            "https://ampcode.com:" <> @thread_path
          ] do
        assert ids(ctx, %{"thread_url" => url}) == {[@early], nil}, url
      end

      for url <- ["https://ampcode.com", "HTTPS://AmpCode.com:443", "https://ampcode.com/"] do
        assert ids(ctx, %{"thread_url" => url}) == {[@late], nil}, url
      end

      # The path is never recased.
      assert ids(ctx, %{"thread_url" => String.upcase(@thread)}) == {[], nil}
      assert ids(ctx, %{"thread_url" => "https://ampcode.com/threads/T-other"}) == {[], nil}
    end

    test "percent triplets match only as written", ctx do
      store!(ctx, %{
        "run_id" => @early,
        "links" => %{"threads" => ["https://ampcode.com/threads/a%7Eb"]}
      })

      assert ids(ctx, %{"thread_url" => "https://ampcode.com/threads/a%7Eb"}) == {[@early], nil}
      assert ids(ctx, %{"thread_url" => "https://ampcode.com/threads/a%7eb"}) == {[], nil}
      assert ids(ctx, %{"thread_url" => "https://ampcode.com/threads/a~b"}) == {[], nil}
    end

    test "a run without links never matches a link filter", ctx do
      store!(ctx, %{"run_id" => @early})
      stored_run(ctx.account, ctx.project, %{run_id: @late})

      assert {[_, _], nil} = ids(ctx)
      assert ids(ctx, %{"ticket" => "GOO-291"}) == {[], nil}
      assert ids(ctx, %{"thread_url" => @thread}) == {[], nil}
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

  describe "latest_clean_by_workflow/2" do
    defp at!(ctx, workflow, outcome, started_at, attrs \\ %{}) do
      run_id = Ecto.UUID.generate()

      stored_run(
        ctx.account,
        ctx.project,
        Map.merge(
          %{
            run_id: run_id,
            workflow: workflow,
            outcome: outcome,
            started_at: started_at,
            source_commit: @commit_a
          },
          attrs
        )
      )

      run_id
    end

    defp latest(ctx, commit \\ @commit_a),
      do:
        ctx.project
        |> WorkflowRuns.latest_clean_by_workflow(commit)
        |> Enum.map(&{&1.workflow, &1.run_id})

    test "a retried workflow shows its newest run, one row per workflow", ctx do
      _failed = at!(ctx, "ci", "failed", ~U[2026-11-05 10:00:00Z])
      passed = at!(ctx, "ci", "passed", ~U[2026-11-05 11:00:00Z])
      lint = at!(ctx, "lint", "passed", ~U[2026-11-05 09:00:00Z])

      assert latest(ctx) == [{"ci", passed}, {"lint", lint}]
    end

    test "a dirty newest run gives way to the older clean one; unknown dirt is clean", ctx do
      clean = at!(ctx, "ci", "passed", ~U[2026-11-05 10:00:00Z], %{source_dirty: nil})
      _dirty = at!(ctx, "ci", "failed", ~U[2026-11-05 11:00:00Z], %{source_dirty: true})

      assert latest(ctx) == [{"ci", clean}]
    end

    test "runs on another commit or project are not shown", ctx do
      _other_commit =
        at!(ctx, "ci", "passed", ~U[2026-11-05 10:00:00Z], %{source_commit: @commit_b})

      stored_run(ctx.other, ctx.other_project, %{source_commit: @commit_a})

      assert latest(ctx) == []

      assert [%Run{workflow: "ci", outcome: "passed"}] =
               WorkflowRuns.latest_clean_by_workflow(ctx.project, @commit_b)
    end
  end
end
