defmodule GoodFlowsWeb.ChangeRequestLive.Show do
  @moduledoc """
  One change request: its verdict and why, the review packet at the
  current head with open tasks, the evidence at the head, the merge status
  and the state history. Every account member can view it.

  On a `draft` or `open` change request, a member answers review items
  here (`GoodFlows.Review.answer/4` with a `dashboard` actor). The answer
  is bound to the head the page showed. Actions a member may not take,
  under the policy's `scenarios.approver`, are hidden, and the domain
  refuses them anyway.

  The page reloads 500 ms after a project event, keeping an open answer
  dialog.
  """
  use GoodFlowsWeb, :live_view

  import GoodFlowsWeb.ChangeRequestComponents

  alias GoodFlows.Accounts
  alias GoodFlows.ChangeRequests
  alias GoodFlows.MergeLeases
  alias GoodFlows.ProjectEvents
  alias GoodFlows.Projects
  alias GoodFlows.Repo
  alias GoodFlows.Review
  alias GoodFlows.Review.Packet
  alias GoodFlows.ReviewPolicies
  alias GoodFlows.ScenarioSets

  @refresh_ms 500

  @kinds %{
    "scenario_set_approval" => "Scenario set approval",
    "diff_only_set" => "Diff-only scenario set",
    "diff_set_weakened" => "Weakened diff set",
    "failed_scenario" => "Failed scenario",
    "not_run" => "Scenario not run",
    "spec_gap" => "Spec gap",
    "one_way_door" => "One-way door",
    "unproven_claim" => "Unproven claim",
    "open_item" => "Open item",
    "question" => "Question",
    "sensitive_path" => "Sensitive path",
    "size" => "Size",
    "unmapped_area" => "Unmapped area",
    "undriven_feature" => "Undriven feature"
  }

  @answer_labels %{
    "approve" => "Approve",
    "reject" => "Reject",
    "request_change" => "Request change",
    "choose" => "Choose"
  }

  @approval_kinds ~w(scenario_set_approval diff_set_weakened)

  @impl true
  def mount(%{"slug" => slug, "number" => number}, _session, socket) do
    account = socket.assigns.current_account
    projects = ~p"/dashboard/accounts/#{account.id}/projects"

    with {:project, {:ok, project}} <- {:project, Projects.get_project(account, slug)},
         {:ok, number} <- parse_number(number),
         {:ok, change_request} <- ChangeRequests.get(project, number) do
      if connected?(socket),
        do: Phoenix.PubSub.subscribe(GoodFlows.PubSub, ProjectEvents.topic(project.id))

      {:ok,
       socket
       |> assign(
         page_title: "##{number} · #{project.slug}",
         active_nav: :projects,
         project: project,
         number: number,
         breadcrumbs: [
           %{label: "Dashboard", to: ~p"/dashboard/accounts/#{account.id}"},
           %{label: "Projects", to: projects},
           %{label: project.slug},
           %{
             label: "Change requests",
             to: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/change-requests"
           },
           %{label: "##{number}"}
         ],
         refresh_scheduled: false,
         dialog: nil,
         answer_form: nil
       )
       |> load(change_request)}
    else
      {:project, {:error, :not_found}} ->
        {:ok, socket |> put_flash(:error, "Project not found") |> push_navigate(to: projects)}

      {:error, _not_found} ->
        {:ok,
         socket |> put_flash(:error, "Change request not found") |> push_navigate(to: projects)}
    end
  end

  defp parse_number(number) do
    case Integer.parse(number) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, :not_found}
    end
  end

  defp load(socket, change_request) do
    %{current_scope: scope, current_account: account} = socket.assigns
    loaded = ChangeRequests.load(change_request)
    change_request = loaded.change_request
    active? = ChangeRequests.require_active(change_request) == :ok
    membership = Accounts.get_account_user(scope.user, account)

    {packet, tasks} =
      if active? and loaded.verdict do
        {:ok, tasks} = Review.list_tasks(change_request, %{"state" => "open"})
        {Review.packet(change_request), tasks}
      else
        {nil, []}
      end

    lease = if active?, do: MergeLeases.held(change_request)

    assign(socket,
      change_request: change_request,
      loaded: loaded,
      active?: active?,
      membership: membership,
      approver:
        ReviewPolicies.compiled(change_request.project_id).effective["scenarios"]["approver"],
      may_approve?: membership && ScenarioSets.check_approver(change_request, membership) == :ok,
      packet: packet,
      tasks: tasks,
      lease: lease && Repo.preload(lease, :api_key),
      claims: Packet.claims(change_request),
      emails: Accounts.member_emails(account)
    )
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :shown, shown_verdict(assigns.change_request, assigns.loaded.verdict))

    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-arrows-right-left">
        <span class="font-mono text-muted">#{@change_request.number}</span>
        <span id="change-request-title" class="break-words">{@change_request.title}</span>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <.state_badge state={@change_request.state} />
            <span :if={@shown} id="header-verdict"><.verdict_badge state={@shown.state} /></span>
            <span class="inline-flex flex-wrap items-center gap-1">
              <.tag>{@change_request.source_branch}</.tag>
              <span aria-hidden="true">→</span>
              <span class="sr-only">into</span>
              <.tag>{@change_request.target_branch}</.tag>
            </span>
          </span>
        </:subtitle>
      </.header>

      <div
        :if={@change_request.state == "merged" and @change_request.merged_without_mergeable_verdict}
        id="merged-unmergeable-notice"
      >
        <.notice kind="warning">
          Merged without a mergeable verdict. The verdict at merge was <strong>{verdict_label(@change_request.merged_verdict_state)}</strong>.
        </.notice>
      </div>

      <.panel id="verdict-panel" title="Verdict reasons" icon="hero-scale">
        <%= cond do %>
          <% @change_request.state == "closed" -> %>
            <p class="text-sm text-muted">
              A closed change request has no current verdict.
            </p>
          <% @shown == nil -> %>
            <p id="verdict-not-computed" class="text-sm text-muted">
              The verdict has not been computed.
            </p>
          <% true -> %>
            <p :if={@shown.reasons == []} id="no-reasons" class="text-sm">
              No rule fired at this head.
            </p>
            <ol :if={@shown.reasons != []} id="reasons" class="space-y-3">
              <li
                :for={{reason, index} <- Enum.with_index(@shown.reasons)}
                id={"reason-#{index}"}
                data-rule={reason["rule"]}
                class="space-y-1 border-b border-base-300 pb-3 last:border-b-0 last:pb-0"
              >
                <div class="flex flex-wrap items-center gap-2">
                  <.verdict_badge state={reason["outcome"]} />
                  <span class="text-sm">{reason["message"]}</span>
                </div>
                <div class="flex flex-wrap items-center gap-2 text-xs text-muted">
                  <span>Rule
                  <.tag>{reason["rule"]}</.tag></span>
                  <span :if={(reason["subject"] || []) != []} id={"reason-#{index}-subject"}>
                    Subject
                    <.tag>{Enum.join(reason["subject"], ", ")}</.tag>
                  </span>
                </div>
              </li>
            </ol>
            <p class="mt-4 font-mono text-xs text-muted">
              Policy version {@shown.policy_version}
              <span :if={@shown.computed_at}>· computed {format_time(@shown.computed_at)}</span>
              <span :if={@change_request.state == "merged"}>· at merge</span>
            </p>
        <% end %>
      </.panel>

      <.panel :if={@packet} id="review-panel" title="Review items" icon="hero-check-badge">
        <:actions>
          <span id="review-cleared" class="font-mono text-xs text-muted">
            {cleared(@loaded.verdict)}
          </span>
        </:actions>
        <p :if={@packet.items == []} id="no-items" class="text-sm text-muted">
          Nothing at this head needs a person.
        </p>
        <ul :if={@packet.items != []} class="space-y-4">
          <li
            :for={item <- @packet.items}
            id={item_dom_id(item)}
            class="space-y-2 border-b border-base-300 pb-4 last:border-b-0 last:pb-0"
          >
            <div class="flex flex-wrap items-center gap-2">
              <.status_badge>{kind_label(item.kind)}</.status_badge>
              <span class="break-words text-sm">{item.message}</span>
            </div>
            <p :if={item.kind == "question"} class="break-words text-sm font-medium">
              {item.data[:text]}
            </p>
            <p :if={item.answer} id={"#{item_dom_id(item)}-answer"} class="text-sm">
              {answer_verb(item.answer)} by {email(@emails, item.answer.account_user_id)}
              <span class="whitespace-nowrap font-mono text-xs text-muted">
                · {format_time(item.answer.inserted_at)}
              </span>
              <span :if={item.answer.note} class="block break-words text-muted">
                “{item.answer.note}”
              </span>
            </p>
            <p :if={!item.answer} id={"#{item_dom_id(item)}-unanswered"} class="text-sm text-muted">
              No answer at this head.
            </p>
            <%= if may_answer?(item, @may_approve?, @membership) do %>
              <div class="flex flex-wrap gap-2">
                <.button
                  :for={answer <- item.answers}
                  id={"#{item_dom_id(item)}-#{answer}"}
                  type="button"
                  variant="soft"
                  size="sm"
                  phx-click="open_answer"
                  phx-value-item={item.id}
                  phx-value-answer={answer}
                  aria-label={"#{answer_label(answer)}: #{kind_label(item.kind)}"}
                >
                  {answer_label(answer)}
                </.button>
              </div>
            <% else %>
              <p id={"#{item_dom_id(item)}-who"} class="text-xs text-muted">
                {who_may_answer(@approver)}
              </p>
            <% end %>
          </li>
        </ul>
        <div :if={@tasks != []} id="open-tasks" class="mt-6 space-y-2">
          <h3 class="font-mono text-xs font-semibold uppercase tracking-wide text-muted">
            Open tasks
          </h3>
          <ul class="space-y-2">
            <li :for={task <- @tasks} id={"task-#{task.id}"} class="text-sm">
              <span class="font-medium">{kind_label(task.kind)}</span>
              · {answer_verb(task)} by {email(@emails, task.created_by_account_user_id)}
              <span :if={task.note} class="block break-words text-muted">“{task.note}”</span>
            </li>
          </ul>
        </div>
      </.panel>

      <.panel
        id="evidence-panel"
        title={if @active?, do: "Evidence at head", else: "Last computed evidence"}
        icon="hero-beaker"
      >
        <p :if={!@active? and @loaded.verdict} id="evidence-frozen" class="mb-4 text-sm text-muted">
          From the verdict last computed before the change request was {@change_request.state}. Nothing updates it now.
        </p>
        <.list>
          <:item title="Required workflows">
            <span :if={workflows(@loaded.verdict) == []} class="text-muted">None required</span>
            <span class="inline-flex flex-wrap justify-end gap-2">
              <span
                :for={{name, status} <- workflows(@loaded.verdict)}
                id={"workflow-#{name}"}
                class="inline-flex items-center gap-1"
              >
                <.tag>{name}</.tag>
                <.status_badge kind={workflow_kind(status)}>{status}</.status_badge>
              </span>
            </span>
          </:item>
          <:item
            :for={{source, set} <- scenario_sets(@loaded.verdict)}
            title={"#{source} scenario set"}
          >
            <span id={"scenario-set-#{source}"}>
              Version {set["version"]} ·
              <.tag>{short(set["digest"])}</.tag>
              · {set_status(source, set)}
            </span>
          </:item>
          <:item :if={!@active? and @loaded.verdict} title="Review count">
            <span id="evidence-review-count" class="font-mono">{cleared(@loaded.verdict)}</span>
          </:item>
          <:item title="Counted verify runs">
            <span :if={counted_runs(@loaded.verdict) == []} class="text-muted">None</span>
            <span class="inline-flex flex-wrap justify-end gap-1">
              <.tag :for={run <- counted_runs(@loaded.verdict)}>{run}</.tag>
            </span>
          </:item>
          <:item title="Claims">
            <span :if={@claims == nil} id="claims-summary" class="text-muted">
              No claims at this head
            </span>
            <span :if={@claims} id="claims-summary">
              {door_label(@claims["door"])} · {plural(
                @claims["safe_because"],
                "safe-because claim",
                "safe-because claims"
              )} · {plural(@claims["questions"], "question", "questions")} · {plural(
                @claims["left_open"],
                "open risk",
                "open risks"
              )}
            </span>
          </:item>
        </.list>
      </.panel>

      <.panel id="details-panel" title="Details" icon="hero-document-text">
        <.list>
          <:item title="Head">
            <.tag :if={@change_request.head}>{short(@change_request.head)}</.tag>
            <span :if={!@change_request.head} id="no-head" class="text-muted">No head yet</span>
          </:item>
          <:item title="Source branch">
            <.tag>{@change_request.source_branch}</.tag>
          </:item>
          <:item title="Target branch">
            <span id="target-branch"><.tag>{@change_request.target_branch}</.tag></span>
          </:item>
          <:item title="Opened by">{email(@emails, @change_request.opened_by_account_user_id)}</:item>
          <:item title="OpenSpec change">
            <.tag :if={@change_request.openspec_change}>{@change_request.openspec_change}</.tag>
            <span :if={!@change_request.openspec_change} class="text-muted">None</span>
          </:item>
          <:item title="Parent">
            <.text_link
              :if={@change_request.parent}
              id="parent-link"
              navigate={show_path(@current_account, @project, @change_request.parent.number)}
            >
              #{@change_request.parent.number} {@change_request.parent.title}
            </.text_link>
            <span :if={!@change_request.parent} class="text-muted">None</span>
          </:item>
          <:item title="Opened">
            <span class="font-mono">{format_time(@change_request.inserted_at)}</span>
          </:item>
        </.list>
      </.panel>

      <.panel id="merge-panel" title="Merge" icon="hero-arrow-down-on-square">
        <%= cond do %>
          <% @change_request.state == "merged" -> %>
            <.list>
              <:item title="Merged commit">
                <.tag>{short(@change_request.merged_commit)}</.tag>
              </:item>
              <:item title="Into">
                <.tag>{@change_request.merged_target_branch}</.tag>
              </:item>
              <:item title="Merged at">
                <span class="font-mono">{format_time(@change_request.merged_at)}</span>
              </:item>
              <:item title="Verdict at merge">
                <.verdict_badge state={@change_request.merged_verdict_state} />
              </:item>
              <:item title="Lease">
                <span :if={@change_request.merged_without_lease} id="merged-without-lease">
                  Merged without a lease
                </span>
                <span :if={!@change_request.merged_without_lease}>Merged under a lease</span>
              </:item>
            </.list>
          <% @lease -> %>
            <p id="lease-held" class="text-sm">
              Key
              <.tag>{@lease.api_key && @lease.api_key.name}</.tag>
              holds the merge lease on
              <.tag>{@lease.target_branch}</.tag>
              until <span class="font-mono">{format_time(@lease.expires_at)}</span>.
            </p>
          <% @active? -> %>
            <p id="no-lease" class="text-sm text-muted">No lease held</p>
          <% true -> %>
            <p class="text-sm text-muted">Closed without a merge.</p>
        <% end %>
      </.panel>

      <.panel id="history-panel" title="History" icon="hero-clock">
        <ol class="space-y-2">
          <li id="history-opened" class="text-sm">
            Opened as draft by {email(@emails, @change_request.opened_by_account_user_id)}
            <span class="whitespace-nowrap font-mono text-xs text-muted">
              · {format_time(@change_request.inserted_at)}
            </span>
          </li>
          <li :for={event <- @loaded.history} id={"history-#{event.id}"} class="text-sm">
            <.state_badge state={event.from_state} />
            <span aria-hidden="true">→</span>
            <span class="sr-only">to</span>
            <.state_badge state={event.to_state} /> by {email(@emails, event.account_user_id)}
            <span class="whitespace-nowrap font-mono text-xs text-muted">
              · {format_time(event.inserted_at)}
            </span>
          </li>
        </ol>
      </.panel>
    </div>

    <.editor_dialog
      :if={@dialog}
      id="answer-dialog"
      title={"#{answer_label(@dialog.answer)}: #{kind_label(@dialog.item.kind)}"}
      on_cancel="cancel_answer"
    >
      <.form for={@answer_form} id="answer-form" phx-submit="submit_answer">
        <p class="mb-4 break-words text-sm">
          {if @dialog.item.kind == "question",
            do: @dialog.item.data[:text],
            else: @dialog.item.message}
        </p>
        <.input
          :if={@dialog.answer == "choose"}
          field={@answer_form[:option]}
          type="select"
          label="Option"
          options={@dialog.options}
        />
        <.input
          field={@answer_form[:note]}
          type="textarea"
          label={if note_required?(@dialog.answer), do: "Note", else: "Note (optional)"}
          maxlength="10000"
        />
        <p class="mt-2 font-mono text-xs text-muted">
          Answers head {short(@dialog.head) || "none"}
        </p>
        <.dialog_actions>
          <.button type="button" variant="ghost" phx-click="cancel_answer">Cancel</.button>
          <.button
            id="answer-confirm"
            type="submit"
            variant="primary"
            phx-disable-with="Saving…"
          >
            {answer_label(@dialog.answer)}
          </.button>
        </.dialog_actions>
      </.form>
    </.editor_dialog>
    """
  end

  @impl true
  def handle_event("open_answer", %{"item" => item_id, "answer" => answer}, socket) do
    %{packet: packet, may_approve?: may_approve?, membership: membership} = socket.assigns
    item = packet && Enum.find(packet.items, &(&1.id == item_id))

    if item && answer in item.answers && may_answer?(item, may_approve?, membership) do
      options = (answer == "choose" && (item.data[:options] || [])) || []
      params = %{"note" => "", "option" => List.first(options)}

      {:noreply,
       assign(socket,
         dialog: %{item: item, answer: answer, head: packet.head, options: options},
         answer_form: to_form(params, as: :answer)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_answer", _params, socket),
    do: {:noreply, assign(socket, dialog: nil, answer_form: nil)}

  def handle_event("submit_answer", _params, %{assigns: %{dialog: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("submit_answer", %{"answer" => params}, socket) do
    %{dialog: dialog, current_scope: scope, current_account: account} = socket.assigns

    case Accounts.get_account_user(scope.user, account) do
      nil ->
        {:noreply, socket |> close_dialog() |> put_flash(:error, "You can't answer this item")}

      membership ->
        body = answer_body(dialog, params)

        socket.assigns.change_request
        |> Review.answer(Review.dashboard_actor(membership), dialog.item.id, body)
        |> answered(params, socket)
    end
  end

  defp answer_body(dialog, params) do
    note = params["note"]

    %{"head" => dialog.head, "answer" => dialog.answer}
    |> then(&if(note in [nil, ""], do: &1, else: Map.put(&1, "note", note)))
    |> then(&if(dialog.answer == "choose", do: Map.put(&1, "option", params["option"]), else: &1))
  end

  defp answered({:ok, _answer}, _params, socket) do
    {:noreply, socket |> close_dialog() |> put_flash(:info, "Answer recorded.") |> reload()}
  end

  defp answered({:error, {:invalid_body, errors}}, params, socket) do
    field_errors =
      for {field, messages} <- errors,
          field in ~w(note option),
          message <- messages,
          do: {String.to_existing_atom(field), {field_message(message), []}}

    if field_errors == [] do
      {:noreply,
       socket
       |> close_dialog()
       |> put_flash(:error, "This answer isn't allowed for the item.")
       |> reload()}
    else
      {:noreply,
       assign(socket,
         answer_form: to_form(params, as: :answer, errors: field_errors, action: :validate)
       )}
    end
  end

  defp answered({:error, reason}, _params, socket) do
    {:noreply, socket |> close_dialog() |> put_flash(:error, error_message(reason)) |> reload()}
  end

  defp field_message("is required for " <> answer),
    do: "Write a note. #{answer_label(answer)} needs one so the author knows what to change."

  defp field_message(message), do: message

  defp error_message({:stale_head, _head}),
    do: "A new head was reported. Review the items at the new head."

  defp error_message(:not_found), do: "This item no longer needs an answer at this head."
  defp error_message(:forbidden), do: "You can't answer this item"
  defp error_message(:not_active), do: "This change request is no longer open"
  defp error_message(:stale_digest), do: "The scenario set changed. Review the items again."

  defp close_dialog(socket), do: assign(socket, dialog: nil, answer_form: nil)

  @impl true
  def handle_info({:project_event, _project_id}, %{assigns: %{refresh_scheduled: true}} = socket),
    do: {:noreply, socket}

  def handle_info({:project_event, _project_id}, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, refresh_scheduled: true)}
  end

  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(refresh_scheduled: false) |> reload()}

  defp reload(socket) do
    case ChangeRequests.get(socket.assigns.project, socket.assigns.number) do
      {:ok, change_request} -> load(socket, change_request)
      {:error, :not_found} -> socket
    end
  end

  defp shown_verdict(%{state: "merged"} = cr, _verdict),
    do: %{
      state: cr.merged_verdict_state,
      reasons: cr.merged_reasons || [],
      policy_version: cr.merged_policy_version,
      computed_at: nil
    }

  defp shown_verdict(%{state: "closed"}, _verdict), do: nil
  defp shown_verdict(_cr, nil), do: nil

  defp shown_verdict(_cr, verdict),
    do: %{
      state: verdict.state,
      reasons: verdict.reasons,
      policy_version: verdict.policy_version,
      computed_at: verdict.computed_at
    }

  defp may_answer?(_item, _may_approve?, nil), do: false

  defp may_answer?(%{kind: kind}, may_approve?, _membership) when kind in @approval_kinds,
    do: may_approve?

  defp may_answer?(_item, _may_approve?, _membership), do: true

  defp who_may_answer("other_member"), do: "Another member must approve this set"
  defp who_may_answer("admin"), do: "An owner or admin must approve this set"
  defp who_may_answer(_approver), do: "Only account members can answer this item"

  defp cleared(%{review: %{"items" => items, "cleared" => cleared}}),
    do: "#{cleared} of #{items} cleared"

  defp cleared(_verdict), do: "0 of 0 cleared"

  defp workflows(nil), do: []
  defp workflows(verdict), do: Packet.workflows(verdict)

  defp workflow_kind("passed"), do: "primary"
  defp workflow_kind("failed"), do: "error"
  defp workflow_kind(_status), do: "neutral"

  defp scenario_sets(nil), do: []

  defp scenario_sets(verdict) do
    for source <- ~w(intent diff),
        set = (verdict.scenarios || %{})[source],
        set != nil,
        do: {source, set}
  end

  defp set_status("intent", set),
    do: if(set["approved"], do: "approved", else: "not approved")

  defp set_status("diff", set), do: if(set["accepted"], do: "accepted", else: "not accepted")

  defp counted_runs(nil), do: []
  defp counted_runs(verdict), do: verdict.counted_runs || []

  defp door_label("one_way"), do: "One-way door"
  defp door_label("two_way"), do: "Two-way door"
  defp door_label(other), do: other

  defp plural(list, one, many) do
    case if(is_list(list), do: length(list), else: 0) do
      1 -> "1 #{one}"
      n -> "#{n} #{many}"
    end
  end

  defp kind_label(kind), do: Map.get(@kinds, kind, kind)
  defp answer_label(answer), do: Map.fetch!(@answer_labels, answer)

  defp answer_verb(%{answer: "approve"}), do: "Approved"
  defp answer_verb(%{answer: "reject"}), do: "Rejected"
  defp answer_verb(%{answer: "request_change"}), do: "Change requested"
  defp answer_verb(%{answer: "choose", option: option}), do: "Chose #{option}"

  defp note_required?(answer), do: answer in ~w(reject request_change)

  defp email(emails, account_user_id),
    do: Map.get(emails, account_user_id, "a former member")

  defp item_dom_id(item), do: "item-" <> String.replace(item.id, ":", "-")

  defp short(nil), do: nil
  defp short(sha), do: String.slice(sha, 0, 7)

  defp show_path(account, project, number),
    do: ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/change-requests/#{number}"
end
