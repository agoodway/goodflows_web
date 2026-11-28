defmodule GoodFlowsWeb.ProjectLive.Show do
  @moduledoc """
  A project's overview. Every account member can view it; it writes
  nothing.

  The Change requests card, at the top, counts the `draft` and `open`
  change requests by verdict state and lists the 5 most recently updated.
  The Runs card below it shows the newest run of each workflow on the
  project's default branch (dirty runs count) and the 5 most recent runs,
  folded as the run list folds called runs, each saying how many runs it
  called (design D6).

  The Changes card, between them, counts the stored changes whose latest
  status is `proposed` and `approved` and lists the 5 most recently
  pushed of them; a project with no stored change shows how to push one,
  and one whose changes are all archived says that no change is active.

  The cards reload 500 ms after a run of the project is stored
  (`GoodFlows.WorkflowRuns.topic/1`) or a project event is recorded
  (`GoodFlows.ProjectEvents.topic/1`).
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.ChangeRequestComponents
  import GoodFlowsWeb.StoredChangeComponents
  import GoodFlowsWeb.WorkflowRunComponents

  alias GoodFlows.ChangeRequests
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects
  alias GoodFlows.StoredChanges
  alias GoodFlows.WorkflowRuns

  @refresh_ms 500
  @recent 5
  @verdict_order ~w(mergeable needs_review blocked pending)

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    account = socket.assigns.current_account

    case Projects.get_project(account, slug) do
      {:ok, project} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(GoodFlows.PubSub, WorkflowRuns.topic(project.id))
          Phoenix.PubSub.subscribe(GoodFlows.PubSub, ProjectEvents.topic(project.id))
        end

        {:ok,
         socket
         |> assign(
           page_title: project.slug,
           active_nav: :projects,
           project: project,
           breadcrumbs: [
             %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
             %{label: "Projects", to: ~p"/dashboard/accounts/#{account.id}/projects"},
             %{label: project.slug}
           ],
           refresh_scheduled: false
         )
         |> load()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Project not found")
         |> push_navigate(to: ~p"/dashboard/accounts/#{account.id}/projects")}
    end
  end

  defp load(socket) do
    %{current_account: account, project: project} = socket.assigns

    {:ok, %{runs: recent}} =
      WorkflowRuns.list_runs(account, project, %{"limit" => @recent}, fold_children: true)

    children =
      project
      |> WorkflowRuns.children(Enum.map(recent, & &1.run_id))
      |> Enum.group_by(& &1.parent_run_id, &%{run: &1, children: []})

    assign(socket,
      latest: WorkflowRuns.latest_by_workflow_on_branch(project, project.default_branch),
      recent: recent,
      children: children,
      counts: ChangeRequests.verdict_counts(project),
      change_requests: ChangeRequests.recent_active(project, @recent),
      change_counts: StoredChanges.status_counts(project),
      active_changes: active_changes(project)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-folder">
        <span id="project-slug" class="font-mono">{@project.slug}</span>
        <:subtitle>
          Default branch <code id="project-default-branch">{@project.default_branch}</code>
        </:subtitle>
        <:actions>
          <.button
            id="review-policy-link"
            variant="outline"
            size="sm"
            icon="hero-scale"
            navigate={
              ~p"/dashboard/accounts/#{@current_account.id}/projects/#{@project.slug}/review-policy"
            }
          >
            Review policy
          </.button>
        </:actions>
      </.header>

      <.panel id="change-requests-card" title="Change requests" icon="hero-arrows-right-left">
        <:actions>
          <.text_link
            id="change-requests-link"
            navigate={
              ~p"/dashboard/accounts/#{@current_account.id}/projects/#{@project.slug}/change-requests"
            }
          >
            <span class="normal-case tracking-normal">All change requests</span>
          </.text_link>
        </:actions>
        <dl id="verdict-counts" class="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <div
            :for={state <- verdict_order()}
            id={"count-#{state}"}
            class="rounded-sm border border-base-300 p-3"
          >
            <dt><.verdict_badge state={state} /></dt>
            <dd class="mt-2 font-mono text-lg font-semibold">{@counts[state]}</dd>
          </div>
        </dl>
        <p :if={@change_requests == []} id="no-active-change-requests" class="mt-4 text-sm text-muted">
          No change request is active.
        </p>
        <ul :if={@change_requests != []} id="active-change-requests" class="mt-4 list-table">
          <li
            :for={cr <- @change_requests}
            id={"change-request-#{cr.number}"}
            class="run-row grid-cols-[1fr_auto] items-center"
          >
            <span class="flex min-w-0 flex-wrap items-center gap-2">
              <span class="font-mono text-xs text-muted">#{cr.number}</span>
              <.link
                navigate={
                  ~p"/dashboard/accounts/#{@current_account.id}/projects/#{@project.slug}/change-requests/#{cr.number}"
                }
                class="min-w-0 break-words font-medium hover:underline"
              >
                {cr.title}
              </.link>
              <.state_badge :if={cr.state == "draft"} state={cr.state} />
            </span>
            <span class="flex flex-col items-end gap-1">
              <.verdict_badge state={(cr.verdict && cr.verdict.state) || "pending"} />
              <span class="font-mono text-xs text-muted">{format_time(cr.updated_at)}</span>
            </span>
          </li>
        </ul>
      </.panel>

      <.panel id="changes-card" title="Changes" icon="hero-document-duplicate">
        <:actions>
          <.text_link id="changes-link" navigate={changes_path(@current_account, @project)}>
            <span class="normal-case tracking-normal">All changes</span>
          </.text_link>
        </:actions>
        <%= if @change_counts |> Map.values() |> Enum.sum() == 0 do %>
          <.push_empty_state id="changes-card-empty" account={@current_account} />
        <% else %>
          <dl id="change-counts" class="grid grid-cols-2 gap-3">
            <div
              :for={status <- ~w(proposed approved)}
              id={"changes-count-#{status}"}
              class="rounded-sm border border-base-300 p-3"
            >
              <dt><.change_status_badge status={status} /></dt>
              <dd class="mt-2 font-mono text-lg font-semibold">{@change_counts[status]}</dd>
            </div>
          </dl>
          <p :if={@active_changes == []} id="no-active-changes" class="mt-4 text-sm text-muted">
            No change is active: every stored change is archived.
          </p>
          <ul :if={@active_changes != []} id="active-changes" class="mt-4 list-table">
            <li
              :for={change <- @active_changes}
              id={"active-change-#{change.change_id}"}
              data-change-id={change.change_id}
              class="run-row grid-cols-[1fr_auto] items-center"
            >
              <span class="flex min-w-0 flex-wrap items-center gap-2">
                <.link
                  navigate={
                    ~p"/dashboard/accounts/#{@current_account.id}/projects/#{@project.slug}/changes/#{change.change_id}"
                  }
                  class="min-w-0 break-all font-mono text-sm font-medium hover:underline"
                >
                  {change.change_id}
                </.link>
                <span class="font-mono text-xs text-muted">v{change.latest_version}</span>
              </span>
              <span class="flex flex-col items-end gap-1">
                <.change_status_badge status={change.status} />
                <span class="font-mono text-xs text-muted">{format_time(change.last_pushed_at)}</span>
              </span>
            </li>
          </ul>
        <% end %>
      </.panel>

      <.panel id="runs-card" title="Runs" icon="hero-play-circle">
        <:actions>
          <.text_link id="runs-link" navigate={runs_path(@current_account, @project)}>
            <span class="normal-case tracking-normal">All runs</span>
          </.text_link>
        </:actions>
        <%= if @recent == [] and @latest == [] do %>
          <.empty_state id="runs-empty" icon="hero-play-circle" title="No workflow runs yet">
            Set <code>history = true</code>
            in the <code>[reporting]</code>
            block of <code>goodflows.toml</code>
            and give goodflows an API key: every run then uploads here.
            <:actions>
              <.button
                id="runs-empty-api-keys"
                variant="outline"
                navigate={~p"/dashboard/accounts/#{@current_account.id}/api-keys"}
              >
                API keys
              </.button>
            </:actions>
          </.empty_state>
        <% else %>
          <div class="space-y-6">
            <section id="branch-health" class="space-y-2">
              <h3 class="font-mono text-xs font-semibold uppercase tracking-wide text-muted">
                Latest on {@project.default_branch}
              </h3>
              <p :if={@latest == []} id="no-branch-runs" class="text-sm text-muted">
                No run on {@project.default_branch} yet.
              </p>
              <ul :if={@latest != []} class="list-table">
                <li
                  :for={run <- @latest}
                  id={"latest-#{run.workflow}"}
                  class="run-row grid-cols-[1fr_auto] items-center"
                >
                  <span class="flex min-w-0 flex-wrap items-center gap-3">
                    <.outcome_badge outcome={run.outcome} />
                    <.link
                      id={"latest-#{run.workflow}-link"}
                      navigate={run_path(@current_account, @project, run)}
                      class="run-row-id break-all"
                    >
                      {run.workflow}
                    </.link>
                  </span>
                  <span class="flex gap-3 whitespace-nowrap font-mono text-xs text-muted">
                    <span>{format_time(run.started_at)}</span>
                    <span>{duration(run.duration_ms)}</span>
                  </span>
                </li>
              </ul>
            </section>
            <section id="recent-runs" class="space-y-2">
              <h3 class="font-mono text-xs font-semibold uppercase tracking-wide text-muted">
                Recent runs
              </h3>
              <ul class="list-table">
                <.run_row
                  :for={run <- @recent}
                  id={"recent-#{run.run_id}"}
                  run={run}
                  to={run_path(@current_account, @project, run)}
                  filter_to={&runs_path(@current_account, @project, %{&1 => &2})}
                  children={Map.get(@children, run.run_id, [])}
                />
              </ul>
            </section>
          </div>
        <% end %>
      </.panel>
    </div>
    """
  end

  @impl true
  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_scheduled: false) |> load()}

  def handle_info(message, socket)
      when is_tuple(message) and elem(message, 0) in [:workflow_run_stored, :project_event] do
    if socket.assigns.refresh_scheduled do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh, @refresh_ms)
      {:noreply, assign(socket, refresh_scheduled: true)}
    end
  end

  defp verdict_order, do: @verdict_order

  defp active_changes(project) do
    {:ok, %{changes: changes}} =
      StoredChanges.list(project, %{"limit" => @recent}, statuses: ~w(proposed approved))

    changes
  end

  defp changes_path(account, project),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/changes"

  defp runs_path(account, project, filters \\ %{}),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/runs?#{filters}"

  defp run_path(account, project, run),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/runs/#{run.run_id}"
end
