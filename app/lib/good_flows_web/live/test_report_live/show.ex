defmodule GoodFlowsWeb.TestReportLive.Show do
  @moduledoc """
  One test report of a workflow run: its summary, its groups and a flat,
  paged list of its tests. Every account member can view it; it writes
  nothing.

  Report contents never load whole into the application:
  `GoodFlows.TestReports.get_report/4` and `report_tests/2` read them
  inside Postgres. The test list's outcome filter, search, sort and page
  live in the URL (`outcome`, `q`, `sort`, `page`). Without `outcome`, the
  list shows failed and errored tests when the report has any, and every
  test otherwise. Failure messages are not part of a report, so the page
  has none.

  `run_id` and `id` must be lowercase canonical UUIDs; any other spelling,
  or a report of another run or project, redirects to the run with
  `Test report not found`. A stored report never changes, so the page does
  not refresh.
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.ChangeRequestComponents, only: [format_time: 1]
  import GoodFlowsWeb.WorkflowRunComponents

  alias GoodFlows.Projects
  alias GoodFlows.TestReports

  @filter_labels [
    {"failed", "Failed"},
    {"all", "All"},
    {"passed", "Passed"},
    {"skipped", "Skipped"},
    {"retried", "Passed on retry"}
  ]

  @impl true
  def mount(%{"slug" => slug, "run_id" => run_id, "id" => id}, _session, socket) do
    account = socket.assigns.current_account
    projects = ~p"/dashboard/accounts/#{account.id}/projects"
    run_path = ~p"/dashboard/accounts/#{account.id}/projects/#{slug}/runs/#{run_id}"

    with {:project, {:ok, project}} <- {:project, Projects.get_project(account, slug)},
         {:ok, details} <- TestReports.get_report(account, project, run_id, id) do
      report = details.report

      {:ok,
       assign(socket,
         page_title: "Report #{report.job} · Run #{String.slice(run_id, 0, 8)}",
         active_nav: :projects,
         project: project,
         run_id: run_id,
         run_path: run_path,
         breadcrumbs: [
           %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
           %{label: "Projects", to: projects},
           %{label: project.slug, to: ~p"/dashboard/accounts/#{account.id}/projects/#{slug}"},
           %{label: "Runs", to: ~p"/dashboard/accounts/#{account.id}/projects/#{slug}/runs"},
           %{label: String.slice(run_id, 0, 8), to: run_path},
           %{label: "Report #{report.job}"}
         ],
         details: details,
         report: report
       )}
    else
      {:project, {:error, :not_found}} ->
        {:ok, socket |> put_flash(:error, "Project not found") |> push_navigate(to: projects)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Test report not found")
         |> push_navigate(to: run_path)}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) when not is_map_key(socket.assigns, :report),
    do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    search = String.trim(params["q"] || "")
    sort = if params["sort"] in TestReports.test_sorts(), do: params["sort"], else: "order"
    page = page(params["page"])
    opts = [search: search, sort: sort, page: page]

    {outcome, result} =
      case params["outcome"] do
        outcome when is_binary(outcome) and outcome != "" ->
          outcome = if outcome in TestReports.test_filters(), do: outcome, else: "all"
          {outcome, TestReports.report_tests(socket.assigns.report, [outcome: outcome] ++ opts)}

        _default ->
          default_tests(socket.assigns.report, opts)
      end

    {:noreply,
     socket
     |> assign(
       search: search,
       sort: sort,
       page: page,
       outcome: outcome,
       tests: result.tests,
       total: result.total,
       counts: result.counts
     )
     |> init_filter_bar()}
  end

  # Search is an always-on input; outcome is a chip that is always set,
  # labelled with each outcome's count. Clear all returns both to the
  # page's default: failures when there are any, otherwise all. Both keep their URL params (`q`, `outcome`).
  defp init_filter_bar(socket) do
    %{outcome: outcome, search: search, counts: counts} = socket.assigns

    search_config =
      LiveFilter.text(:q,
        label: "Search",
        custom_param: "q",
        always_on: true,
        hide_label: true,
        placeholder: "Search tests",
        operators: [:eq],
        default_operator: :eq
      )

    outcome_config =
      LiveFilter.select(:outcome,
        label: "Outcome",
        custom_param: "outcome",
        options: for({value, label} <- @filter_labels, do: {"#{label} #{counts[value]}", value}),
        default_visible: true,
        default_value: if(counts["failed"] > 0, do: "failed", else: "all")
      )

    LiveFilter.init(socket, [search_config, outcome_config], [
      LiveFilter.Filter.new(search_config, :eq, if(search != "", do: search)),
      LiveFilter.Filter.new(outcome_config, :eq, outcome)
    ])
  end

  # Failures first when there are any, otherwise every test.
  defp default_tests(report, opts) do
    failed = TestReports.report_tests(report, [outcome: "failed"] ++ opts)

    if failed.counts["failed"] > 0,
      do: {"failed", failed},
      else: {"all", TestReports.report_tests(report, [outcome: "all"] ++ opts)}
  end

  defp page(value) do
    case Integer.parse(value || "") do
      {n, ""} when n > 0 -> n
      _other -> 1
    end
  end

  @impl true
  def handle_info({:livefilter, :updated, params}, socket) do
    q = String.trim(params["q"] || "")
    path = tests_path(socket.assigns, outcome: params["outcome"], q: q, page: 1)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        filters: @filter_labels,
        pages: max(ceil(assigns.total / TestReports.tests_page_size()), 1),
        offset: (assigns.page - 1) * TestReports.tests_page_size(),
        warnings: warnings(assigns.details, assigns.report)
      )

    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-clipboard-document-list">
        <span class="inline-flex flex-wrap items-center gap-2">
          <span id="report-job" class="font-mono">{@report.job}</span>
          <span id="report-job-status"><.job_status_badge status={@report.job_status} /></span>
          <.status_badge kind={if @report.status == "complete", do: "primary", else: "neutral"}>
            {String.capitalize(@report.status)}
          </.status_badge>
        </span>
        <:subtitle>
          Test report <code class="break-all">{@report.report_id}</code>
          of run
          <.text_link id="report-run-link" navigate={@run_path}>{String.slice(@run_id, 0, 8)}</.text_link>
        </:subtitle>
      </.header>

      <div :if={@warnings != []} id="report-warnings">
        <.notice kind="warning">
          <p :for={{id, text} <- @warnings} id={"warning-#{id}"}>{text}</p>
        </.notice>
      </div>

      <.panel id="report-summary-panel" title="Summary" icon="hero-document-text">
        <.list>
          <:item :if={@details.suite_finished} title="Results">
            <span id="summary-counts" class="font-mono">
              {counts_text(@details.suite_finished["counts"])}
            </span>
          </:item>
          <:item title="Suite">
            <code id="summary-suite" class="break-all font-mono">{@report.suite_id}</code>
          </:item>
          <:item :if={@report.partition} title="Partition">
            <span id="summary-partition" class="font-mono">{partition(@report)}</span>
          </:item>
          <:item :if={runner(@details.suite_started)} title="Runner">
            <span id="summary-runner" class="font-mono">{runner(@details.suite_started)}</span>
          </:item>
          <:item :if={@details.suite_started} title="Started">
            <span class="font-mono">{@details.suite_started["started_at"]}</span>
          </:item>
          <:item
            :if={@details.suite_finished && @details.suite_finished["duration_us"]}
            title="Duration"
          >
            <span id="summary-duration" class="font-mono">
              {test_duration(@details.suite_finished["duration_us"])}
            </span>
          </:item>
          <:item :if={@details.suite_started && @details.suite_started["seed"] != nil} title="Seed">
            <span id="summary-seed" class="font-mono">{@details.suite_started["seed"]}</span>
          </:item>
          <:item :if={filters(@details.suite_started) != []} title="Filters">
            <span id="summary-filters" class="inline-flex flex-wrap justify-end gap-1">
              <.tag :for={filter <- filters(@details.suite_started)}>{filter}</.tag>
            </span>
          </:item>
          <:item :if={@details.source["commit"]} title="Commit">
            <span class="inline-flex items-center justify-end gap-1">
              <code class="break-all font-mono">{@details.source["commit"]}</code>
              <span :if={@details.source["dirty"]} class="run-row-dirty">dirty</span>
            </span>
          </:item>
          <:item :if={@details.source["branch"]} title="Branch">
            <.tag>{@details.source["branch"]}</.tag>
          </:item>
          <:item :if={@report.environment} title="Environment">
            <.tag>{@report.environment}</.tag>
          </:item>
          <:item title="Stored">
            <span class="font-mono">{format_time(@report.inserted_at)}</span>
          </:item>
        </.list>
      </.panel>

      <.panel
        id="tests-panel"
        title="Tests"
        icon="hero-beaker"
        class="overflow-visible [&>header]:rounded-t-md"
      >
        <div class="space-y-4">
          <div class="flex flex-wrap items-center gap-3">
            <LiveFilter.bar filter={@livefilter} theme={:neutral} variant={:neutral} />
            <div class="ml-auto flex flex-wrap items-center gap-2">
              <div class="flex gap-1" role="group" aria-label="Test order">
                <.button
                  id="sort-order"
                  variant={if @sort == "order", do: "soft", else: "ghost"}
                  size="sm"
                  patch={tests_path(assigns, sort: "order", page: 1)}
                >
                  Report order
                </.button>
                <.button
                  id="sort-slowest"
                  variant={if @sort == "slowest", do: "soft", else: "ghost"}
                  size="sm"
                  patch={tests_path(assigns, sort: "slowest", page: 1)}
                >
                  Slowest first
                </.button>
              </div>
            </div>
          </div>

          <p :if={@tests == []} id="no-tests" class="text-sm text-muted">
            {empty_text(@search, @counts["all"])}
          </p>

          <ul :if={@tests != []} id="tests" class="list-table">
            <li
              :for={{test, i} <- Enum.with_index(@tests, @offset)}
              id={"test-#{i}"}
              class="run-row"
            >
              <details class="group">
                <summary class="flex cursor-pointer list-none flex-col gap-1 rounded-sm">
                  <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                    <.icon
                      name="hero-chevron-right-micro"
                      class="size-4 shrink-0 text-muted transition-transform group-open:rotate-90"
                    />
                    <.job_status_badge status={test.outcome} />
                    <span :if={test.retried} id={"test-#{i}-retried"}>
                      <.status_badge dot>Passed on retry</.status_badge>
                    </span>
                    <span class="min-w-0 break-words text-sm font-medium">{test.name}</span>
                    <span :if={test.duration_us} class="ml-auto font-mono text-xs text-muted">
                      {test_duration(test.duration_us)}
                    </span>
                  </div>
                  <div class="flex flex-wrap items-center gap-x-3 gap-y-1 pl-7 text-xs text-muted">
                    <span class="break-all font-mono">{Enum.join([test.group | test.path], " › ")}</span>
                    <code :if={location(test) not in [nil, test.group]} class="break-all">
                      {location(test)}
                    </code>
                  </div>
                </summary>
                <div class="mt-2 space-y-2 pl-7">
                  <div :if={test.file} class="flex items-center gap-1 text-xs">
                    <code class="break-all">{location(test)}</code>
                    <.copy_button
                      id={"test-#{i}-copy"}
                      value={location(test)}
                      label={"Copy path of #{test.name}"}
                    />
                  </div>
                  <ol id={"test-#{i}-attempts"} class="space-y-1 text-xs">
                    <li
                      :for={{attempt, n} <- Enum.with_index(test.attempts, 1)}
                      class="flex flex-wrap items-center gap-x-3 gap-y-1"
                    >
                      <span class="font-mono text-muted">Attempt {n}</span>
                      <.job_status_badge status={attempt.outcome} />
                      <span :if={attempt.duration_us} class="font-mono text-muted">
                        {test_duration(attempt.duration_us)}
                      </span>
                      <.tag :for={{key, value} <- Enum.sort(attempt.meta)}>
                        {key}: {meta_value(value)}
                      </.tag>
                    </li>
                  </ol>
                </div>
              </details>
            </li>
          </ul>

          <div :if={@pages > 1} id="tests-pages" class="flex items-center justify-between gap-2">
            <span class="text-xs text-muted">
              Tests {@offset + 1}–{@offset + length(@tests)} of {@total}
            </span>
            <div class="flex gap-1">
              <.button
                :if={@page > 1}
                id="tests-previous"
                variant="ghost"
                size="sm"
                patch={tests_path(assigns, page: @page - 1)}
              >
                Previous
              </.button>
              <.button
                :if={@page < @pages}
                id="tests-next"
                variant="ghost"
                size="sm"
                patch={tests_path(assigns, page: @page + 1)}
              >
                Next
              </.button>
            </div>
          </div>
          <p class="text-xs text-muted">
            Reports do not include failure messages or output.
          </p>
        </div>
      </.panel>

      <.panel id="groups-panel" title="Groups" icon="hero-folder">
        <p :if={@details.groups == []} id="no-groups" class="text-sm text-muted">
          The report has no finished groups.
        </p>
        <.table
          :if={@details.groups != []}
          id="groups"
          rows={Enum.with_index(@details.groups)}
          row_id={fn {_group, i} -> "group-#{i}" end}
          row_item={fn {group, _i} -> group end}
        >
          <:col :let={group} label="Group">
            <span class="break-all font-mono text-xs">{group.group}</span>
            <p :if={group.outcome == "errored" and group.counts == %{}} class="text-xs text-muted">
              Errored before any test finished.
            </p>
          </:col>
          <:col :let={group} label="Outcome">
            <.job_status_badge status={group.outcome} />
          </:col>
          <:col :let={group} label="Tests">
            <span class="font-mono text-xs">{counts_text(group.counts)}</span>
          </:col>
          <:col :let={group} label="Duration">
            <span class="font-mono text-xs">{test_duration(group.duration_us) || "-"}</span>
          </:col>
        </.table>
        <p
          :if={@details.groups_total > length(@details.groups)}
          id="groups-more"
          class="mt-2 text-xs text-muted"
        >
          Showing the first {length(@details.groups)} of {@details.groups_total} groups, failures first.
        </p>
      </.panel>
    </div>
    """
  end

  defp tests_path(assigns, changes) do
    params =
      %{
        "outcome" => assigns.outcome,
        "q" => assigns.search,
        "sort" => assigns.sort,
        "page" => assigns.page
      }
      |> Map.merge(Map.new(changes, fn {k, v} -> {to_string(k), v} end))
      |> Enum.reject(fn {k, v} ->
        v in ["", nil] or {k, v} in [{"sort", "order"}, {"page", 1}]
      end)

    ~p"/dashboard/accounts/#{assigns.current_account.id}/projects/#{assigns.project.slug}/runs/#{assigns.run_id}/reports/#{assigns.report.id}?#{params}"
  end

  defp warnings(details, report) do
    finished = details.suite_finished || %{}

    [
      report.status == "incomplete" &&
        {"incomplete", "The report stopped before the suite finished, so some tests are missing."},
      finished["aborted"] == true && {"aborted", "The suite was aborted."},
      details.interrupted && {"interrupted", "The test run was interrupted."},
      details.max_failures_reached &&
        {"max-failures", "The runner stopped after reaching its maximum number of failures."},
      details.truncated && {"truncated", "The reporter truncated this report."},
      (finished["unfinished_tests"] || 0) > 0 &&
        {"unfinished",
         "#{count_label(finished["unfinished_tests"], "test", "tests")} started but did not finish."}
    ]
    |> Enum.filter(& &1)
  end

  defp counts_text(counts) do
    case for(
           o <- ~w(passed failed errored skipped),
           (counts[o] || 0) > 0,
           do: "#{counts[o]} #{o}"
         ) do
      [] -> "none"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp runner(nil), do: nil

  defp runner(%{"runner" => runner}),
    do: Enum.join(Enum.reject([runner["name"], runner["version"]], &is_nil/1), " ")

  defp filters(%{"filters" => %{"include" => include, "exclude" => exclude}}) do
    Enum.map(include, &"include #{&1["tag"]}:#{&1["value"]}") ++
      Enum.map(exclude, &"exclude #{&1["tag"]}:#{&1["value"]}")
  end

  defp filters(_suite_started), do: []

  defp location(%{file: nil}), do: nil
  defp location(%{file: file, line: nil}), do: file
  defp location(%{file: file, line: line}), do: "#{file}:#{line}"

  defp meta_value(nil), do: "null"
  defp meta_value(value), do: to_string(value)

  defp empty_text("", 0), do: "The report has no finished tests."
  defp empty_text("", _all), do: "No test has this outcome."
  defp empty_text(_search, _all), do: "No test matches the search."

  defp partition(%{partition: p, partition_count: nil}), do: p
  defp partition(%{partition: p, partition_count: n}), do: "#{p}/#{n}"
end
