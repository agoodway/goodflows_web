defmodule GoodFlowsWeb.ReviewPolicyLive.Show do
  @moduledoc """
  A project's review policy, read-only. Every account member can view it;
  owners and admins write new versions through the API
  (`PUT /api/v1/projects/:project/review-policy`).

  The page shows one version: the current one, or `?version=N`. The
  header switches versions with a picker and Older and Newer buttons. Its
  Settings panel lists every setting of the effective document and marks
  the ones the version leaves at the version 0 default; the Document
  panel shows the policy as written. The History panel lists every stored
  version, newest first, and version 0.

  The page reloads 500 ms after a project event is recorded, so a new
  version shows without a reload.
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.ChangeRequestComponents, only: [format_time: 1]

  alias GoodFlows.Accounts
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ReviewPolicies.{Document, Version}

  @refresh_ms 500
  @history_limit 200

  @sections [
    {"scenarios", "Scenarios",
     [
       {"require_approved_intent", "Hold the verdict pending until an intent set is approved"},
       {"should_failures", "Outcome when a Should scenario fails"},
       {"spec_gaps", "Outcome when a spec scenario has no check"},
       {"approver", "Who may approve a scenario set"},
       {"diff_only", "Outcome when only a diff scenario set exists"}
     ]},
    {"evidence", "Evidence",
     [
       {"required_workflows", "Workflows that must pass at the head"},
       {"ignore_paths", "Paths left out of evidence and coverage"}
     ]},
    {"claims", "Claims",
     [
       {"one_way_door", "Outcome for a one-way-door change"},
       {"min_proof_level", "Lowest accepted proof level"},
       {"open_items", "Outcome when claims leave items open"}
     ]},
    {"size", "Size",
     [
       {"max_changed_files", "Most changed files before review"},
       {"max_changed_lines", "Most changed lines before review"}
     ]},
    {"coverage", "Coverage",
     [
       {"unmapped_areas", "Outcome for changed files no feature maps"},
       {"undriven_features", "Outcome for touched features no run drove"}
     ]},
    {"merge", "Merge",
     [
       {"lease_ttl", "How long a merge lease lasts"},
       {"regrade_merge_result", "Regrade the merge result when the base moved"}
     ]}
  ]

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    account = socket.assigns.current_account

    case Projects.get_project(account, slug) do
      {:ok, project} ->
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(GoodFlows.PubSub, ProjectEvents.topic(project.id))

        {:ok,
         assign(socket,
           page_title: "Review policy · #{project.slug}",
           active_nav: :projects,
           project: project,
           emails: Accounts.member_emails(account),
           breadcrumbs: [
             %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
             %{label: "Projects", to: ~p"/dashboard/accounts/#{account.id}/projects"},
             %{
               label: project.slug,
               to: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}"
             },
             %{label: "Review policy"}
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
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(requested: params["version"]) |> load()}
  end

  defp load(socket) do
    %{project: project, requested: requested} = socket.assigns
    current = ReviewPolicies.current(project)

    {:ok, %{versions: history}} =
      ReviewPolicies.list_versions(project, %{"limit" => @history_limit})

    case shown(project, current, requested) do
      {:ok, version} ->
        assign(socket,
          current: current,
          version: version,
          effective: Document.effective(version.document),
          history: history
        )

      :error ->
        socket
        |> put_flash(:error, "Policy version #{requested} not found")
        |> push_patch(to: policy_path(socket.assigns.current_account, project))
    end
  end

  defp shown(_project, current, nil), do: {:ok, current}

  defp shown(project, _current, requested) do
    with {number, ""} <- Integer.parse(requested),
         {:ok, version} <- ReviewPolicies.get_version(project, number) do
      {:ok, version}
    else
      _other -> :error
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={assigns[:version]} class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-scale">
        Review policy
        <:subtitle>
          <span id="policy-version" class="font-mono">Version {@version.version}</span>
          <span :if={@version.version == @current.version}>· current</span>
          <span :if={@version.version == 0}>· the default</span>
        </:subtitle>
        <:actions>
          <div class="flex items-center gap-2">
            <.button
              id="older-version"
              variant="ghost"
              icon="hero-chevron-left-mini"
              disabled={@version.version == 0}
              aria-label="Older version"
              phx-click="switch_version"
              phx-value-version={@version.version - 1}
            >
              <span class="hidden sm:inline">Older</span>
            </.button>
            <.form
              for={%{}}
              as={:policy}
              id="version-form"
              class="w-44 [&_.ui-field]:mb-0"
              phx-change="switch_version"
            >
              <.input
                type="select"
                id="version-select"
                name="version"
                value={@version.version}
                aria-label="Policy version"
                options={version_options(@history, @current)}
              />
            </.form>
            <.button
              id="newer-version"
              variant="ghost"
              disabled={@version.version == @current.version}
              aria-label="Newer version"
              phx-click="switch_version"
              phx-value-version={@version.version + 1}
            >
              <span class="hidden sm:inline">Newer</span>
              <.icon name="hero-chevron-right-mini" class="size-4 shrink-0" />
            </.button>
          </div>
        </:actions>
      </.header>

      <div :if={@version.version != @current.version} id="old-version-notice">
        <.notice kind="info">
          This is not the current policy. Verdicts use version {@current.version}.
          <.text_link id="current-version-link" patch={policy_path(@current_account, @project)}>
            Show the current version
          </.text_link>
        </.notice>
      </div>

      <div :if={@current.version == 0} id="default-policy-notice">
        <.notice kind="info">
          This project never wrote a policy, so it uses the default. Owners and admins write a
          new version with <code>PUT /api/v1/projects/{@project.slug}/review-policy</code>.
        </.notice>
      </div>

      <.panel id="policy-meta" title="Version" icon="hero-information-circle">
        <.list>
          <:item title="Version"><span class="font-mono">{@version.version}</span></:item>
          <:item title="Written by">
            <span id="policy-written-by">{written_by(@version, @emails)}</span>
          </:item>
          <:item title="Written at">
            <span class="font-mono">{format_time(@version.inserted_at) || "—"}</span>
          </:item>
          <:item title="Note"><span id="policy-note">{@version.note || "—"}</span></:item>
        </.list>
      </.panel>

      <.panel id="policy-settings" title="Settings" icon="hero-adjustments-horizontal">
        <div class="space-y-6">
          <section
            :for={{key, label, settings} <- sections()}
            id={"policy-section-#{key}"}
            class="space-y-2"
          >
            <h3 class="font-mono text-xs font-semibold uppercase tracking-wide text-muted">
              {label}
            </h3>
            <ul class="list-table">
              <li
                :for={{setting, help} <- settings}
                id={"setting-#{key}-#{setting}"}
                class="run-row grid-cols-[1fr_auto] items-center"
              >
                <span class="min-w-0">
                  <span class="font-mono text-sm">{key}.{setting}</span>
                  <span class="block text-xs text-muted">{help}</span>
                </span>
                <span class="flex flex-wrap items-center justify-end gap-2">
                  <.setting_value value={@effective[key][setting]} />
                  <span
                    :if={!set?(@version, key, setting)}
                    class="font-mono text-xs text-muted"
                  >
                    default
                  </span>
                </span>
              </li>
            </ul>
          </section>

          <section id="policy-section-paths" class="space-y-2">
            <h3 class="font-mono text-xs font-semibold uppercase tracking-wide text-muted">
              Sensitive paths
              <span
                :if={!set?(@version, "paths")}
                class="normal-case tracking-normal"
              >
                · default
              </span>
            </h3>
            <p :if={@effective["paths"] == []} id="no-policy-paths" class="text-sm text-muted">
              No path sets an outcome.
            </p>
            <ul :if={@effective["paths"] != []} id="policy-paths" class="list-table">
              <li
                :for={{path, index} <- Enum.with_index(@effective["paths"])}
                id={"policy-path-#{index}"}
                class="run-row grid-cols-[1fr_auto] items-center"
              >
                <span class="min-w-0 break-all font-mono text-sm">{path["glob"]}</span>
                <.tag>{path["outcome"]}</.tag>
              </li>
            </ul>
          </section>
        </div>
      </.panel>

      <.panel id="policy-document" title="Document as written" icon="hero-code-bracket">
        <.code_block>
          <:source>{Jason.encode!(@version.document, pretty: true)}</:source>
        </.code_block>
      </.panel>

      <.panel id="policy-history" title="History" icon="hero-clock">
        <ul class="list-table">
          <li
            :for={version <- @history ++ [%Version{version: 0}]}
            id={"policy-history-#{version.version}"}
            class="run-row grid-cols-[1fr_auto] items-center"
          >
            <span class="flex min-w-0 flex-wrap items-center gap-2">
              <.link
                patch={policy_path(@current_account, @project, version.version)}
                class="run-row-id"
                aria-current={version.version == @version.version && "page"}
              >
                Version {version.version}
              </.link>
              <.status_badge :if={version.version == @current.version} kind="primary">
                Current
              </.status_badge>
              <.status_badge :if={version.version == @version.version}>Shown</.status_badge>
              <span class="min-w-0 break-words text-sm text-muted">
                {if version.version == 0, do: "The default", else: version.note}
              </span>
            </span>
            <span class="flex flex-col items-end gap-1 font-mono text-xs text-muted">
              <span :if={version.version > 0}>{written_by(version, @emails)}</span>
              <span>{format_time(version.inserted_at)}</span>
            </span>
          </li>
        </ul>
      </.panel>
    </div>
    """
  end

  attr :value, :any, required: true

  defp setting_value(%{value: []} = assigns),
    do: ~H|<span class="text-sm text-muted">none</span>|

  defp setting_value(%{value: value} = assigns) when is_list(value),
    do: ~H|<.tag :for={item <- @value}>{item}</.tag>|

  defp setting_value(assigns), do: ~H|<.tag>{to_string(@value)}</.tag>|

  @impl true
  def handle_event("switch_version", %{"version" => version}, socket) do
    %{current_account: account, project: project, current: current} = socket.assigns

    to =
      case Integer.parse(version) do
        {n, ""} when n == current.version -> policy_path(account, project)
        {n, ""} -> policy_path(account, project, n)
        _other -> policy_path(account, project)
      end

    {:noreply, push_patch(socket, to: to)}
  end

  @impl true
  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_scheduled: false) |> load()}

  def handle_info({:project_event, _project_id}, socket) do
    if socket.assigns.refresh_scheduled do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh, @refresh_ms)
      {:noreply, assign(socket, refresh_scheduled: true)}
    end
  end

  defp sections, do: @sections

  defp version_options(history, current) do
    Enum.map(history, &{version_label(&1.version, current), &1.version}) ++
      [{version_label(0, current), 0}]
  end

  defp version_label(n, %Version{version: n}), do: "Version #{n} · current"
  defp version_label(0, _current), do: "Version 0 · default"
  defp version_label(n, _current), do: "Version #{n}"

  # Version 0 is the default itself, so none of its settings is written.
  defp set?(%Version{version: 0}, _section), do: false
  defp set?(%Version{document: document}, section), do: Map.has_key?(document, section)

  defp set?(%Version{version: 0}, _section, _key), do: false

  defp set?(%Version{document: document}, section, key),
    do: Map.has_key?(document[section] || %{}, key)

  defp written_by(%{version: 0}, _emails), do: "—"

  defp written_by(%{account_user_id: id}, emails),
    do: Map.get(emails, id, "a former member")

  defp policy_path(account, project),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/review-policy"

  defp policy_path(account, project, version),
    do:
      ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/review-policy?#{%{version: version}}"
end
