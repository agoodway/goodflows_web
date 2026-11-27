defmodule GoodFlowsWeb.WorkflowRunLive.Index do
  @moduledoc """
  Lists a project's workflow runs, newest `started_at` first, 50 per page
  with Load more. Every account member can view it; it writes nothing.

  The filters live in the URL under the API's names and go to
  `GoodFlows.WorkflowRuns.list_runs/4` as given, so they mean and validate
  exactly what the API's do (design D7). A LiveFilter bar edits them and
  patches the URL on each change. An invalid filter is not applied: its
  error shows under the bar and the other filters stay applied. The page
  shows the matching API request as a copyable URL.

  With no filter applied, a run called by a run stored in the project is
  folded under its parent (design D3), whose row expands to show it. A
  run whose parent is not stored is marked as called by a run that was
  not uploaded.

  The page refreshes 500 ms after a run of the project is stored
  (`GoodFlows.WorkflowRuns.topic/1`), keeping the filters and every loaded
  row: it rereads the list in pages of at most 200 down to the last row it
  had loaded (design D4).
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.WorkflowRunComponents

  alias GoodFlows.Projects
  alias GoodFlows.WorkflowRuns

  @page_size 50
  @max_page_size 200
  @refresh_ms 500
  @child_depth 3

  @filters_in_api_order ~w(workflow environment outcome commit branch event graph_sha256 ticket thread_url)

  @labels %{
    "workflow" => "Workflow",
    "environment" => "Environment",
    "outcome" => "Outcome",
    "commit" => "Commit",
    "branch" => "Branch",
    "event" => "CI event",
    "graph_sha256" => "Graph",
    "ticket" => "Ticket",
    "thread_url" => "Thread URL"
  }

  @errors %{
    "workflow" => "Workflow must be a workflow name of 1 to 64 characters.",
    "environment" => "Environment must be a name of 1 to 64 characters.",
    "outcome" => "Outcome must be passed, failed or cancelled.",
    "commit" => "Commit must be a full 40- or 64-character SHA.",
    "branch" => "Branch must be a branch name of 1 to 256 characters.",
    "event" => "CI event must be a name of 1 to 64 characters.",
    "graph_sha256" => "Graph must be a 64-character lowercase SHA-256.",
    "ticket" => "Ticket must be a ticket ID such as GOO-123.",
    "thread_url" => "Thread URL must be an agent thread URL."
  }

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    account = socket.assigns.current_account

    case Projects.get_project(account, slug) do
      {:ok, project} ->
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(GoodFlows.PubSub, WorkflowRuns.topic(project.id))

        {:ok,
         socket
         |> assign(
           page_title: "Runs · #{project.slug}",
           active_nav: :projects,
           project: project,
           breadcrumbs: [
             %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
             %{label: "Projects", to: ~p"/dashboard/accounts/#{account.id}/projects"},
             %{label: project.slug, to: ~p"/dashboard/accounts/#{account.id}/projects/#{slug}"},
             %{label: "Runs"}
           ],
           values: WorkflowRuns.filter_values(project),
           expanded: MapSet.new(),
           refresh_scheduled: false
         )
         |> stream_configure(:runs, dom_id: &"run-#{&1.run.run_id}")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Project not found")
         |> push_navigate(to: ~p"/dashboard/accounts/#{account.id}/projects")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) when not is_map_key(socket.assigns, :project),
    do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    raw = Map.take(params, @filters_in_api_order)

    {:noreply,
     socket
     |> init_filter_bar(raw)
     |> assign(filters: raw, invalid: [], expanded: MapSet.new())
     |> load_rows(@page_size)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-play-circle">
        Workflow runs
        <:subtitle>
          Runs of <code>{@project.slug}</code> uploaded by the goodflows CLI, newest first.
        </:subtitle>
      </.header>

      <.panel
        id="run-filters"
        title="Filters"
        icon="hero-funnel"
        class="overflow-visible [&>header]:rounded-t-md"
      >
        <LiveFilter.bar filter={@livefilter} theme={:neutral} variant={:neutral} />

        <div :if={@invalid != []} id="filter-errors" class="mt-4">
          <.notice kind="warning">
            <p :for={name <- @invalid} id={"filter-error-#{name}"}>
              {error_message(name)} The filter is not applied.
            </p>
          </.notice>
        </div>

        <div id="api-query" class="mt-4 flex items-start gap-2 border-t border-base-300 pt-4">
          <span class="shrink-0 pt-1 font-mono text-[0.6875rem] font-semibold uppercase tracking-wider text-muted">
            API
          </span>
          <code id="api-query-url" class="min-w-0 flex-1 break-all pt-1 font-mono text-xs">
            GET {api_query(@project, @filters)}
          </code>
          <.copy_button
            id="copy-api-query"
            value={api_query(@project, @filters)}
            label="Copy API query"
          />
        </div>
      </.panel>

      <ul id="runs" phx-update="stream" class={["list-table", @row_count == 0 && "hidden"]}>
        <.run_row
          :for={{dom_id, item} <- @streams.runs}
          id={dom_id}
          run={item.run}
          to={run_path(@current_account, @project, item.run)}
          filter_to={&list_path(@current_account, @project, Map.put(@filters, &1, &2))}
          patch
          children={item.children}
          child_to={&run_path(@current_account, @project, &1)}
          expanded={item.expanded?}
          toggle="toggle_children"
          missing_parent={item.missing_parent?}
        />
      </ul>

      <div :if={@row_count == 0} class="list-table">
        <.empty_state
          :if={@filters == %{}}
          id="runs-empty"
          icon="hero-play-circle"
          title="No workflow runs yet"
        >
          Set <code>history = true</code>
          in the <code>[reporting]</code>
          block of <code>goodflows.toml</code>
          and give goodflows an API key: every run then uploads here.
          <:actions>
            <.button
              id="empty-api-keys"
              variant="outline"
              navigate={~p"/dashboard/accounts/#{@current_account.id}/api-keys"}
            >
              API keys
            </.button>
          </:actions>
        </.empty_state>
        <.empty_state
          :if={@filters != %{}}
          id="runs-no-match"
          icon="hero-funnel"
          title="No matching runs"
        >
          No run matches
          <span :for={{{name, value}, index} <- Enum.with_index(active(@filters))}>
            <span :if={index > 0}>and</span>
            <code>{name}</code>
            <code class="break-all">{value}</code>
          </span>
          <:actions>
            <.button
              id="empty-clear-filters"
              variant="outline"
              patch={list_path(@current_account, @project, %{})}
            >
              Clear filters
            </.button>
          </:actions>
        </.empty_state>
      </div>

      <div :if={@next_cursor} class="flex justify-center">
        <.button
          id="load-more"
          variant="outline"
          size="sm"
          phx-click="load_more"
          phx-disable-with="Loading…"
        >
          Load more
        </.button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("load_more", _params, %{assigns: %{next_cursor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    {:ok, page} = list(socket, %{"limit" => @page_size, "cursor" => socket.assigns.next_cursor})

    {:noreply,
     socket
     |> assign(
       row_count: socket.assigns.row_count + length(page.runs),
       next_cursor: page.next_cursor,
       last_run: List.last(page.runs) || socket.assigns.last_run
     )
     |> stream(:runs, items(socket, page.runs))}
  end

  def handle_event("toggle_children", %{"run_id" => run_id}, socket) do
    %{project: project, expanded: expanded} = socket.assigns

    expanded =
      if MapSet.member?(expanded, run_id),
        do: MapSet.delete(expanded, run_id),
        else: MapSet.put(expanded, run_id)

    socket = assign(socket, expanded: expanded)

    case WorkflowRuns.summaries(project, [run_id]) do
      [run] -> {:noreply, stream_insert(socket, :runs, hd(items(socket, [run])))}
      [] -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:livefilter, :updated, params}, socket) do
    %{current_account: account, project: project} = socket.assigns
    {:noreply, push_patch(socket, to: list_path(account, project, params))}
  end

  def handle_info(
        {:workflow_run_stored, _project_id, _run_id},
        %{assigns: %{refresh_scheduled: true}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:workflow_run_stored, _project_id, _run_id}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, refresh_scheduled: true)}
  end

  def handle_info(:refresh, socket) do
    %{row_count: row_count, last_run: last_run} = socket.assigns
    socket = assign(socket, refresh_scheduled: false)
    {:noreply, load_rows(socket, max(row_count + 1, @page_size), last_run)}
  end

  defp load_rows(socket, count, last_loaded \\ nil) do
    {socket, runs, next_cursor} = read_rows_dropping_invalid_filters(socket, count, last_loaded)

    socket
    |> assign(
      row_count: length(runs),
      next_cursor: next_cursor,
      last_run: List.last(runs)
    )
    |> stream(:runs, items(socket, runs), reset: true)
  end

  defp read_rows_dropping_invalid_filters(socket, count, last_loaded) do
    case read_rows_through_last_loaded(socket, count, last_loaded, nil, []) do
      {:ok, runs, next_cursor} ->
        {socket, runs, next_cursor}

      {:error, %Ecto.Changeset{errors: errors}} ->
        socket = drop_invalid_filters(socket, errors)

        {:ok, runs, next_cursor} =
          read_rows_through_last_loaded(socket, count, last_loaded, nil, [])

        {socket, runs, next_cursor}
    end
  end

  defp drop_invalid_filters(socket, errors) do
    invalid =
      for {field, _error} <- errors,
          name = to_string(field),
          name in @filters_in_api_order,
          do: name

    assign(socket, filters: Map.drop(socket.assigns.filters, invalid), invalid: invalid)
  end

  defp read_rows_through_last_loaded(socket, count, last_loaded, cursor, acc) do
    remaining = count - length(acc)
    params = %{"limit" => if(remaining > 0, do: min(remaining, @max_page_size), else: @page_size)}
    params = if cursor, do: Map.put(params, "cursor", cursor), else: params

    with {:ok, page} <- list(socket, params) do
      acc = acc ++ page.runs

      if page.next_cursor != nil and
           (length(acc) < count or newer?(List.last(acc), last_loaded)),
         do: read_rows_through_last_loaded(socket, count, last_loaded, page.next_cursor, acc),
         else: drop_rows_after_last_loaded(acc, count, last_loaded, page.next_cursor)
    end
  end

  defp drop_rows_after_last_loaded(read, count, last_loaded, next_cursor) do
    kept =
      read
      |> Enum.with_index()
      |> Enum.take_while(fn {run, index} -> index < count or not older?(run, last_loaded) end)
      |> Enum.map(&elem(&1, 0))

    if length(kept) == length(read),
      do: {:ok, read, next_cursor},
      else: {:ok, kept, WorkflowRuns.cursor(List.last(kept))}
  end

  defp newer?(_run, nil), do: false
  defp newer?(run, last), do: compare(run, last) == :gt

  defp older?(_run, nil), do: false
  defp older?(run, last), do: compare(run, last) == :lt

  defp compare(run, last) do
    case DateTime.compare(run.started_at, last.started_at) do
      :eq when run.run_id > last.run_id -> :gt
      :eq when run.run_id < last.run_id -> :lt
      order -> order
    end
  end

  defp list(socket, params) do
    %{current_account: account, project: project, filters: filters} = socket.assigns

    WorkflowRuns.list_runs(account, project, Map.merge(filters, params),
      fold_children: filters == %{}
    )
  end

  # Commit, CI event and ticket are free text, always shown as inputs; graph
  # and thread URL join them only when the URL sets one. The others are
  # chips added from the bar's menu. Each filter is an exact match whose URL
  # param is its API name with the raw value.
  defp init_filter_bar(socket, raw) do
    %{values: values} = socket.assigns

    texts =
      for {field, placeholder} <- [
            commit: "Full SHA",
            event: "push",
            ticket: "GOO-123",
            graph_sha256: "SHA-256",
            thread_url: "https://"
          ],
          field in [:commit, :event, :ticket] or Map.has_key?(raw, to_string(field)),
          do: filter_config(&LiveFilter.text/2, field, always_on: true, placeholder: placeholder)

    selects = [
      filter_config(&LiveFilter.select/2, :workflow,
        options: options(values.workflows, raw["workflow"])
      ),
      filter_config(&LiveFilter.select/2, :outcome,
        options: [{"Passed", "passed"}, {"Failed", "failed"}, {"Cancelled", "cancelled"}]
      ),
      filter_config(&LiveFilter.select/2, :branch,
        options: options(values.branches, raw["branch"])
      ),
      filter_config(&LiveFilter.select/2, :environment,
        options: options(values.environments, raw["environment"])
      )
    ]

    config = texts ++ selects

    filters =
      for %{field: field} = config <- config,
          config.always_on or Map.has_key?(raw, to_string(field)),
          do: LiveFilter.Filter.new(config, :eq, raw[to_string(field)])

    LiveFilter.init(socket, config, filters)
  end

  defp filter_config(builder, field, opts) do
    name = to_string(field)

    builder.(
      field,
      [label: label(name), custom_param: name, operators: [:eq], default_operator: :eq] ++ opts
    )
  end

  defp items(socket, runs) do
    %{project: project, filters: filters, expanded: expanded} = socket.assigns
    stored_parents = stored_parents(project, runs)
    children = if filters == %{}, do: children(project, Enum.map(runs, & &1.run_id)), else: %{}

    for run <- runs do
      %{
        run: run,
        children: tree(children, run.run_id, @child_depth),
        missing_parent?:
          run.parent_run_id != nil and not MapSet.member?(stored_parents, run.parent_run_id),
        expanded?: MapSet.member?(expanded, run.run_id)
      }
    end
  end

  defp stored_parents(project, runs) do
    parent_ids = runs |> Enum.map(& &1.parent_run_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    project |> WorkflowRuns.summaries(parent_ids) |> MapSet.new(& &1.run_id)
  end

  defp children(project, run_ids, depth \\ @child_depth)
  defp children(_project, [], _depth), do: %{}
  defp children(_project, _run_ids, 0), do: %{}

  defp children(project, run_ids, depth) do
    level = WorkflowRuns.children(project, run_ids)
    grouped = Enum.group_by(level, & &1.parent_run_id)
    Map.merge(grouped, children(project, Enum.map(level, & &1.run_id), depth - 1))
  end

  defp tree(_children, _run_id, 0), do: []

  defp tree(children, run_id, depth) do
    for child <- Map.get(children, run_id, []),
        do: %{run: child, children: tree(children, child.run_id, depth - 1)}
  end

  defp options(values, nil), do: values
  defp options(values, current), do: if(current in values, do: values, else: values ++ [current])

  defp active(filters),
    do: for(name <- @filters_in_api_order, value = filters[name], value != nil, do: {name, value})

  defp label(name), do: Map.fetch!(@labels, name)
  defp error_message(name), do: Map.fetch!(@errors, name)

  defp api_query(project, filters) do
    path = "/api/v1/projects/#{project.slug}/workflow-runs"

    case filters |> Enum.sort() |> URI.encode_query() do
      "" -> path
      query -> path <> "?" <> query
    end
  end

  defp list_path(account, project, filters) do
    query =
      for name <- @filters_in_api_order, value = filters[name], value != nil, do: {name, value}

    ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/runs?#{query}"
  end

  defp run_path(account, project, run),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/runs/#{run.run_id}"
end
