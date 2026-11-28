defmodule GoodFlowsWeb.StoredChangeLive.Index do
  @moduledoc """
  Lists a project's stored goodflows changes, newest latest push first,
  50 per page with Load more. The filter (`?status=active|archived|all`,
  default and fallback `active`: latest status `proposed` or `approved`)
  lives in the URL. Each row shows the latest version's listing fields
  and the change requests of the project with that change id. Every
  account member can view it; it writes nothing.

  The page refreshes 500 ms after a project event, keeping the filter
  and every loaded row.
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.ChangeRequestComponents, only: [state_badge: 1, format_time: 1]
  import GoodFlowsWeb.StoredChangeComponents

  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects
  alias GoodFlows.StoredChanges

  @page_size 50
  @max_page_size 200
  @refresh_ms 500
  @filters ~w(active archived all)
  @active ~w(proposed approved)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    account = socket.assigns.current_account

    case Projects.get_project(account, slug) do
      {:ok, project} ->
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(GoodFlows.PubSub, ProjectEvents.topic(project.id))

        {:ok,
         socket
         |> assign(
           page_title: "Changes · #{project.slug}",
           active_nav: :projects,
           project: project,
           breadcrumbs: [
             %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
             %{label: "Projects", to: ~p"/dashboard/accounts/#{account.id}/projects"},
             %{
               label: project.slug,
               to: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}"
             },
             %{label: "Changes"}
           ],
           refresh_scheduled: false
         )
         |> stream_configure(:changes, dom_id: &"changes-row-#{&1.id}")}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Project #{slug} not found. Pick a project of this account.")
         |> push_navigate(to: ~p"/dashboard/accounts/#{account.id}/projects")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) when not is_map_key(socket.assigns, :project),
    do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    filter = if params["status"] in @filters, do: params["status"], else: "active"

    {:noreply,
     socket
     |> assign(filter: filter)
     |> LiveFilter.init([status_filter()], [LiveFilter.Filter.new(status_filter(), :eq, filter)])
     |> load_rows(@page_size)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-document-duplicate">
        Changes
        <:subtitle>
          Goodflows changes pushed to <code>{@project.slug}</code>, planned before or while a change request builds them.
        </:subtitle>
      </.header>

      <div id="changes-filter">
        <LiveFilter.bar filter={@livefilter} theme={:neutral} variant={:neutral} />
      </div>

      <.table id="changes" rows={@streams.changes} empty={@row_count == 0}>
        <:col :let={{_id, row}} label="Change">
          <.link
            id={"change-link-#{row.id}"}
            navigate={show_path(@current_account, @project, row.id)}
            class="block break-all font-mono text-sm font-medium hover:underline"
          >
            {row.id}
          </.link>
        </:col>
        <:col :let={{_id, row}} label="Status">
          <span id={"change-status-#{row.id}"}>
            <.change_status_badge status={row.change.status} />
          </span>
        </:col>
        <:col :let={{_id, row}} label="Size" class="text-xs">
          <span id={"change-size-#{row.id}"}>
            <span :if={row.change.size} class="font-mono">{row.change.size}</span>
            <span :if={!row.change.size} class="text-muted">—</span>
          </span>
        </:col>
        <:col :let={{_id, row}} label="Door" class="text-xs">
          <span id={"change-door-#{row.id}"}>
            <span :if={row.change.door} class="font-mono">{row.change.door}</span>
            <span :if={!row.change.door} class="text-muted">—</span>
          </span>
        </:col>
        <:col :let={{_id, row}} label="Capabilities">
          <span id={"change-capabilities-#{row.id}"} class="flex flex-wrap gap-1">
            <.tag :for={capability <- row.change.capabilities || []}>{capability}</.tag>
            <span :if={row.change.capabilities in [nil, []]} class="text-xs text-muted">—</span>
          </span>
        </:col>
        <:col :let={{_id, row}} label="Version" class="font-mono text-xs">
          <span id={"change-version-#{row.id}"}>{row.change.latest_version}</span>
        </:col>
        <:col :let={{_id, row}} label="Pushed" class="font-mono text-xs text-muted">
          <span id={"change-pushed-#{row.id}"}>{format_time(row.change.last_pushed_at)}</span>
        </:col>
        <:col :let={{_id, row}} label="Change requests">
          <ul id={"change-#{row.id}-crs"} class="space-y-1">
            <li :for={cr <- row.change_requests} class="flex items-center gap-2">
              <.text_link
                id={"change-#{row.id}-cr-#{cr.number}"}
                navigate={cr_path(@current_account, @project, cr.number)}
              >
                #{cr.number}
              </.text_link>
              <span id={"change-#{row.id}-cr-#{cr.number}-state"}>
                <.state_badge state={cr.state} />
              </span>
            </li>
            <li :if={row.change_requests == []} class="text-xs text-muted">None</li>
          </ul>
        </:col>
        <:empty_state>
          <%= if @any_changes? do %>
            <.empty_state
              id="changes-filter-empty"
              icon="hero-document-duplicate"
              title={"No #{String.downcase(filter_label(@filter))} changes"}
            >
              No stored change of this project matches the {filter_label(@filter)} filter. Show all changes to see the others.
              <:actions>
                <.button
                  id="empty-show-all"
                  variant="outline"
                  patch={list_path(@current_account, @project, "all")}
                >
                  Show all
                </.button>
              </:actions>
            </.empty_state>
          <% else %>
            <.push_empty_state id="changes-empty" account={@current_account} />
          <% end %>
        </:empty_state>
      </.table>

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
    {rows, next} = fetch(socket, %{"limit" => @page_size, "cursor" => socket.assigns.next_cursor})

    {:noreply,
     socket
     |> assign(row_count: socket.assigns.row_count + length(rows), next_cursor: next)
     |> stream(:changes, rows)}
  end

  @impl true
  def handle_info({:livefilter, :updated, params}, socket) do
    %{current_account: account, project: project} = socket.assigns
    {:noreply, push_patch(socket, to: list_path(account, project, params["status"] || "active"))}
  end

  def handle_info({:project_event, _project_id}, %{assigns: %{refresh_scheduled: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:project_event, _project_id}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, refresh_scheduled: true)}
  end

  def handle_info(:refresh, socket) do
    socket = assign(socket, refresh_scheduled: false)
    {:noreply, load_rows(socket, max(socket.assigns.row_count, @page_size))}
  end

  defp load_rows(socket, count) do
    {rows, next} = fetch_rows(socket, count, nil, [])

    socket
    |> assign(
      row_count: length(rows),
      next_cursor: next,
      any_changes?:
        rows != [] or
          socket.assigns.project |> StoredChanges.status_counts() |> Map.values() |> Enum.sum() >
            0
    )
    |> stream(:changes, rows, reset: true)
  end

  defp fetch_rows(socket, remaining, cursor, acc) do
    params = %{"limit" => min(remaining, @max_page_size)}
    params = if cursor, do: Map.put(params, "cursor", cursor), else: params
    {rows, next} = fetch(socket, params)
    acc = acc ++ rows
    remaining = remaining - length(rows)

    if remaining > 0 and next != nil,
      do: fetch_rows(socket, remaining, next, acc),
      else: {acc, next}
  end

  defp fetch(socket, params) do
    {params, opts} =
      case socket.assigns.filter do
        "active" -> {params, [statuses: @active]}
        "all" -> {params, []}
        status -> {Map.put(params, "status", status), []}
      end

    {:ok, page} = StoredChanges.list(socket.assigns.project, params, opts)

    rows =
      Enum.map(
        page.changes,
        &%{
          id: &1.change_id,
          change: &1,
          change_requests: Map.get(page.change_requests, &1.change_id, [])
        }
      )

    {rows, page.next_cursor}
  end

  # A chip that is always shown and always set: picking a status patches
  # `?status=`, and Clear all returns to the default, active.
  defp status_filter do
    LiveFilter.select(:status,
      label: "Status",
      options: Enum.map(@filters, &{filter_label(&1), &1}),
      custom_param: "status",
      default_visible: true,
      default_value: "active"
    )
  end

  defp filter_label("active"), do: "Active"
  defp filter_label("archived"), do: "Archived"
  defp filter_label("all"), do: "All"

  defp list_path(account, project, filter),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/changes?status=#{filter}"

  defp show_path(account, project, change_id),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/changes/#{change_id}"

  defp cr_path(account, project, number),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/change-requests/#{number}"
end
