defmodule GoodFlowsWeb.StoredChangeLive.Show do
  @moduledoc """
  One stored goodflows change: its latest version, or `?version=N`. Every
  account member can view it; it writes nothing.

  The Version panel shows the version's own fields, each null as not
  given. The Change requests panel lists the change requests of the
  project with this change id. What changed lists the files the version
  added, removed and changed against the version before it, with a line
  diff for each changed file unless either side is over 262,144 UTF-8
  bytes, its changed region (both sides, without the lines they share at
  the start and end) has more than 1,000 lines, or it would take the
  version's changed-region lines past 1,000
  (`GoodFlows.StoredChanges.Files`). Files shows each file: `change.md`
  expanded and the others collapsed until opened, the front matter as a
  code block and the body as Markdown rendered by
  `GoodFlowsWeb.ScenarioMarkdown` with only `http:`, `https:` and
  `mailto:` links kept; a file over the size limit shows as plain text.
  History lists the versions newest first, 50 at a time.

  The page reloads 500 ms after a project event, keeping the version
  shown (the latest when opened without `?version`), the expanded files
  and the loaded History. When the change is gone, or its row is not the
  one the page loaded (deleted and pushed again), it redirects to the
  Changes list with a deleted flash.
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.ChangeRequestComponents, only: [state_badge: 1, format_time: 1]
  import GoodFlowsWeb.StoredChangeComponents
  import GoodFlowsWeb.WorkflowRunComponents, only: [short_sha: 1]

  alias GoodFlows.Accounts
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects
  alias GoodFlows.StoredChanges
  alias GoodFlows.StoredChanges.Files
  alias GoodFlowsWeb.ScenarioMarkdown

  @refresh_ms 500
  @history_page 50
  @max_page_size 200
  @git_diff_step "To see what changed, compare the two versions with git diff in the change's repository."

  @impl true
  def mount(%{"slug" => slug, "change_id" => change_id}, _session, socket) do
    account = socket.assigns.current_account
    projects = ~p"/dashboard/accounts/#{account.id}/projects"

    with {:project, {:ok, project}} <- {:project, Projects.get_project(account, slug)},
         {:ok, %{version: latest}} <- StoredChanges.get(project, change_id) do
      if connected?(socket),
        do: Phoenix.PubSub.subscribe(GoodFlows.PubSub, ProjectEvents.topic(project.id))

      list = ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/changes"

      {:ok,
       assign(socket,
         page_title: "#{change_id} · #{project.slug}",
         active_nav: :projects,
         project: project,
         change_id: change_id,
         change_uuid: latest.stored_change.id,
         breadcrumbs: [
           %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
           %{label: "Projects", to: projects},
           %{
             label: project.slug,
             to: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}"
           },
           %{label: "Changes", to: list},
           %{label: change_id}
         ],
         refresh_scheduled: false,
         open_files: MapSet.new(["change.md"]),
         history_count: @history_page,
         compared: nil
       )}
    else
      {:project, {:error, :not_found}} ->
        {:ok,
         socket
         |> put_flash(:error, "Project #{slug} not found. Pick a project of this account.")
         |> push_navigate(to: projects)}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "Change #{change_id} not found in project #{slug}. Pick a change from the list."
         )
         |> push_navigate(to: ~p"/dashboard/accounts/#{account.id}/projects/#{slug}/changes")}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket) when not is_map_key(socket.assigns, :change_uuid),
    do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    case parse_version(params["version"]) do
      {:ok, requested} ->
        {:noreply, socket |> assign(requested: requested) |> load()}

      :error ->
        {:noreply, not_found(socket, bad_version_message(params["version"], socket))}
    end
  end

  defp parse_version(nil), do: {:ok, nil}

  defp parse_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> :error
    end
  end

  defp parse_version(_version), do: :error

  defp bad_version_message(version, socket) when is_binary(version),
    do:
      "Version #{version} of #{socket.assigns.change_id} not found. " <>
        "Versions are numbered from 1; pick one from the change's History."

  defp bad_version_message(_version, socket),
    do:
      "Version not found: the version in the link is not a number. Versions of " <>
        "#{socket.assigns.change_id} are numbered from 1; pick one from the change's History."

  # A read that finds the change gone, or a different change under its id
  # (deleted and pushed again, D22), counts as a deletion at any step.
  defp load(socket) do
    %{project: project, change_id: change_id, requested: requested} = socket.assigns

    with {:ok, %{version: latest, change_requests: crs}} <- StoredChanges.get(project, change_id),
         true <- same_change?(socket, latest),
         {:ok, version} <- shown(socket, latest, requested),
         {:ok, socket} <- compare(socket, version),
         {:ok, socket} <- load_history(socket) do
      assign(socket,
        latest: latest,
        version: version,
        change_requests: crs,
        emails: Accounts.member_emails(socket.assigns.current_account),
        stored_depends_on: StoredChanges.stored_ids(project, version.depends_on || [])
      )
    else
      {:version_not_found, latest} ->
        not_found(
          socket,
          "Version #{requested} of #{change_id} not found: the latest is version " <>
            "#{latest}. Pick a version from the change's History."
        )

      _deleted ->
        deleted(socket)
    end
  end

  defp same_change?(socket, version), do: version.stored_change.id == socket.assigns.change_uuid

  defp shown(_socket, latest, nil), do: {:ok, latest}
  defp shown(_socket, %{version: n} = latest, n), do: {:ok, latest}

  defp shown(socket, latest, n) do
    case fetch_version(socket, n) do
      {:error, :version_not_found} -> {:version_not_found, latest.version}
      other -> other
    end
  end

  defp fetch_version(socket, n) do
    case StoredChanges.get_version(socket.assigns.project, socket.assigns.change_id, n) do
      {:ok, version} -> if same_change?(socket, version), do: {:ok, version}, else: :deleted
      {:error, :not_found} -> :deleted
      {:error, :version_not_found} -> {:error, :version_not_found}
    end
  end

  # A version never changes, so its comparison is kept across refreshes.
  # It is computed on the connected mount only, not on the dead render.
  defp compare(%{assigns: %{compared: {id, _entries}}} = socket, %{id: id}), do: {:ok, socket}

  defp compare(socket, version) do
    if connected?(socket) do
      with {:ok, previous} <- previous_files(socket, version) do
        {:ok, assign(socket, compared: {version.id, Files.compare(previous, version.files)})}
      end
    else
      {:ok, socket}
    end
  end

  defp previous_files(_socket, %{version: 1}), do: {:ok, nil}

  defp previous_files(socket, version) do
    case fetch_version(socket, version.version - 1) do
      {:ok, previous} -> {:ok, previous.files}
      {:error, :version_not_found} -> {:ok, nil}
      :deleted -> :deleted
    end
  end

  defp load_history(socket) do
    case fetch_history(socket, socket.assigns.history_count, nil, []) do
      {:ok, versions, next} -> {:ok, assign(socket, history: versions, history_next: next)}
      :deleted -> :deleted
    end
  end

  defp fetch_history(socket, remaining, cursor, acc) do
    params = %{"limit" => min(remaining, @max_page_size)}
    params = if cursor, do: Map.put(params, "cursor", cursor), else: params

    with {:ok, %{versions: versions, next_cursor: next}} <-
           StoredChanges.list_versions(socket.assigns.project, socket.assigns.change_id, params),
         true <- Enum.all?(versions, &same_change?(socket, &1)) do
      acc = acc ++ versions
      remaining = remaining - length(versions)

      if remaining > 0 and next != nil,
        do: fetch_history(socket, remaining, next, acc),
        else: {:ok, acc, next}
    else
      _deleted -> :deleted
    end
  end

  defp deleted(socket) do
    %{project: project, change_id: change_id} = socket.assigns

    socket
    |> put_flash(
      :error,
      "Change #{change_id} was deleted from project #{project.slug}. Pick another change from the list."
    )
    |> push_navigate(to: list_path(socket.assigns.current_account, project))
  end

  defp not_found(socket, message) do
    socket
    |> put_flash(:error, message)
    |> push_navigate(to: list_path(socket.assigns.current_account, socket.assigns.project))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={assigns[:version]} class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-document-duplicate">
        <span id="change-id" class="break-all font-mono">{@change_id}</span>
        <:subtitle>
          <span class="font-mono">Version {@version.version}</span>
          <span :if={@version.version == @latest.version}>· latest</span>
        </:subtitle>
      </.header>

      <div :if={@version.version != @latest.version} id="not-latest-notice">
        <.notice kind="info">
          This is not the latest version of the change. Version {@latest.version} is the latest.
          <.text_link
            id="latest-version-link"
            patch={show_path(@current_account, @project, @change_id)}
          >
            Show the latest version
          </.text_link>
        </.notice>
      </div>

      <.panel id="version-panel" title="Version" icon="hero-information-circle">
        <.list>
          <:item title="Version">
            <span id="change-version" class="font-mono">{@version.version}</span>
          </:item>
          <:item title="Status">
            <span id="change-status"><.change_status_badge status={@version.status} /></span>
          </:item>
          <:item title="Size">
            <span id="change-size">
              <%= if @version.size do %>
                <span class="font-mono">{@version.size}</span>
              <% else %>
                <.not_given />
              <% end %>
            </span>
          </:item>
          <:item title="Door">
            <span id="change-door">
              <%= if @version.door do %>
                <span class="font-mono">{@version.door}</span>
              <% else %>
                <.not_given />
              <% end %>
            </span>
          </:item>
          <:item title="Capabilities">
            <span id="change-capabilities" class="flex flex-wrap justify-end gap-1">
              <%= case @version.capabilities do %>
                <% nil -> %>
                  <.not_given />
                <% [] -> %>
                  <.not_given label="None" />
                <% capabilities -> %>
                  <.tag :for={capability <- capabilities}>{capability}</.tag>
              <% end %>
            </span>
          </:item>
          <:item title="Depends on">
            <span id="change-depends-on" class="flex flex-wrap justify-end gap-2">
              <%= case @version.depends_on do %>
                <% nil -> %>
                  <.not_given />
                <% [] -> %>
                  <.not_given label="None" />
                <% depends_on -> %>
                  <%= for id <- depends_on do %>
                    <%= if id in @stored_depends_on do %>
                      <.text_link
                        id={"depends-on-#{id}"}
                        navigate={show_path(@current_account, @project, id)}
                      >
                        <span class="font-mono">{id}</span>
                      </.text_link>
                    <% else %>
                      <span id={"depends-on-#{id}"} title="Not stored in this project">
                        <.tag>{id}</.tag>
                      </span>
                    <% end %>
                  <% end %>
              <% end %>
            </span>
          </:item>
          <:item title="Commit">
            <span id="change-commit">
              <.tag :if={@version.commit}>{short_sha(@version.commit)}</.tag>
              <.not_given :if={!@version.commit} label="No commit" />
            </span>
          </:item>
          <:item title="Branch">
            <span id="change-branch">
              <.tag :if={@version.branch}>{@version.branch}</.tag>
              <.not_given :if={!@version.branch} label="Detached HEAD" />
            </span>
          </:item>
          <:item title="Checkout">
            <span id="change-dirty">{if @version.dirty, do: "Dirty", else: "Clean"}</span>
          </:item>
          <:item title="Pushed by">
            <span id="change-pusher">{pusher(@version, @emails)}</span>
          </:item>
          <:item title="Pushed at">
            <span id="change-pushed-at" class="font-mono">{format_time(@version.inserted_at)}</span>
          </:item>
        </.list>
      </.panel>

      <.panel id="change-requests-panel" title="Change requests" icon="hero-arrows-right-left">
        <p :if={@change_requests == []} id="no-change-requests" class="text-sm text-muted">
          No change request exists for this change yet. One links to it when it is opened with change id <code>{@change_id}</code>.
        </p>
        <ul :if={@change_requests != []} id="linked-change-requests" class="list-table">
          <li
            :for={cr <- @change_requests}
            id={"linked-cr-row-#{cr.number}"}
            class="run-row grid-cols-[1fr_auto] items-center"
          >
            <.text_link
              id={"linked-cr-#{cr.number}"}
              navigate={cr_path(@current_account, @project, cr.number)}
            >
              <span class="font-mono">#{cr.number}</span>
            </.text_link>
            <span id={"linked-cr-#{cr.number}-state"}><.state_badge state={cr.state} /></span>
          </li>
        </ul>
      </.panel>

      <.panel id="version-changes-panel" title="What changed" icon="hero-arrows-up-down">
        <p class="mb-3 text-sm text-muted">
          {if @version.version == 1,
            do: "Version 1 adds every file of the change.",
            else: "Compared with version #{@version.version - 1}."}
        </p>
        <p :if={!@compared} id="version-changes-pending" class="text-sm text-muted">
          Comparing the files…
        </p>
        <p
          :if={@compared && changes(@compared) == []}
          id="no-version-changes"
          class="text-sm text-muted"
        >
          No file changed.
        </p>
        <ul id="version-changes" class="space-y-3">
          <li
            :for={entry <- changes(@compared)}
            data-path={entry.path}
            data-change={entry.change}
            class="space-y-2"
          >
            <div class="flex flex-wrap items-center gap-2">
              <.status_badge kind={if entry.change == :added, do: "primary", else: "neutral"}>
                {change_label(entry.change)}
              </.status_badge>
              <span class="break-all font-mono text-sm">{entry.path}</span>
            </div>
            <%= case entry.diff do %>
              <% {:lines, rows} -> %>
                <div
                  data-role="line-diff"
                  class="stored-change-diff"
                  tabindex="0"
                  role="region"
                  aria-label={"Line diff of #{entry.path}"}
                >
                  <div
                    :for={row <- rows}
                    data-op={row.op}
                    class={["stored-change-diff-line", "stored-change-diff-#{row.op}"]}
                  >
                    <%= if row.op == :skip do %>
                      <span class="stored-change-diff-text">{skip_label(row.count)}</span>
                    <% else %>
                      <span class="stored-change-diff-number">{row.old}</span>
                      <span class="stored-change-diff-number">{row.new}</span>
                      <span class="stored-change-diff-mark" aria-hidden="true">{diff_mark(row.op)}</span>
                      <span class="sr-only">{diff_name(row.op)}</span>
                      <span class="stored-change-diff-text">{row.text}</span>
                    <% end %>
                  </div>
                </div>
              <% {:skipped, reason} -> %>
                <p data-role="no-diff" class="text-sm text-muted">{no_diff_reason(reason)}</p>
              <% nil -> %>
            <% end %>
          </li>
        </ul>
      </.panel>

      <.panel id="files-panel" title="Files" icon="hero-document-text">
        <ul id="files" class="space-y-3">
          <li
            :for={path <- file_order(@version.files)}
            id={"file-#{dom_id(path)}"}
            data-path={path}
            class="space-y-2"
          >
            <div class="flex items-center gap-2">
              <.button
                id={"file-#{dom_id(path)}-toggle"}
                type="button"
                variant="ghost"
                size="sm"
                icon={
                  if MapSet.member?(@open_files, path),
                    do: "hero-chevron-down",
                    else: "hero-chevron-right"
                }
                phx-click="toggle_file"
                phx-value-path={path}
                aria-expanded={to_string(MapSet.member?(@open_files, path))}
                aria-controls={MapSet.member?(@open_files, path) && "file-#{dom_id(path)}-body"}
              >
                <span class="sr-only">
                  {if MapSet.member?(@open_files, path), do: "Hide", else: "Show"}
                </span>
                <span class="break-all font-mono">{path}</span>
              </.button>
            </div>
            <div
              :if={MapSet.member?(@open_files, path)}
              id={"file-#{dom_id(path)}-body"}
              data-role="file-body"
              class="space-y-3"
            >
              <.file_body text={@version.files[path]} />
            </div>
          </li>
        </ul>
      </.panel>

      <.panel id="history-panel" title="History" icon="hero-clock">
        <ul id="history" class="list-table">
          <li
            :for={version <- @history}
            id={"history-#{version.version}"}
            class="run-row grid-cols-[1fr_auto] items-center"
          >
            <span class="flex min-w-0 flex-wrap items-center gap-2">
              <.link
                patch={version_path(@current_account, @project, @change_id, version, @latest)}
                class="run-row-id"
                aria-current={version.version == @version.version && "page"}
              >
                Version {version.version}
              </.link>
              <.change_status_badge status={version.status} />
              <span :if={version.version == @latest.version}>
                <.status_badge kind="primary">Latest</.status_badge>
              </span>
              <span :if={version.version == @version.version} data-role="viewed">
                <.status_badge>Viewed</.status_badge>
              </span>
            </span>
            <span class="flex flex-col items-end gap-1 font-mono text-xs text-muted">
              <span>{pusher(version, @emails)}</span>
              <span class="flex items-center gap-2">
                <.tag :if={version.commit}>{short_sha(version.commit)}</.tag>
                <span :if={!version.commit}>No commit</span>
                <span>{format_time(version.inserted_at)}</span>
              </span>
            </span>
          </li>
        </ul>
        <div :if={@history_next} class="mt-4 flex justify-center">
          <.button
            id="history-load-more"
            variant="outline"
            size="sm"
            phx-click="load_more_history"
            phx-disable-with="Loading…"
          >
            Load more
          </.button>
        </div>
      </.panel>
    </div>
    """
  end

  attr :text, :string, required: true

  defp file_body(assigns) do
    if Files.too_large?(assigns.text) do
      ~H"""
      <p data-role="too-large" class="text-sm text-muted">
        This file is over {format_bytes(Files.max_render_bytes())} bytes, so it shows as plain text instead of rendered Markdown. To read it rendered, open it in the change's repository.
      </p>
      <.code_block data-role="plain-text" class="stored-change-plain-text">
        <:source>{@text}</:source>
      </.code_block>
      """
    else
      {front_matter, body} = Files.split(assigns.text)
      assigns = assign(assigns, front_matter: front_matter, body: body)

      ~H"""
      <.code_block :if={@front_matter} data-role="front-matter" title="Front matter">
        <:source>{@front_matter}</:source>
      </.code_block>
      <div class="scenario-markdown">
        {ScenarioMarkdown.to_html(@body, only_scheme_links: true)}
      </div>
      """
    end
  end

  @impl true
  def handle_event("toggle_file", %{"path" => path}, socket) do
    open = socket.assigns.open_files

    open =
      if MapSet.member?(open, path), do: MapSet.delete(open, path), else: MapSet.put(open, path)

    {:noreply, assign(socket, open_files: open)}
  end

  def handle_event("load_more_history", _params, %{assigns: %{history_next: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more_history", _params, socket) do
    socket = assign(socket, history_count: length(socket.assigns.history) + @history_page)

    case load_history(socket) do
      {:ok, socket} -> {:noreply, socket}
      :deleted -> {:noreply, deleted(socket)}
    end
  end

  @impl true
  def handle_info({:project_event, _project_id}, %{assigns: %{refresh_scheduled: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:project_event, _project_id}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, refresh_scheduled: true)}
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_scheduled: false) |> load()}

  defp changes({_id, entries}), do: entries
  defp changes(nil), do: []

  # change.md first, then the rest by path.
  defp file_order(files),
    do: files |> Map.keys() |> Enum.sort_by(&{&1 != "change.md", &1})

  # Base64url keeps distinct paths distinct (a.md and a_md) in an id.
  defp dom_id(path), do: Base.url_encode64(path, padding: false)

  defp skip_label(1), do: "1 unchanged line"
  defp skip_label(count), do: "#{count} unchanged lines"

  defp change_label(:added), do: "Added"
  defp change_label(:removed), do: "Removed"
  defp change_label(:changed), do: "Changed"

  defp diff_mark(:ins), do: "+"
  defp diff_mark(:del), do: "-"
  defp diff_mark(:eq), do: " "

  defp diff_name(:ins), do: "Added line:"
  defp diff_name(:del), do: "Removed line:"
  defp diff_name(:eq), do: "Unchanged line:"

  defp no_diff_reason(:too_large),
    do:
      "No line diff: one of its two versions is over #{format_bytes(Files.max_render_bytes())} bytes. " <>
        @git_diff_step

  defp no_diff_reason(:too_many_lines),
    do:
      "No line diff: its two versions differ across more than " <>
        "#{format_bytes(Files.max_diff_lines())} lines together. " <> @git_diff_step

  defp no_diff_reason(:version_budget),
    do:
      "No line diff: the files listed before it use up this version's limit of " <>
        "#{format_bytes(Files.max_version_diff_lines())} changed lines in line diffs. " <>
        @git_diff_step

  defp format_bytes(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp pusher(%{account_user_id: id}, emails), do: Map.get(emails, id, "a former member")

  defp list_path(account, project),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/changes"

  defp show_path(account, project, change_id),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/changes/#{change_id}"

  defp version_path(account, project, change_id, %{version: n}, %{version: n}),
    do: show_path(account, project, change_id)

  defp version_path(account, project, change_id, version, _latest),
    do:
      ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/changes/#{change_id}?#{%{version: version.version}}"

  defp cr_path(account, project, number),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/change-requests/#{number}"
end
