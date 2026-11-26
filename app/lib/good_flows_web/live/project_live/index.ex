defmodule GoodFlowsWeb.ProjectLive.Index do
  @moduledoc """
  Lists, creates, edits, and deletes the current account's projects. Every
  member can view them; only owners and admins can change them. Only
  `default_branch` can be edited: the slug is the project's public name.
  """
  use GoodFlowsWeb, :live_view

  alias GoodFlows.Accounts
  alias GoodFlows.Accounts.AccountUser
  alias GoodFlows.Projects
  alias GoodFlows.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_account

    {:ok,
     socket
     |> assign(
       page_title: "Projects",
       active_nav: :projects,
       breadcrumbs: [
         %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
         %{label: "Projects"}
       ],
       can_manage?: manager?(socket),
       show_create_modal: false,
       edit_project: nil,
       delete_project: nil
     )
     |> assign_create_form(%{})
     |> assign_projects()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-folder">
        Projects
        <:subtitle>
          Projects group recipes, test reports, workflow runs, and change requests in {@current_account.name}.
        </:subtitle>
        <:actions>
          <.button
            :if={@can_manage? and @project_count > 0}
            id="new-project-btn"
            variant="primary"
            size="sm"
            icon="hero-plus"
            phx-click="show_create_modal"
          >
            Create project
          </.button>
        </:actions>
      </.header>

      <.table id="projects" rows={@streams.projects} empty={@project_count == 0}>
        <:col :let={{_id, project}} label="Slug" class="font-mono font-medium">
          <.text_link
            id={"project-#{project.id}"}
            navigate={~p"/dashboard/accounts/#{@current_account.id}/projects/#{project.slug}"}
          >
            {project.slug}
          </.text_link>
        </:col>
        <:col :let={{_id, project}} label="Default branch">
          <.tag>{project.default_branch}</.tag>
        </:col>
        <:col :let={{_id, project}} label="Created" class="font-mono text-xs text-muted">
          {format_datetime(project.inserted_at)}
        </:col>
        <:action :let={{_id, project}} :if={@can_manage?}>
          <.button
            id={"edit-#{project.id}"}
            type="button"
            variant="ghost"
            size="sm"
            phx-click="edit_project"
            phx-value-slug={project.slug}
            aria-label={"Edit #{project.slug}"}
          >
            Edit
          </.button>
          <.button
            id={"delete-#{project.id}"}
            type="button"
            variant="ghost"
            size="sm"
            phx-click="confirm_delete"
            phx-value-slug={project.slug}
            aria-label={"Delete #{project.slug}"}
          >
            Delete
          </.button>
        </:action>
        <:empty_state>
          <.empty_state id="projects-empty" icon="hero-folder" title="No projects yet">
            <%= if @can_manage? do %>
              Create a project to store test reports, workflow runs, and caches for a repository.
            <% else %>
              An account owner or admin can create projects.
            <% end %>
            <:actions :if={@can_manage?}>
              <.button
                id="empty-new-project-btn"
                variant="primary"
                icon="hero-plus"
                phx-click="show_create_modal"
              >
                Create project
              </.button>
            </:actions>
          </.empty_state>
        </:empty_state>
      </.table>
      <p :if={!@can_manage?} id="projects-read-only" class="text-xs text-muted">
        Only account owners and admins can create, edit, or delete projects.
      </p>
    </div>

    <.editor_dialog
      :if={@show_create_modal}
      id="create-project-modal"
      title="Create project"
      on_cancel="hide_create_modal"
    >
      <.form
        for={@create_form}
        id="create-project-form"
        phx-change="validate_create"
        phx-submit="create_project"
      >
        <.input
          field={@create_form[:slug]}
          type="text"
          label="Slug"
          placeholder="my-service"
          autocomplete="off"
          phx-debounce="300"
          hint="Lowercase letters, digits, _ and -. The slug can't be changed later."
        />
        <.input
          field={@create_form[:default_branch]}
          type="text"
          label="Default branch"
          autocomplete="off"
          phx-debounce="300"
          hint="Cache lookups fall back to this branch's scope."
        />
        <.dialog_actions>
          <.button type="button" variant="ghost" phx-click="hide_create_modal">Cancel</.button>
          <.button type="submit" variant="primary" phx-disable-with="Creating…">
            Create project
          </.button>
        </.dialog_actions>
      </.form>
    </.editor_dialog>

    <.editor_dialog
      :if={@edit_project}
      id="edit-project-modal"
      title={"Edit #{@edit_project.slug}"}
      on_cancel="cancel_edit"
    >
      <.form
        for={@edit_form}
        id="edit-project-form"
        phx-change="validate_edit"
        phx-submit="update_project"
      >
        <.input
          field={@edit_form[:default_branch]}
          type="text"
          label="Default branch"
          autocomplete="off"
          phx-debounce="300"
          hint="Later cache lookups fall back to this branch's scope. No cache entries move."
        />
        <.dialog_actions>
          <.button type="button" variant="ghost" phx-click="cancel_edit">Cancel</.button>
          <.button type="submit" variant="primary" phx-disable-with="Saving…">Save</.button>
        </.dialog_actions>
      </.form>
    </.editor_dialog>

    <.confirm_dialog
      :if={@delete_project}
      id="delete-confirm-modal"
      title="Delete project"
      confirm_label="Delete project"
      on_confirm="delete_project"
      on_cancel="cancel_delete"
    >
      <p class="font-medium">Delete “{@delete_project.slug}”?</p>
      <p class="mt-2 text-muted">
        Its caches, cache keys, review policy, feature index, and events are deleted with it.
        A project that still has recipes, test reports, workflow runs, change requests, or
        verify runs can't be deleted. This can't be undone.
      </p>
    </.confirm_dialog>
    """
  end

  @manage_events ~w(show_create_modal create_project edit_project update_project
                     confirm_delete delete_project)

  # The role is checked again on every change, so a member whose role was
  # lowered after mount, or who pushes events by hand, changes nothing.
  @impl true
  def handle_event(event, params, socket) when event in @manage_events do
    if manager?(socket) do
      manage(event, params, socket)
    else
      {:noreply,
       socket
       |> assign(
         can_manage?: false,
         show_create_modal: false,
         edit_project: nil,
         delete_project: nil
       )
       |> assign_projects()
       |> put_flash(:error, "Only account owners and admins can manage projects.")}
    end
  end

  def handle_event("hide_create_modal", _params, socket) do
    {:noreply, socket |> assign(show_create_modal: false) |> assign_create_form(%{})}
  end

  def handle_event("validate_create", %{"project" => params}, socket) do
    {:noreply, assign_create_form(socket, params, :validate)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, edit_project: nil)}
  end

  def handle_event("validate_edit", _params, %{assigns: %{edit_project: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("validate_edit", %{"project" => params}, socket) do
    changeset =
      socket.assigns.edit_project
      |> Project.update_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, edit_form: to_form(changeset))}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_project: nil)}
  end

  defp manage("show_create_modal", _params, socket) do
    {:noreply, assign(socket, show_create_modal: true)}
  end

  defp manage("create_project", %{"project" => params}, socket) do
    case Projects.create_project(socket.assigns.current_account, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(show_create_modal: false)
         |> assign_create_form(%{})
         |> assign_projects()
         |> put_flash(:info, "Project “#{project.slug}” created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, create_form: to_form(changeset))}
    end
  end

  defp manage("edit_project", %{"slug" => slug}, socket) do
    case Projects.get_project(socket.assigns.current_account, slug) do
      {:ok, project} ->
        {:noreply,
         assign(socket,
           edit_project: project,
           edit_form: project |> Project.update_changeset(%{}) |> to_form()
         )}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  defp manage("update_project", _params, %{assigns: %{edit_project: nil}} = socket) do
    {:noreply, socket}
  end

  defp manage("update_project", %{"project" => params}, socket) do
    %{current_account: account, edit_project: project} = socket.assigns

    case Projects.update_project(account, project, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(edit_project: nil)
         |> stream_insert(:projects, project)
         |> put_flash(:info, "Project “#{project.slug}” updated.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, edit_form: to_form(changeset))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(edit_project: nil)
         |> assign_projects()
         |> put_flash(:error, "That project no longer exists.")}
    end
  end

  defp manage("confirm_delete", %{"slug" => slug}, socket) do
    case Projects.get_project(socket.assigns.current_account, slug) do
      {:ok, project} -> {:noreply, assign(socket, delete_project: project)}
      {:error, :not_found} -> {:noreply, socket}
    end
  end

  defp manage("delete_project", _params, %{assigns: %{delete_project: nil}} = socket) do
    {:noreply, socket}
  end

  defp manage("delete_project", _params, socket) do
    %{current_account: account, delete_project: project} = socket.assigns
    socket = assign(socket, delete_project: nil)

    case Projects.delete_project(account, project) do
      :ok ->
        {:noreply,
         socket
         |> assign_projects()
         |> put_flash(:info, "Project “#{project.slug}” deleted.")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign_projects()
         |> put_flash(:error, "That project no longer exists.")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "“#{project.slug}” still has #{blocker(reason)}, so it can't be deleted."
         )}
    end
  end

  # The count and the rows come from one fetch, so the empty state never
  # hides rows another session added.
  defp assign_projects(socket) do
    projects = Projects.list_projects(socket.assigns.current_account)

    socket
    |> assign(project_count: length(projects))
    |> stream(:projects, projects, reset: true)
  end

  defp manager?(socket) do
    %{current_scope: scope, current_account: account} = socket.assigns

    case Accounts.get_account_user(scope.user, account) do
      %AccountUser{} = account_user -> AccountUser.admin?(account_user)
      nil -> false
    end
  end

  defp assign_create_form(socket, params, action \\ nil) do
    changeset = Project.changeset(%Project{}, params)
    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, create_form: to_form(changeset))
  end

  defp blocker(:has_recipes), do: "recipes"
  defp blocker(:has_test_reports), do: "test reports"
  defp blocker(:has_workflow_runs), do: "workflow runs"
  defp blocker(:has_change_requests), do: "change requests"
  defp blocker(:has_verify_runs), do: "verify runs"

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
