defmodule GoodFlowsWeb.ChangeRequestLive.Index do
  @moduledoc """
  Lists a project's change requests, newest first, 50 per page with Load
  more. The filter (`?state=active|merged|closed|all`, default `active`:
  `draft` and `open`) lives in the URL. Every account member can view it;
  it writes nothing.

  A merged row shows a verdict only when it merged without a mergeable
  one (the verdict at merge, marked so); a closed row shows no verdict. Every row's review
  count is the stored verdict's (the merge report keeps none). The page
  refreshes 500 ms after a project event, keeping the filter and every
  loaded row.
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.ChangeRequestComponents

  alias GoodFlows.ChangeRequests
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects

  @page_size 50
  @max_page_size 200
  @refresh_ms 500
  @filters ~w(active merged closed all)

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
           page_title: "Change requests · #{project.slug}",
           active_nav: :projects,
           project: project,
           breadcrumbs: [
             %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
             %{label: "Projects", to: ~p"/dashboard/accounts/#{account.id}/projects"},
             %{
               label: project.slug,
               to: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}"
             },
             %{label: "Change requests"}
           ],
           refresh_scheduled: false
         )}

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
    filter = if params["state"] in @filters, do: params["state"], else: "active"

    {:noreply,
     socket
     |> assign(filter: filter)
     |> LiveFilter.init([state_filter()], [LiveFilter.Filter.new(state_filter(), :eq, filter)])
     |> load_rows(@page_size)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-arrows-right-left">
        Change requests
        <:subtitle>
          Change requests of <code>{@project.slug}</code>, with what each one needs before it merges.
        </:subtitle>
      </.header>

      <LiveFilter.bar filter={@livefilter} theme={:neutral} variant={:neutral} />

      <.table
        id="change-requests"
        rows={@streams.change_requests}
        empty={@row_count == 0}
        row_click={fn {_id, cr} -> JS.navigate(show_path(@current_account, @project, cr)) end}
      >
        <:col :let={{_id, cr}} label="Number" class="font-mono text-xs">#{cr.number}</:col>
        <:col :let={{_id, cr}} label="Title">
          <div class="min-w-0 space-y-1">
            <.link
              id={"change-request-link-#{cr.number}"}
              navigate={show_path(@current_account, @project, cr)}
              class="block break-words font-medium"
            >
              {cr.title}
            </.link>
            <div class="flex flex-wrap items-center gap-1 text-xs text-muted">
              <.tag>{cr.source_branch}</.tag>
              <span aria-hidden="true">→</span>
              <span class="sr-only">into</span>
              <.tag>{cr.target_branch}</.tag>
            </div>
          </div>
        </:col>
        <:col :let={{_id, cr}} label="State">
          <.state_badge :if={cr.state != "open"} state={cr.state} />
        </:col>
        <:col :let={{_id, cr}} label="Verdict">
          <div
            :if={
              cr.state in ~w(draft open) or
                (cr.state == "merged" and cr.merged_without_mergeable_verdict)
            }
            id={"verdict-#{cr.number}"}
            class="flex flex-col items-start gap-1"
          >
            <.verdict_badge state={row_verdict(cr)} />
            <span
              :if={cr.state == "merged" and cr.merged_without_mergeable_verdict}
              id={"merged-unmergeable-#{cr.number}"}
              class="text-xs text-muted"
            >
              Merged without a mergeable verdict
            </span>
          </div>
        </:col>
        <:col :let={{_id, cr}} label="Review" class="font-mono text-xs">
          <span id={"review-count-#{cr.number}"}>{review_count(cr)}</span>
        </:col>
        <:col :let={{_id, cr}} label="Updated" class="font-mono text-xs text-muted">
          {format_time(cr.updated_at)}
        </:col>
        <:empty_state>
          <.empty_state
            id="change-requests-empty"
            icon="hero-arrows-right-left"
            title={empty_title(@filter)}
          >
            <%= if @filter == "all" do %>
              Change requests are opened with the goodflows CLI, which reports their commits, claims and checks here.
            <% else %>
              Show all change requests to see the ones in other states.
            <% end %>
            <:actions :if={@filter != "all"}>
              <.button
                id="empty-show-all"
                variant="outline"
                patch={list_path(@current_account, @project, "all")}
              >
                Show all
              </.button>
            </:actions>
          </.empty_state>
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
    %{change_requests: rows, next_cursor: next} =
      fetch(socket, %{"limit" => @page_size, "cursor" => socket.assigns.next_cursor})

    {:noreply,
     socket
     |> assign(row_count: socket.assigns.row_count + length(rows), next_cursor: next)
     |> stream(:change_requests, rows)}
  end

  @impl true
  def handle_info({:livefilter, :updated, params}, socket) do
    %{current_account: account, project: project} = socket.assigns
    {:noreply, push_patch(socket, to: list_path(account, project, params["state"] || "active"))}
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
    |> assign(row_count: length(rows), next_cursor: next)
    |> stream(:change_requests, rows, reset: true)
  end

  defp fetch_rows(socket, remaining, cursor, acc) do
    params = %{"limit" => min(remaining, @max_page_size)}
    params = if cursor, do: Map.put(params, "cursor", cursor), else: params
    %{change_requests: rows, next_cursor: next} = fetch(socket, params)
    acc = acc ++ rows
    remaining = remaining - length(rows)

    if remaining > 0 and next != nil,
      do: fetch_rows(socket, remaining, next, acc),
      else: {acc, next}
  end

  defp fetch(socket, params) do
    {params, opts} =
      case socket.assigns.filter do
        "active" -> {params, [states: ~w(draft open)]}
        "all" -> {params, []}
        state -> {Map.put(params, "state", state), []}
      end

    {:ok, page} =
      ChangeRequests.list(socket.assigns.project, params, [preload: [:verdict]] ++ opts)

    page
  end

  defp row_verdict(%{state: "merged", merged_verdict_state: state}), do: state
  defp row_verdict(%{verdict: nil}), do: "pending"
  defp row_verdict(%{verdict: verdict}), do: verdict.state

  defp review_count(%{verdict: %{review: %{"items" => items, "cleared" => cleared}}}),
    do: "#{cleared} of #{items}"

  defp review_count(_cr), do: "0 of 0"

  # A chip that is always shown and always set: picking a state patches
  # `?state=`, and Clear all returns to the default, active.
  defp state_filter do
    LiveFilter.select(:state,
      label: "State",
      options: Enum.map(@filters, &{filter_label(&1), &1}),
      custom_param: "state",
      default_visible: true,
      default_value: "active"
    )
  end

  defp filter_label("active"), do: "Active"
  defp filter_label("merged"), do: "Merged"
  defp filter_label("closed"), do: "Closed"
  defp filter_label("all"), do: "All"

  defp empty_title("active"), do: "No active change requests"
  defp empty_title("merged"), do: "No merged change requests"
  defp empty_title("closed"), do: "No closed change requests"
  defp empty_title("all"), do: "No change requests yet"

  defp list_path(account, project, filter),
    do:
      ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/change-requests?state=#{filter}"

  defp show_path(account, project, cr),
    do:
      ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/change-requests/#{cr.number}"
end
