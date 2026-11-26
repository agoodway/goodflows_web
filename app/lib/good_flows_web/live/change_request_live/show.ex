defmodule GoodFlowsWeb.ChangeRequestLive.Show do
  @moduledoc """
  One change request: its verdict and why, the review packet at the
  current head with open tasks, the evidence at the head, the merge status
  and the state history. Every account member can view it.

  Below the evidence summary, the QA scenarios panel shows each scenario
  set the verdict graded, with each scenario's result from the run grading
  used, the decisions on the set, and the change request's verify runs
  with why each counts or not (`GoodFlows.ChangeRequests.verify_runs/2`).
  The workflow runs panel shows one clean run per workflow at the
  verdict's head, the counted run for a required workflow. A merged or
  closed change request shows them from its stored verdict, marked as
  frozen, with only `Counts` or `Not counted` for verify runs.

  On a `draft` or `open` change request, a member answers review items
  here (`GoodFlows.Review.answer/4` with a `dashboard` actor). The answer
  is bound to the head the page showed. Actions a member may not take,
  under the policy's `scenarios.approver`, are hidden, and the domain
  refuses them anyway. On the QA panel, a member the approver rule allows
  approves or rejects the intent set version shown from a popover, bound
  to its digest
  (`GoodFlows.ScenarioSets.decide/5` with no key, channel `dashboard`).

  Each scenario row has a toggle that opens a details row: the scenario's
  section of the set file (`GoodFlows.ScenarioSets.Sections`), rendered
  with `GoodFlowsWeb.ScenarioMarkdown` only when its digest matches, and
  from the run the row's result came from, the failed step, reason and
  evidence, each linking to `GoodFlowsWeb.VerifyRunArtifactController`
  unless expired. Open rows are kept in `open_scenarios`.

  The page reloads 500 ms after a project event, keeping an open answer
  dialog and the open scenario rows.
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
  alias GoodFlows.ScenarioSets.Sections
  alias GoodFlows.VerifyRuns
  alias GoodFlows.WorkflowRuns
  alias GoodFlowsWeb.ScenarioMarkdown

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

  @run_marks %{
    counts: "Counts",
    not_counted: "Not counted",
    uploading: "Still uploading",
    dirty: "Dirty tree",
    merge_result: "Merge-result run",
    older_version: "Older set version",
    intent_not_approved: "Intent set not approved",
    diff_not_at_head: "Diff set does not name the head",
    no_git_facts: "No Git facts at the head",
    commit_not_counted: "Commit does not count at the head"
  }

  # Reasons whose subject is one value: its label and whether it is a SHA.
  @subject_labels %{
    "git_facts_missing" => {"Head", :sha},
    "claims_missing" => {"Head", :sha},
    "diff_set_revision" => {"Names commit", :sha},
    "merge_result_ungraded" => {"Lease base", :sha},
    "required_workflow_failed" => {"Workflow", :text},
    "required_workflow_missing" => {"Workflow", :text},
    "dependency_not_merged" => {"Change", :text},
    "unmapped_area" => {"File", :text},
    "undriven_feature" => {"Feature", :text}
  }

  @results %{"passed" => "Passed", "failed" => "Failed", "not_run" => "Not run"}

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
         answer_form: nil,
         set_form: set_form(),
         open_scenarios: MapSet.new()
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
      emails: Accounts.member_emails(account),
      evidence: evidence(socket.assigns.project, change_request, loaded.verdict, active?)
    )
  end

  defp evidence(_project, _change_request, nil, _active?), do: nil

  defp evidence(project, change_request, verdict, active?) do
    frozen_at = if active?, do: nil, else: verdict.computed_at

    runs =
      change_request
      |> ChangeRequests.verify_runs(frozen_at)
      |> Enum.map(&Map.put(&1, :mark, run_mark(&1, verdict, active?)))

    sets = scenario_sets(verdict)

    run_ids =
      for {_source, set} <- sets,
          row <- set["scenarios"] || [],
          row["run_id"],
          uniq: true,
          do: row["run_id"]

    details = VerifyRuns.scenario_details(project, run_ids)

    %{
      sets:
        for({source, set} <- sets, do: set_evidence(change_request, source, set, runs, details)),
      runs: runs,
      workflows: workflow_rows(project, verdict, frozen_at)
    }
  end

  defp run_mark(%{explanation: explanation}, _verdict, true), do: explanation

  defp run_mark(run, verdict, false),
    do: if(run.run_id in counted_runs(verdict), do: :counts, else: :not_counted)

  defp set_evidence(change_request, source, set, runs, details) do
    version =
      case ScenarioSets.get_version(change_request, source, set["version"]) do
        {:ok, version} -> Repo.preload(version, :api_key)
        {:error, :not_found} -> nil
      end

    rows = set["scenarios"] || []
    run_id = Enum.find_value(rows, & &1["run_id"])

    %{
      source: source,
      set: set,
      version: version,
      rows: rows,
      names: names(version),
      sections: sections(version),
      details: details,
      decisions: ScenarioSets.decisions(change_request, set["digest"]),
      run_id: run_id,
      run: run_id && Enum.find(runs, &(&1.run_id == run_id))
    }
  end

  defp names(nil), do: %{}

  defp names(version),
    do: Map.new(version.front_matter["scenarios"] || [], &{&1["id"], &1["name"]})

  defp sections(nil), do: %{}
  defp sections(version), do: Sections.split(version.content, version.sections || [])

  defp workflow_rows(_project, %{head: nil}, _frozen_at), do: []

  defp workflow_rows(project, verdict, frozen_at) do
    required = (verdict.inputs || %{})["required_workflows"] || %{}
    latest = WorkflowRuns.latest_clean_by_workflow(project, verdict.head, frozen_at)
    required_rows(project, required, latest) ++ other_rows(required, latest)
  end

  defp required_rows(project, required, latest) do
    counted_ids = required |> Map.values() |> Enum.reject(&is_nil/1)
    not_latest_ids = counted_ids -- Enum.map(latest, & &1.run_id)

    by_id =
      Map.new(latest ++ WorkflowRuns.summaries(project, not_latest_ids), &{&1.run_id, &1})

    for {name, run_id} <- Enum.sort(required),
        do: %{workflow: name, required: true, run: run_id && by_id[run_id]}
  end

  defp other_rows(required, latest) do
    for run <- latest,
        not Map.has_key?(required, run.workflow),
        do: %{workflow: run.workflow, required: false, run: run}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown: shown_verdict(assigns.change_request, assigns.loaded.verdict),
        subject_context: subject_context(assigns)
      )

    ~H"""
    <div class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-arrows-right-left">
        <span class="font-mono text-muted">#{@change_request.number}</span>
        <span id="change-request-title" class="break-words">{@change_request.title}</span>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <.state_badge state={@change_request.state} />
            <span :if={@shown && @active?} id="header-verdict">
              <.verdict_badge state={@shown.state} />
            </span>
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

      <.panel
        id="verdict-panel"
        title={if @change_request.state == "merged", do: "Verdict at merge", else: "Verdict reasons"}
        icon="hero-scale"
      >
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
              {if @change_request.state == "merged",
                do: "Nothing blocked the merge",
                else: "Nothing blocks merging"}{if @shown.head, do: " at commit #{short(@shown.head)}"}.
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
                <ul
                  :if={subject_lines(reason, @subject_context) != []}
                  id={"reason-#{index}-subject"}
                  class="space-y-1 text-sm"
                >
                  <li :for={line <- subject_lines(reason, @subject_context)} class="break-words">
                    <.link
                      :if={line.href}
                      href={line.href}
                      class="underline decoration-base-300 underline-offset-2 hover:decoration-current"
                    >
                      {line.text}
                    </.link>
                    <span :if={!line.href && line.text}>{line.text}</span>
                    <.tag :for={tag <- line.tags}>{tag}</.tag>
                  </li>
                </ul>
                <p class="text-xs text-muted">
                  Rule
                  <.tag>{reason["rule"]}</.tag>
                </p>
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
            <p
              :if={item.kind == "open_item"}
              id={"#{item_dom_id(item)}-risk"}
              class="break-words text-sm font-medium"
            >
              {item.data[:risk]}
              <span :if={item.data[:location]} class="block font-mono text-xs text-muted">
                {item.data[:location]}
              </span>
            </p>
            <p
              :if={item.kind in ~w(failed_scenario not_run) and item.data[:reason]}
              id={"#{item_dom_id(item)}-result"}
              class="break-words text-sm font-medium"
            >
              {item.data[:reason]}
              <span :if={item.data[:failed_step]} class="block font-mono text-xs text-muted">
                Failed at {item.data[:failed_step]}
              </span>
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

      <.panel :if={@evidence} id="qa-panel" title="QA scenarios" icon="hero-clipboard-document-check">
        <p :if={!@active?} id="qa-frozen" class="mb-4 text-sm text-muted">
          From the verdict last computed before the change request was {@change_request.state}. Nothing updates it now.
        </p>
        <p :if={@evidence.sets == []} id="no-sets" class="text-sm text-muted">
          No scenario set has been uploaded.
        </p>
        <div class="space-y-8">
          <.qa_set
            :for={set <- @evidence.sets}
            set={set}
            emails={@emails}
            decide={if @active? and set.source == "intent", do: decide_state(@may_approve?, set)}
            who={who_may_answer(@approver)}
            form={@set_form}
            open={@open_scenarios}
            artifact_path={&artifact_path(@current_account, @project, &1, &2)}
          />
        </div>
        <div id="verify-runs-section" class="mt-8 space-y-3">
          <h3 class="font-mono text-xs font-semibold uppercase tracking-wide text-muted">
            Verify runs
          </h3>
          <.table
            id="verify-runs"
            rows={@evidence.runs}
            row_id={&"verify-run-#{&1.run_id}"}
            empty={@evidence.runs == []}
          >
            <:col :let={run} label="Run">
              <.tag>{short(run.run_id)}</.tag>
            </:col>
            <:col :let={run} label="Set">
              <span class="whitespace-nowrap">{set_version_label(run)}</span>
            </:col>
            <:col :let={run} label="Commit">
              <.tag>{short(run.commit)}</.tag>
            </:col>
            <:col :let={run} label="Finished">
              <span class="whitespace-nowrap font-mono text-xs">{format_time(run.finished_at)}</span>
            </:col>
            <:col :let={run} label="Results">
              <span class="whitespace-nowrap font-mono text-xs">{result_counts(run.counts)}</span>
            </:col>
            <:col :let={run} label="Grading">
              <span data-mark={run.mark}>
                <.status_badge kind={if run.mark == :counts, do: "primary", else: "neutral"}>
                  {run_mark_label(run.mark)}
                </.status_badge>
              </span>
            </:col>
            <:empty_state>
              <p id="no-verify-runs" class="p-4 text-sm text-muted">
                No verify run grades a set of this change request.
              </p>
            </:empty_state>
          </.table>
        </div>
      </.panel>

      <.panel
        :if={@evidence}
        id="workflow-runs-panel"
        title="Workflow runs at head"
        icon="hero-play-circle"
      >
        <:actions>
          <span
            :if={@loaded.verdict.head}
            id="workflow-runs-summary"
            class="block text-right font-normal normal-case tracking-normal text-muted"
          >
            {required_passed(@evidence.workflows)} · newest clean run of each workflow on {short(
              @loaded.verdict.head
            )}
          </span>
        </:actions>
        <p :if={!@active?} id="workflow-runs-frozen" class="mb-4 text-sm text-muted">
          The runs the last computed verdict saw on its head. Nothing updates them now.
        </p>
        <.table
          id="workflow-runs"
          rows={@evidence.workflows}
          row_id={&"workflow-run-#{&1.workflow}"}
          empty={@evidence.workflows == []}
          span_from={&if(&1.run, do: nil, else: 2)}
        >
          <:col :let={row} label="Workflow">
            <span class="flex flex-col items-end gap-0.5 md:items-start">
              <.tag>{row.workflow}</.tag>
              <span class="text-xs text-muted">
                {if row.required, do: "Required", else: "Not required"}
              </span>
            </span>
          </:col>
          <:col :let={row} label="Outcome">
            <.status_badge kind={outcome_kind(row.run)}>{outcome_label(row.run)}</.status_badge>
          </:col>
          <:col :let={row} label="Started">
            <span :if={row.run} class="whitespace-nowrap font-mono text-xs">
              {format_time(row.run.started_at)}
            </span>
          </:col>
          <:col :let={row} label="Duration">
            <span :if={row.run} class="whitespace-nowrap font-mono text-xs">
              {format_duration(row.run.duration_ms)}
            </span>
          </:col>
          <:col :let={row} label="Trigger">
            <span :if={row.run} class="flex flex-col items-end gap-0.5 md:items-start">
              <span class="text-xs">{trigger(row.run.ci)}</span>
              <.text_link
                :if={ci_url(row.run.ci)}
                id={"workflow-run-#{row.workflow}-ci"}
                href={ci_url(row.run.ci)}
              >
                <span class="text-xs">CI run</span>
              </.text_link>
              <span :if={row.run.ci && !ci_url(row.run.ci)} class="text-xs text-muted">
                No CI link
              </span>
            </span>
          </:col>
          <:span :let={row}>
            <span id={"workflow-run-#{row.workflow}-missing"} class="text-xs text-muted">
              No clean run of this workflow on the head
            </span>
          </:span>
          <:empty_state>
            <p id="no-workflow-runs" class="p-4 text-sm text-muted">
              {if @loaded.verdict.head,
                do: "No clean workflow run on this head.",
                else: "No head yet."}
            </p>
          </:empty_state>
        </.table>
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
          <:item title="Change">
            <.tag :if={@change_request.change_id}>{@change_request.change_id}</.tag>
            <span :if={!@change_request.change_id} class="text-muted">None</span>
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
  def handle_event("decide_set", %{"digest" => digest, "answer" => answer} = params, socket)
      when answer in ~w(approve reject) do
    %{evidence: evidence, current_scope: scope, current_account: account} = socket.assigns
    set = evidence && Enum.find(evidence.sets, &(&1.source == "intent"))
    note = get_in(params, ["set_decision", "note"]) || ""

    with true <- set != nil and decide_state(socket.assigns.may_approve?, set) == :may,
         membership when membership != nil <- Accounts.get_account_user(scope.user, account) do
      body =
        if answer == "reject",
          do: %{"digest" => digest, "note" => note},
          else: %{"digest" => digest}

      socket.assigns.change_request
      |> ScenarioSets.decide(membership, nil, String.to_existing_atom(answer), body)
      |> set_decided(answer, note, socket)
    else
      _refused -> {:noreply, socket}
    end
  end

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

  def handle_event("toggle_scenario", %{"source" => source, "id" => id}, socket) do
    key = {source, id}
    open = socket.assigns.open_scenarios

    open =
      cond do
        MapSet.member?(open, key) -> MapSet.delete(open, key)
        scenario_row?(socket.assigns.evidence, source, id) -> MapSet.put(open, key)
        true -> open
      end

    {:noreply, assign(socket, open_scenarios: open)}
  end

  def handle_event("cancel_answer", _params, socket),
    do: {:noreply, close_dialog(socket)}

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

  defp set_decided({:ok, _status, _decision}, answer, _note, socket) do
    message = if answer == "approve", do: "Intent set approved.", else: "Intent set rejected."

    {:noreply,
     socket
     |> assign(set_form: set_form())
     |> hide_set_popover()
     |> put_flash(:info, message)
     |> reload()}
  end

  defp set_decided({:error, {:invalid_body, _errors}}, _answer, note, socket) do
    error = {:note, {"Write a note so the author knows what to change.", []}}

    {:noreply,
     assign(socket,
       set_form: to_form(%{"note" => note}, as: :set_decision, errors: [error], action: :validate)
     )}
  end

  defp set_decided({:error, reason}, _answer, _note, socket) do
    {:noreply,
     socket |> hide_set_popover() |> put_flash(:error, error_message(reason)) |> reload()}
  end

  defp set_form, do: to_form(%{"note" => ""}, as: :set_decision)

  defp hide_set_popover(socket),
    do: push_event(socket, "gf:popover", %{id: "qa-set-intent-decide", action: "hide"})

  defp decide_state(may_approve?, %{set: data}) do
    cond do
      data["approved"] -> nil
      may_approve? -> :may
      true -> :may_not
    end
  end

  defp scenario_counts(rows) do
    rows
    |> Enum.frequencies_by(& &1["priority"])
    |> Enum.sort_by(fn {priority, _n} -> priority != "must" end)
    |> Enum.map_join(", ", fn {priority, n} ->
      "#{n} #{priority} scenario#{if n != 1, do: "s"}"
    end)
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

  defp scenario_row?(nil, _source, _id), do: false

  defp scenario_row?(evidence, source, id),
    do:
      Enum.any?(
        evidence.sets,
        &(&1.source == source and Enum.any?(&1.rows, fn r -> r["id"] == id end))
      )

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
      head: cr.merged_head,
      reasons: cr.merged_reasons || [],
      policy_version: cr.merged_policy_version,
      computed_at: nil
    }

  defp shown_verdict(%{state: "closed"}, _verdict), do: nil
  defp shown_verdict(_cr, nil), do: nil

  defp shown_verdict(_cr, verdict),
    do: %{
      state: verdict.state,
      head: verdict.head,
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

  attr :set, :map, required: true
  attr :emails, :map, required: true
  attr :decide, :atom, default: nil, doc: "`:may`, `:may_not` or nil (no control)"
  attr :who, :string, default: nil
  attr :form, :any, default: nil
  attr :open, MapSet, required: true
  attr :artifact_path, :any, required: true, doc: "the function of run ID and artifact ID"

  defp qa_set(assigns) do
    assigns =
      assign(assigns,
        source: assigns.set.source,
        data: assigns.set.set,
        version: assigns.set.version
      )

    ~H"""
    <section id={"qa-set-#{@source}"} class="space-y-4">
      <div class="flex flex-wrap items-center gap-2">
        <h3 class="text-sm font-semibold">{set_title(@source)}</h3>
        <span id={"qa-set-#{@source}-status"}>
          <.status_badge kind={if set_ok?(@source, @data), do: "primary", else: "neutral"}>
            {set_status_label(@source, @data)}
          </.status_badge>
        </span>
        <span :if={!@data["graded"]} id={"qa-set-#{@source}-not-graded"}>
          <.status_badge dot>Not graded</.status_badge>
        </span>
        <.popover :if={@decide == :may} id={"qa-set-#{@source}-decide"} align="start" class="w-80">
          <:trigger
            size="sm"
            variant="soft"
            icon="hero-check-badge"
            class="h-6 min-h-0 px-2 py-0 text-xs"
          >
            Decide on v{@data["version"]}
          </:trigger>
          <:title>Intent set v{@data["version"]}</:title>
          <:description>
            {scenario_counts(@set.rows)} · digest {short(@data["digest"])}
          </:description>
          <.form
            for={@form}
            id={"qa-set-#{@source}-decision-form"}
            phx-submit="decide_set"
            class="space-y-3"
          >
            <input type="hidden" name="digest" value={@data["digest"]} />
            <.input
              field={@form[:note]}
              type="textarea"
              label="Note (needed to reject)"
              maxlength="10000"
            />
            <div class="flex justify-end gap-2">
              <.button
                id={"qa-set-#{@source}-reject"}
                type="submit"
                name="answer"
                value="reject"
                variant="ghost"
                size="sm"
              >
                Reject
              </.button>
              <.button
                id={"qa-set-#{@source}-approve"}
                type="submit"
                name="answer"
                value="approve"
                variant="primary"
                size="sm"
                phx-disable-with="Saving…"
              >
                Approve v{@data["version"]}
              </.button>
            </div>
          </.form>
        </.popover>
        <span :if={@decide == :may_not} id={"qa-set-#{@source}-who"} class="text-xs text-muted">
          {@who}
        </span>
        <span id={"qa-set-#{@source}-tallies"} class="ml-auto flex flex-wrap items-center gap-2">
          <.status_badge :for={{priority, passed, total, kind} <- tallies(@set.rows)} kind={kind}>
            {String.capitalize(priority)} {passed}/{total}
          </.status_badge>
        </span>
      </div>

      <dl class="grid grid-cols-1 gap-4 border-y border-base-300 py-3 sm:grid-cols-2 lg:grid-cols-4">
        <.fact label="Version" id={"qa-set-#{@source}-version"}>
          <span class="inline-flex flex-wrap items-center gap-1">
            <.tag>v{@data["version"]}</.tag>
            <.tag>{short(@data["digest"])}</.tag>
          </span>
        </.fact>
        <.fact :if={@source == "diff"} label="Revision" id="qa-set-diff-revision">
          <.tag :if={@version && @version.front_matter["revision"]}>
            {short(@version.front_matter["revision"])}
          </.tag>
          <:sub>
            {if @data["graded"], do: "Names the head", else: "Does not name the head"}
            <span :if={@data["baseline_version"]}>· baseline v{@data["baseline_version"]}</span>
          </:sub>
        </.fact>
        <.fact label="Uploaded" id={"qa-set-#{@source}-uploaded"}>
          <span :if={@version} class="font-mono">{format_time(@version.inserted_at)}</span>
          <:sub :if={@version}>
            {email(@emails, @version.account_user_id)}
            <span :if={@version.api_key}>· Key {@version.api_key.name}</span>
          </:sub>
        </.fact>
        <.fact label="Results from" id={"qa-set-#{@source}-run"}>
          <span :if={!@set.run_id} class="text-muted">No counted run</span>
          <span :if={@set.run_id} class="inline-flex flex-wrap items-center gap-1">
            <.tag>{short(@set.run_id)}</.tag>
            <span :if={@set.run}>on</span>
            <.tag :if={@set.run}>{short(@set.run.commit)}</.tag>
          </span>
          <:sub :if={@set.run}>
            Finished <span class="font-mono">{format_time(@set.run.finished_at)}</span>
          </:sub>
        </.fact>
      </dl>

      <div :if={!@data["graded"]} id={"qa-set-#{@source}-not-graded-note"}>
        <.notice kind="info">{not_graded_note(@source)}</.notice>
      </div>

      <.table
        id={"qa-set-#{@source}-scenarios"}
        rows={@set.rows}
        row_id={&"scenario-#{@source}-#{&1["id"]}"}
        row_open={&MapSet.member?(@open, {@source, &1["id"]})}
      >
        <:col :let={row} label="ID">
          <span class="inline-flex items-center gap-1">
            <.button
              id={"scenario-#{@source}-#{row["id"]}-toggle"}
              type="button"
              variant="ghost"
              size="sm"
              icon={
                if MapSet.member?(@open, {@source, row["id"]}),
                  do: "hero-chevron-down",
                  else: "hero-chevron-right"
              }
              phx-click="toggle_scenario"
              phx-value-source={@source}
              phx-value-id={row["id"]}
              aria-expanded={to_string(MapSet.member?(@open, {@source, row["id"]}))}
              aria-controls={
                MapSet.member?(@open, {@source, row["id"]}) &&
                  "scenario-#{@source}-#{row["id"]}-details"
              }
            >
              <span class="sr-only">
                {if MapSet.member?(@open, {@source, row["id"]}), do: "Hide", else: "Show"} details for {row[
                  "id"
                ]}
              </span>
            </.button>
            <.tag>{row["id"]}</.tag>
          </span>
        </:col>
        <:col :let={row} label="Scenario">
          <span class="break-words">{@set.names[row["id"]]}</span>
        </:col>
        <:col :let={row} label="Priority">{String.capitalize(row["priority"] || "")}</:col>
        <:col :let={row} label="Result">
          <.status_badge kind={result_kind(row["result"])}>
            {result_label(row["result"])}
          </.status_badge>
        </:col>
        <:details :let={row}>
          <.scenario_details
            dom_id={"scenario-#{@source}-#{row["id"]}"}
            section={@set.sections[row["id"]]}
            run_id={row["run_id"]}
            detail={row["run_id"] && get_in(@set.details, [row["run_id"], row["id"]])}
            artifact_path={@artifact_path}
          />
        </:details>
      </.table>

      <div id={"qa-set-#{@source}-decisions"} class="space-y-2">
        <h4 class="font-mono text-xs font-semibold uppercase tracking-wide text-muted">
          Decisions on v{@data["version"]}
        </h4>
        <p :if={@set.decisions == []} class="text-sm text-muted">No decisions on this version.</p>
        <ul :if={@set.decisions != []} class="space-y-2">
          <li :for={decision <- @set.decisions} id={"decision-#{decision.id}"} class="text-sm">
            {decision_verb(@source, decision.decision)} by {email(@emails, decision.account_user_id)}
            <span class="whitespace-nowrap font-mono text-xs text-muted">
              · {decision.channel} · {format_time(decision.inserted_at)}
            </span>
            <span :if={decision.note} class="block break-words text-muted">“{decision.note}”</span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :dom_id, :string, required: true
  attr :section, :any, required: true, doc: "`{:ok, text}`, `:unmatched` or nil"
  attr :run_id, :string, default: nil
  attr :detail, :map, default: nil
  attr :artifact_path, :any, required: true

  defp scenario_details(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= case @section do %>
        <% {:ok, text} -> %>
          <div id={"#{@dom_id}-text"} class="scenario-markdown">
            {ScenarioMarkdown.to_html(text)}
          </div>
        <% _unmatched -> %>
          <p id={"#{@dom_id}-unmatched"} class="text-sm text-muted">
            The text of this scenario could not be matched to the set file.
          </p>
      <% end %>

      <div id={"#{@dom_id}-result"} class="space-y-2 border-t border-base-300 pt-3">
        <h4 class="font-mono text-xs font-semibold uppercase tracking-wide text-muted">
          Run result
        </h4>
        <p :if={!@detail} id={"#{@dom_id}-no-result"} class="text-sm text-muted">
          No verify run result for this scenario.
        </p>
        <div :if={@detail} class="space-y-2">
          <p :if={@detail.failed_step} id={"#{@dom_id}-failed-step"} class="font-mono text-xs">
            Failed at {@detail.failed_step}
          </p>
          <p :if={@detail.reason} id={"#{@dom_id}-reason"} class="break-words text-sm">
            {@detail.reason}
          </p>
          <p
            :if={!@detail.failed_step and !@detail.reason and @detail.evidence == []}
            class="text-sm text-muted"
          >
            No failed step, reason or evidence recorded.
          </p>
          <ul :if={@detail.evidence != []} id={"#{@dom_id}-evidence"} class="space-y-1">
            <li
              :for={artifact <- @detail.evidence}
              id={"#{@dom_id}-evidence-#{artifact.id}"}
              class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs"
            >
              <span class="min-w-0 break-all font-mono">{artifact.path || artifact.id}</span>
              <span class="text-muted">{artifact.content_type}</span>
              <span class="whitespace-nowrap font-mono text-muted">{format_size(artifact.size)}</span>
              <%= if artifact.expired do %>
                <.status_badge>Expired</.status_badge>
              <% else %>
                <.text_link
                  id={"#{@dom_id}-evidence-#{artifact.id}-download"}
                  href={@artifact_path.(@run_id, artifact.id)}
                  aria-label={"Download #{artifact.path || artifact.id}"}
                >
                  Download
                </.text_link>
              <% end %>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp format_size(nil), do: nil
  defp format_size(bytes) when bytes < 1_024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KiB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  defp artifact_path(account, project, run_id, artifact_id),
    do:
      ~p"/dashboard/accounts/#{account.id}/projects/#{project.slug}/verify-runs/#{run_id}/artifacts/#{artifact_id}"

  attr :label, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true
  slot :sub

  defp fact(assigns) do
    ~H"""
    <div class="min-w-0" {@rest}>
      <dt class="font-mono text-[0.6875rem] font-semibold uppercase tracking-wider text-muted">
        {@label}
      </dt>
      <dd class="mt-1 break-words text-xs">{render_slot(@inner_block)}</dd>
      <dd :for={sub <- @sub} class="mt-1 break-words text-xs text-muted">{render_slot(sub)}</dd>
    </div>
    """
  end

  defp set_title("intent"), do: "Intent set"
  defp set_title("diff"), do: "Diff set"

  defp set_ok?("intent", set), do: set["approved"] == true
  defp set_ok?("diff", set), do: set["accepted"] == true

  defp set_status_label("intent", set),
    do: if(set["approved"], do: "Approved", else: "Not approved")

  defp set_status_label("diff", set),
    do: if(set["accepted"], do: "Accepted", else: "Not accepted")

  defp not_graded_note("intent"),
    do:
      "Not graded. No verify run counts until the current version of the intent set is approved."

  defp not_graded_note("diff"),
    do:
      "Not graded. The set's revision does not name the head, so no verify run counts until a diff set for the head is uploaded."

  defp tallies(rows) do
    for priority <- ~w(must should could),
        of_priority = Enum.filter(rows, &(&1["priority"] == priority)),
        of_priority != [] do
      passed = Enum.count(of_priority, &(&1["result"] == "passed"))
      total = length(of_priority)
      {priority, passed, total, tally_kind(of_priority, passed, total)}
    end
  end

  defp tally_kind(rows, passed, total) do
    cond do
      Enum.any?(rows, &(&1["result"] == "failed")) -> "error"
      passed == total -> "primary"
      true -> "neutral"
    end
  end

  defp result_label(result), do: Map.get(@results, result, "No result")

  defp result_kind("passed"), do: "primary"
  defp result_kind("failed"), do: "error"
  defp result_kind(_result), do: "neutral"

  defp decision_verb(_source, "reject"), do: "Rejected"
  defp decision_verb("diff", "approve"), do: "Accepted"
  defp decision_verb(_source, "approve"), do: "Approved"

  defp run_mark_label(mark), do: Map.fetch!(@run_marks, mark)

  defp set_version_label(%{source: source, version: nil}), do: String.capitalize(source)
  defp set_version_label(%{source: source, version: v}), do: "#{String.capitalize(source)} v#{v}"

  defp result_counts(counts),
    do: "#{counts["passed"]} passed · #{counts["failed"]} failed · #{counts["not_run"]} not run"

  defp required_passed(rows) do
    required = Enum.filter(rows, & &1.required)
    passed = Enum.count(required, &match?(%{run: %{outcome: "passed"}}, &1))
    "#{passed} of #{length(required)} required passed"
  end

  defp outcome_label(nil), do: "Missing"
  defp outcome_label(run), do: run.outcome |> String.replace("_", " ") |> String.capitalize()

  defp outcome_kind(%{outcome: "passed"}), do: "primary"
  defp outcome_kind(%{outcome: "failed"}), do: "error"
  defp outcome_kind(_run), do: "neutral"

  defp format_duration(nil), do: nil
  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  defp format_duration(ms) do
    seconds = div(ms, 1_000)
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp trigger(nil), do: "Local run"

  defp trigger(ci) do
    event = ci["event"] || ci["provider"]
    if ci["attempt"], do: "#{event} · attempt #{ci["attempt"]}", else: event
  end

  defp ci_url(%{"url" => url}) when is_binary(url), do: url
  defp ci_url(_ci), do: nil

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

  defp subject_context(assigns) do
    %{
      names: Map.new((assigns.evidence && assigns.evidence.sets) || [], &{&1.source, &1.names}),
      question_ids: for(q <- (assigns.claims || %{})["questions"] || [], do: q["id"]),
      review?: assigns.packet != nil,
      parent_path: &show_path(assigns.current_account, assigns.project, &1)
    }
  end

  # What a reason's subject points at, in plain words: one line per thing,
  # each with optional text, a link and code tags.
  defp subject_lines(%{"subject" => subject}, _context) when subject in [nil, []], do: []

  defp subject_lines(%{"subject" => subject}, _context) when is_binary(subject),
    do: [line(nil, [subject])]

  defp subject_lines(%{"rule" => rule, "subject" => [source, id]}, context)
       when rule in ~w(must_failed should_failed should_not_run merge_result_failed diff_set_weakened) do
    name = context.names[source][id]
    text = "#{set_title(source)} · scenario #{id}" <> if(name, do: ": #{name}", else: "")
    [line(text, [], name && "#scenario-#{source}-#{id}")]
  end

  defp subject_lines(%{"rule" => "open_items", "subject" => subject}, context) do
    questions = Enum.count(subject, &(&1 in context.question_ids))

    text =
      [
        questions > 0 && plural_count(questions, "question", "questions"),
        length(subject) > questions &&
          plural_count(length(subject) - questions, "open risk", "open risks")
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    [line(text, [], context.review? && "#review-panel")]
  end

  defp subject_lines(%{"rule" => "spec_gap", "subject" => parts}, _context),
    do: [line(Enum.join(parts, " › "))]

  defp subject_lines(%{"rule" => "path_match", "subject" => [glob | paths]}, _context),
    do: [line("Pattern", [glob]) | Enum.map(paths, &line(nil, [&1]))]

  defp subject_lines(%{"rule" => "proof_below_minimum", "subject" => facts}, _context),
    do: Enum.map(facts, &line/1)

  defp subject_lines(%{"rule" => "scenario_results_missing", "subject" => [source]}, context),
    do: [line(set_title(source), [], context.names[source] && "#qa-set-#{source}")]

  defp subject_lines(%{"rule" => "scenario_set_approval", "subject" => [digest]}, context),
    do: [line("Intent set, digest", [short(digest)], context.names["intent"] && "#qa-set-intent")]

  defp subject_lines(%{"rule" => rule, "subject" => [number]}, context)
       when rule in ~w(parent_not_merged parent_closed),
       do: [line("Parent change request ##{number}", [], context.parent_path.(number))]

  defp subject_lines(%{"rule" => rule, "subject" => [value]}, _context)
       when is_map_key(@subject_labels, rule) do
    {label, kind} = @subject_labels[rule]
    [line(label, [if(kind == :sha, do: short(value), else: value)])]
  end

  defp subject_lines(%{"subject" => subject}, _context), do: [line(nil, subject)]

  defp line(text, tags \\ [], href \\ nil), do: %{text: text, tags: tags, href: href || nil}

  defp plural_count(1, one, _many), do: "1 #{one}"
  defp plural_count(n, _one, many), do: "#{n} #{many}"
end
