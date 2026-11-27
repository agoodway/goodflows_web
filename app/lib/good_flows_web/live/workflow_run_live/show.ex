defmodule GoodFlowsWeb.WorkflowRunLive.Show do
  @moduledoc """
  One workflow run: its summary, every job (failures first, or in result
  order), the runs it called and the run that called it, the failed tests
  of its test reports, its test report summaries (each linking to
  `GoodFlowsWeb.TestReportLive.Show`) and the change requests
  whose head is its commit. Every account member sees every field,
  including commands, errors and thread links. It writes nothing.

  `run_id` must be a lowercase canonical UUID
  (`GoodFlows.WorkflowRuns.Validator.canonical_uuid?/1`); any other
  spelling, or a run of another project, redirects to the project's run
  list with `Run not found`. Failed tests load with `start_async` after
  the summary and jobs render (design D5). A stored run never changes, so
  the page does not refresh.
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.ChangeRequestComponents
  import GoodFlowsWeb.WorkflowRunComponents

  alias GoodFlows.ChangeRequests
  alias GoodFlows.Projects
  alias GoodFlows.TestReports
  alias GoodFlows.WorkflowRuns
  alias GoodFlows.WorkflowRuns.Validator
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(%{"slug" => slug, "run_id" => run_id}, _session, socket) do
    account = socket.assigns.current_account
    projects = ~p"/dashboard/accounts/#{account.id}/projects"

    with {:project, {:ok, project}} <- {:project, Projects.get_project(account, slug)},
         true <- Validator.canonical_uuid?(run_id),
         {:ok, %{run: run, test_reports: reports}} <-
           WorkflowRuns.get_run(account, project, run_id) do
      {:ok,
       socket
       |> assign(
         page_title: "Run #{String.slice(run_id, 0, 8)} · #{project.slug}",
         active_nav: :projects,
         project: project,
         breadcrumbs: [
           %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
           %{label: "Projects", to: projects},
           %{label: project.slug, to: ~p"/dashboard/accounts/#{account.id}/projects/#{slug}"},
           %{label: "Runs", to: ~p"/dashboard/accounts/#{account.id}/projects/#{slug}/runs"},
           %{label: String.slice(run_id, 0, 8)}
         ],
         run: run,
         doc: run.payload,
         reports: reports,
         order: :failures_first,
         linked: stored_linked_run_ids(project, run),
         change_requests: ChangeRequests.at_head(project, run.source_commit)
       )
       |> assign_async_failed(account, project, run_id)}
    else
      {:project, {:error, :not_found}} ->
        {:ok, socket |> put_flash(:error, "Project not found") |> push_navigate(to: projects)}

      _not_found ->
        {:ok,
         socket
         |> put_flash(:error, "Run not found")
         |> push_navigate(to: ~p"/dashboard/accounts/#{account.id}/projects/#{slug}/runs")}
    end
  end

  defp assign_async_failed(socket, account, project, run_id) do
    socket
    |> assign(:failed_tests, AsyncResult.loading())
    |> start_async(:failed_tests, fn -> TestReports.failed_tests(account, project, run_id) end)
  end

  @impl true
  def handle_async(:failed_tests, {:ok, results}, socket),
    do:
      {:noreply,
       assign(socket, :failed_tests, AsyncResult.ok(socket.assigns.failed_tests, results))}

  def handle_async(:failed_tests, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, :failed_tests, AsyncResult.failed(socket.assigns.failed_tests, reason))}

  defp stored_linked_run_ids(project, run) do
    child_ids = for %{"child_run_id" => id} <- results(run.payload), is_binary(id), do: id
    ids = Enum.reject([run.parent_run_id | child_ids], &is_nil/1)
    project |> WorkflowRuns.summaries(ids) |> MapSet.new(& &1.run_id)
  end

  @impl true
  def handle_event("order", %{"order" => order}, socket) when order in ~w(failures_first results),
    do: {:noreply, assign(socket, order: String.to_existing_atom(order))}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, jobs: jobs(assigns.doc, assigns.order))

    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-play-circle">
        <span class="inline-flex flex-wrap items-center gap-2">
          <span id="run-workflow" class="font-mono">{@run.workflow}</span>
          <span id="run-outcome"><.outcome_badge outcome={@run.outcome} /></span>
        </span>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-1">
            Run <code id="run-id" class="break-all">{@run.run_id}</code>
            <.copy_button id="copy-run-id" value={@run.run_id} label="Copy run ID" />
          </span>
        </:subtitle>
      </.header>

      <.panel id="summary-panel" title="Summary" icon="hero-document-text">
        <.list>
          <:item title="Started">
            <span id="summary-started" class="font-mono">{format_time(@run.started_at)}</span>
          </:item>
          <:item title="Duration">
            <span id="summary-duration" class="font-mono">{duration(@run.duration_ms)}</span>
          </:item>
          <:item :if={@run.environment} title="Environment">
            <span id="summary-environment"><.tag>{@run.environment}</.tag></span>
          </:item>
          <:item :if={@run.source_commit} title="Commit">
            <span id="summary-commit" class="inline-flex items-center justify-end gap-1">
              <code class="break-all font-mono">{@run.source_commit}</code>
              <span :if={@run.source_dirty} id="summary-dirty" class="run-row-dirty">dirty</span>
              <.copy_button id="copy-commit" value={@run.source_commit} label="Copy commit" />
            </span>
          </:item>
          <:item :if={@run.source_branch} title="Branch">
            <span id="summary-branch"><.tag>{@run.source_branch}</.tag></span>
          </:item>
          <:item :if={@run.ci} title="CI">
            <span id="summary-ci" class="inline-flex flex-wrap items-center justify-end gap-2">
              <span>{trigger(@run.ci)}</span>
              <span :if={@run.ci["provider"]} class="text-muted">{@run.ci["provider"]}</span>
              <.text_link :if={ci_url(@run.ci)} id="summary-ci-link" href={ci_url(@run.ci)}>
                CI run
              </.text_link>
            </span>
          </:item>
          <:item title="Host">
            <span id="summary-host" class="font-mono">{host(@run.host)}</span>
          </:item>
          <:item title="Parallelism">
            <span class="font-mono">{@run.parallelism} · max in flight {@run.max_in_flight}</span>
          </:item>
          <:item title="Graph">
            <code class="break-all font-mono">{@run.graph_sha256}</code>
          </:item>
          <:item :if={@doc["requested_jobs"] not in [nil, []]} title="Requested jobs">
            <span id="summary-requested" class="inline-flex flex-wrap justify-end gap-1">
              <.tag :for={job <- @doc["requested_jobs"]}>{job}</.tag>
            </span>
          </:item>
          <:item :if={tickets(@doc) != []} title="Tickets">
            <span id="summary-tickets" class="inline-flex flex-wrap justify-end gap-1">
              <.tag :for={ticket <- tickets(@doc)}>{ticket}</.tag>
            </span>
          </:item>
          <:item :if={threads(@doc) != []} title="Threads">
            <span id="summary-threads" class="flex flex-col items-end gap-1">
              <.text_link :for={thread <- threads(@doc)} href={thread}>
                <span class="break-all">{thread}</span>
              </.text_link>
            </span>
          </:item>
          <:item :if={@run.parent_run_id} title="Called by">
            <span id="summary-parent">
              <%= if MapSet.member?(@linked, @run.parent_run_id) do %>
                <.text_link
                  id="parent-link"
                  navigate={run_path(@current_account, @project, @run.parent_run_id)}
                >
                  {String.slice(@run.parent_run_id, 0, 8)}
                </.text_link>
                <span :if={@doc["caller_job"]} class="text-muted">
                  job <code>{@doc["caller_job"]}</code>
                </span>
              <% else %>
                <span id="parent-missing" class="text-muted">
                  A run that was not uploaded ({String.slice(@run.parent_run_id, 0, 8)})
                </span>
              <% end %>
            </span>
          </:item>
          <:item title="Stored">
            <span class="font-mono">{format_time(@run.inserted_at)}</span>
          </:item>
        </.list>
      </.panel>

      <.panel id="jobs-panel" title="Jobs" icon="hero-queue-list">
        <:actions>
          <div class="flex gap-1 normal-case tracking-normal" role="group" aria-label="Job order">
            <.button
              id="order-failures-first"
              type="button"
              variant={if @order == :failures_first, do: "soft", else: "ghost"}
              size="sm"
              phx-click="order"
              phx-value-order="failures_first"
              aria-pressed={to_string(@order == :failures_first)}
            >
              Failures first
            </.button>
            <.button
              id="order-results"
              type="button"
              variant={if @order == :results, do: "soft", else: "ghost"}
              size="sm"
              phx-click="order"
              phx-value-order="results"
              aria-pressed={to_string(@order == :results)}
            >
              Result order
            </.button>
          </div>
        </:actions>
        <p :if={@jobs == []} id="no-jobs" class="text-sm text-muted">The run has no jobs.</p>
        <ol :if={@jobs != []} id="jobs" class="-my-2">
          <li
            :for={{job, index} <- Enum.with_index(@jobs)}
            id={"job-#{index}"}
            data-name={job["name"]}
            class="border-b border-base-300 py-2 last:border-b-0"
          >
            <details class="group" open={job["status"] in ~w(failed timed_out)}>
              <summary class="flex cursor-pointer list-none flex-wrap items-center gap-x-3 gap-y-1 rounded-sm py-1">
                <.icon
                  name="hero-chevron-right-micro"
                  class="size-4 shrink-0 text-muted transition-transform group-open:rotate-90"
                />
                <.job_status_badge status={job["status"]} />
                <span class="min-w-0 wrap-anywhere font-mono text-sm font-medium">{job["name"]}</span>
                <.tag :if={job["partition"]}>
                  {job["partition"]["index"]}/{job["partition"]["count"]}
                </.tag>
                <span :if={job["workflow"]} class="text-xs text-muted">
                  calls <code>{job["workflow"]}</code>
                </span>
                <span class="ml-auto flex flex-wrap gap-3 font-mono text-xs text-muted">
                  <span :if={job["duration_ms"]}>{duration(job["duration_ms"])}</span>
                  <span :if={(job["queued_ms"] || 0) > 0}>queued {duration(job["queued_ms"])}</span>
                  <span :if={(job["blocked_ms"] || 0) > 0}>
                    blocked {duration(job["blocked_ms"])}
                  </span>
                  <span :if={job["exit_code"] != nil} id={"job-#{index}-exit"}>
                    exit {job["exit_code"]}
                  </span>
                </span>
              </summary>
              <div class="mt-2 space-y-3 pl-6">
                <p :if={job["status"] == "not_run"} class="text-xs text-muted">
                  The graph has this job, but the run recorded no result for it.
                </p>
                <div :if={job["child_run_id"]} id={"job-#{index}-child"} class="text-xs">
                  <%= if MapSet.member?(@linked, job["child_run_id"]) do %>
                    Called run
                    <.text_link
                      id={"job-#{index}-child-link"}
                      navigate={run_path(@current_account, @project, job["child_run_id"])}
                    >
                      {String.slice(job["child_run_id"], 0, 8)}
                    </.text_link>
                  <% else %>
                    <span class="text-muted">
                      The called run ({String.slice(job["child_run_id"], 0, 8)}) was not uploaded.
                    </span>
                  <% end %>
                </div>
                <.code_block
                  :if={job["command"]}
                  id={"job-#{index}-command"}
                  title="Command"
                  class="code-block-wrap"
                >
                  <:source>{job["command"]}</:source>
                </.code_block>
                <.code_block
                  :if={job["error"]}
                  id={"job-#{index}-error"}
                  title="Error"
                  class="code-block-wrap"
                >
                  <:source>{job["error"]}</:source>
                </.code_block>
                <.table
                  :if={(job["commands"] || []) != []}
                  id={"job-#{index}-steps"}
                  rows={job["commands"]}
                >
                  <:col :let={step} label="Step">
                    <span class="font-mono text-xs">{step["step"] || step["kind"]}</span>
                  </:col>
                  <:col :let={step} label="Wall">
                    <span class="font-mono text-xs">{duration(step["wall_ms"])}</span>
                  </:col>
                  <:col :let={step} label="CPU">
                    <span class="font-mono text-xs">
                      {duration((step["cpu_user_ms"] || 0) + (step["cpu_system_ms"] || 0))}
                    </span>
                  </:col>
                  <:col :let={step} label="Peak memory">
                    <span class="font-mono text-xs">{bytes(step["peak_rss_bytes"])}</span>
                  </:col>
                </.table>
              </div>
            </details>
          </li>
        </ol>
      </.panel>

      <.panel id="failed-tests-panel" title="Failed tests" icon="hero-beaker">
        <.async_result :let={results} assign={@failed_tests}>
          <:loading>
            <p id="failed-tests-loading" class="text-sm text-muted">Reading the test reports…</p>
          </:loading>
          <:failed>
            <p id="failed-tests-error" class="text-sm text-muted">
              The failed tests could not be read. Reload the page to try again.
            </p>
          </:failed>
          <p :if={results == []} id="no-test-reports" class="text-sm text-muted">
            No test report was uploaded for this run.
          </p>
          <div :if={results != []} class="space-y-6">
            <section
              :for={result <- results}
              id={"report-#{result.report.id}"}
              class="space-y-2"
            >
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="font-mono text-sm font-semibold">
                  <.text_link
                    id={"report-#{result.report.id}-link"}
                    navigate={report_path(@current_account, @project, @run.run_id, result.report.id)}
                  >
                    {result.report.job}
                  </.text_link>
                </h3>
                <.tag :if={result.report.partition}>
                  partition {partition(result.report)}
                </.tag>
                <span
                  :if={result.report.status == "incomplete"}
                  id={"report-#{result.report.id}-incomplete"}
                >
                  <.status_badge dot>Incomplete report</.status_badge>
                </span>
                <span class="ml-auto text-xs text-muted">
                  {count_label(result.failed_total, "failed test", "failed tests")}
                </span>
              </div>
              <p
                :if={result.report.status == "incomplete"}
                class="text-xs text-muted"
              >
                The report stopped before the suite finished, so more tests may have failed.
              </p>
              <ul :if={result.failed != []} class="list-table">
                <.test_row
                  :for={{test, i} <- Enum.with_index(result.failed)}
                  id={"report-#{result.report.id}-failed-#{i}"}
                  test={test}
                />
              </ul>
              <p
                :if={result.failed_total > length(result.failed)}
                id={"report-#{result.report.id}-more"}
                class="text-xs text-muted"
              >
                {count_label(
                  result.failed_total - length(result.failed),
                  "more failed test is not shown.",
                  "more failed tests are not shown."
                )}
              </p>
              <div :if={result.retried != []} id={"report-#{result.report.id}-retried"}>
                <h4 class="mb-2 font-mono text-xs font-semibold uppercase tracking-wide text-muted">
                  Passed on retry
                </h4>
                <ul class="list-table">
                  <.test_row
                    :for={{test, i} <- Enum.with_index(result.retried)}
                    id={"report-#{result.report.id}-retried-#{i}"}
                    test={test}
                  />
                </ul>
                <p
                  :if={result.retried_total > length(result.retried)}
                  id={"report-#{result.report.id}-retried-more"}
                  class="mt-2 text-xs text-muted"
                >
                  {count_label(
                    result.retried_total - length(result.retried),
                    "more test that passed on retry is not shown.",
                    "more tests that passed on retry are not shown."
                  )}
                </p>
              </div>
            </section>
          </div>
        </.async_result>
      </.panel>

      <.panel id="reports-panel" title="Test reports" icon="hero-clipboard-document-list">
        <.table
          id="test-reports"
          rows={@reports}
          row_id={&"test-report-#{&1.id}"}
          empty={@reports == []}
        >
          <:col :let={report} label="Job">
            <.text_link
              id={"test-report-#{report.id}-link"}
              navigate={report_path(@current_account, @project, @run.run_id, report.id)}
            >
              <span class="font-mono">{report.job}</span>
            </.text_link>
          </:col>
          <:col :let={report} label="Job status">
            <.job_status_badge status={report.job_status} />
          </:col>
          <:col :let={report} label="Suite">
            <span class="break-all font-mono text-xs">{report.suite_id}</span>
          </:col>
          <:col :let={report} label="Partition">
            <span class="font-mono text-xs">{partition(report) || "-"}</span>
          </:col>
          <:col :let={report} label="Completeness">
            <.status_badge kind={if report.status == "complete", do: "primary", else: "neutral"}>
              {String.capitalize(report.status)}
            </.status_badge>
          </:col>
          <:empty_state>
            <p id="no-reports" class="p-4 text-sm text-muted">
              No test report was uploaded for this run.
            </p>
          </:empty_state>
        </.table>
      </.panel>

      <.panel
        :if={@run.source_commit}
        id="change-requests-panel"
        title="Change requests at this commit"
        icon="hero-arrows-right-left"
      >
        <p :if={@change_requests == []} id="no-change-requests" class="text-sm text-muted">
          No change request has this commit as its head.
        </p>
        <ul :if={@change_requests != []} class="space-y-2">
          <li
            :for={cr <- @change_requests}
            id={"change-request-#{cr.number}"}
            class="flex flex-wrap items-center gap-2 text-sm"
          >
            <.text_link navigate={
              ~p"/dashboard/accounts/#{@current_account.id}/projects/#{@project.slug}/change-requests/#{cr.number}"
            }>
              #{cr.number} {cr.title}
            </.text_link>
            <.state_badge state={cr.state} />
          </li>
        </ul>
      </.panel>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :test, :map, required: true

  defp test_row(assigns) do
    ~H"""
    <li id={@id} class="run-row">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <.job_status_badge status={@test.outcome} />
        <span class="min-w-0 break-words text-sm font-medium">{@test.name}</span>
        <span :if={@test.duration_us} class="ml-auto font-mono text-xs text-muted">
          {test_duration(@test.duration_us)}
        </span>
      </div>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted">
        <span class="break-all font-mono">
          {Enum.join([@test.group | @test.path], " › ")}
        </span>
        <span :if={@test.file} class="inline-flex min-w-0 items-center gap-1">
          <code class="break-all">{@test.file}<span :if={@test.line}>:{@test.line}</span></code>
          <.copy_button
            id={"#{@id}-copy"}
            value={if @test.line, do: "#{@test.file}:#{@test.line}", else: @test.file}
            label={"Copy path of #{@test.name}"}
          />
        </span>
      </div>
    </li>
    """
  end

  defp results(doc), do: doc["results"] || []

  defp jobs(doc, order) do
    results = results(doc)

    ordered =
      case order do
        :results -> results
        :failures_first -> Enum.sort_by(results, &(&1["status"] not in ~w(failed timed_out)))
      end

    ordered ++ not_run_jobs(doc)
  end

  defp not_run_jobs(doc) do
    named = MapSet.new(results(doc), & &1["name"])

    for job <- (doc["graph"] || %{})["jobs"] || [],
        not MapSet.member?(named, job["name"]),
        do: %{"name" => job["name"], "status" => "not_run", "command" => job["command"]}
  end

  defp partition(%{partition: nil}), do: nil
  defp partition(%{partition: p, partition_count: nil}), do: p
  defp partition(%{partition: p, partition_count: n}), do: "#{p}/#{n}"

  defp tickets(doc), do: (doc["links"] || %{})["tickets"] || []
  defp threads(doc), do: (doc["links"] || %{})["threads"] || []

  defp host(host) do
    cpus = host["logical_cpus"] && count_label(host["logical_cpus"], "CPU", "CPUs")

    [host["os"], host["arch"], cpus]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp bytes(nil), do: "-"
  defp bytes(n) when n < 1_048_576, do: "#{div(n + 1023, 1024)} KiB"
  defp bytes(n), do: "#{Float.round(n / 1_048_576, 1)} MiB"

  defp report_path(account, project, run_id, id),
    do:
      ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/runs/#{run_id}/reports/#{id}"

  defp run_path(account, project, run_id),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/runs/#{run_id}"
end
