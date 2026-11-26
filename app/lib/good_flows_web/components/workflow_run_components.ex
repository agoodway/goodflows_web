defmodule GoodFlowsWeb.WorkflowRunComponents do
  @moduledoc """
  Workflow run pieces shared by `GoodFlowsWeb.ProjectLive.Show` (the
  project overview), `GoodFlowsWeb.WorkflowRunLive.Index` (the run list),
  `GoodFlowsWeb.WorkflowRunLive.Show` (the run detail) and the workflow
  runs panel of `GoodFlowsWeb.ChangeRequestLive.Show`:

  - `outcome_badge/1`: a run outcome in words, or `Missing` for no run.
  - `job_status_badge/1`: a result status in words, or `Not run`.
  - `duration/1`: milliseconds as `850ms`, `1.2s` or `3m 4s`.
  - `trigger/1`: what started a run: `ci.event` (or the provider) with
    `#<pull request>` and the attempt, or `local` without `ci`.
  - `ci_url/1`: the run's `ci.url`, or nil.
  - `short_sha/1`: the first 7 characters of a commit.
  - `failed_jobs/1`: up to 3 failed job names, then `+N more`.
  - `run_row/1`: one run of a list, with its filters, failed jobs and the
    runs it called.
  """
  use Phoenix.Component

  import GoodFlowsWeb.CoreComponents
  import GoodFlowsWeb.ChangeRequestComponents, only: [format_time: 1]

  alias Phoenix.LiveView.JS

  @outcomes %{"passed" => "Passed", "failed" => "Failed", "cancelled" => "Cancelled"}

  @statuses %{
    "passed" => "Passed",
    "failed" => "Failed",
    "timed_out" => "Timed out",
    "cancelled" => "Cancelled",
    "skipped" => "Skipped",
    "not_run" => "Not run"
  }

  @shown_failed_jobs 3

  @doc "Renders a run outcome with `status_badge/1`; nil is `Missing`."
  attr :outcome, :string, default: nil

  def outcome_badge(assigns) do
    assigns = assign(assigns, :label, outcome_label(assigns.outcome))

    ~H"""
    <.status_badge kind={outcome_kind(@outcome)}>{@label}</.status_badge>
    """
  end

  defp outcome_label(nil), do: "Missing"
  defp outcome_label(outcome), do: Map.get(@outcomes, outcome, outcome)

  defp outcome_kind("passed"), do: "primary"
  defp outcome_kind("failed"), do: "error"
  defp outcome_kind(_outcome), do: "neutral"

  @doc """
  Renders a result status with `status_badge/1`. `failed` and `timed_out`
  are `error`; `not_run` is a graph job with no result.
  """
  attr :status, :string, required: true

  def job_status_badge(assigns) do
    assigns = assign(assigns, :label, Map.get(@statuses, assigns.status, assigns.status))

    ~H"""
    <.status_badge kind={status_kind(@status)} dot={@status == "not_run"}>{@label}</.status_badge>
    """
  end

  defp status_kind("passed"), do: "primary"
  defp status_kind(status) when status in ~w(failed timed_out), do: "error"
  defp status_kind(_status), do: "neutral"

  @doc "Formats milliseconds as `850ms`, `1.2s` or `3m 4s`."
  @spec duration(non_neg_integer() | nil) :: String.t() | nil
  def duration(nil), do: nil
  def duration(ms) when ms < 1_000, do: "#{ms}ms"
  def duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"

  def duration(ms) do
    seconds = div(ms, 1_000)
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  @doc """
  What started a run: `ci.event` (or `ci.provider`), then `#<number>` for a
  pull request and `· attempt <n>`. A run without `ci` is `local`.
  """
  @spec trigger(map() | nil) :: String.t()
  def trigger(nil), do: "local"

  def trigger(ci) do
    event = ci["event"] || ci["provider"]
    event = if ci["pull_request"], do: "#{event} ##{ci["pull_request"]}", else: event
    if ci["attempt"], do: "#{event} · attempt #{ci["attempt"]}", else: event
  end

  @doc "The run's CI link (`ci.url`), or nil."
  @spec ci_url(map() | nil) :: String.t() | nil
  def ci_url(%{"url" => url}) when is_binary(url), do: url
  def ci_url(_ci), do: nil

  @doc "The first 7 characters of a commit."
  @spec short_sha(String.t() | nil) :: String.t() | nil
  def short_sha(nil), do: nil
  def short_sha(sha), do: String.slice(sha, 0, 7)

  @doc "Renders up to 3 failed job names, then `+N more`."
  attr :id, :string, default: nil
  attr :names, :list, required: true

  def failed_jobs(assigns) do
    {shown, rest} = Enum.split(assigns.names, @shown_failed_jobs)
    assigns = assign(assigns, shown: shown, more: length(rest))

    ~H"""
    <p :if={@names != []} id={@id} class="flex flex-wrap items-center gap-1 text-xs">
      <span class="text-muted">Failed jobs</span>
      <.tag :for={name <- @shown}>{name}</.tag>
      <span :if={@more > 0} class="text-muted">+{@more} more</span>
    </p>
    """
  end

  @doc """
  Renders one run as a list row (`<li>`): outcome, run id linking to `to`,
  workflow, environment, branch, commit with a dirty mark, trigger, CI
  link, start time, duration and failed jobs.

  `filter_to` (a function of the filter name and value returning a URL)
  turns the workflow, branch and commit into links that apply that
  filter; with `patch` they patch the current page. `children` are the
  stored runs this one called: the row shows how many and, when
  `toggle` names an event, a control that pushes it with the run id to
  expand them (`expanded`). `missing_parent` marks a run called by a run
  that was not uploaded.
  """
  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :to, :string, required: true
  attr :filter_to, :any, default: nil
  attr :patch, :boolean, default: false
  attr :children, :list, default: []
  attr :child_to, :any, default: nil, doc: "the function of a child run returning its URL"
  attr :expanded, :boolean, default: false
  attr :toggle, :string, default: nil
  attr :missing_parent, :boolean, default: false
  attr :nested, :boolean, default: false

  def run_row(assigns) do
    ~H"""
    <li id={@id} class={["run-row", @nested && "run-row-nested"]}>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <.outcome_badge outcome={@run.outcome} />
        <.link
          id={"#{@id}-link"}
          navigate={@to}
          class="run-row-id"
          aria-label={"Run #{String.slice(@run.run_id, 0, 8)} of #{@run.workflow}"}
        >
          {String.slice(@run.run_id, 0, 8)}
        </.link>
        <.filter_link
          id={"#{@id}-workflow"}
          filter_to={@filter_to}
          patch={@patch}
          field="workflow"
          value={@run.workflow}
          class="font-mono text-sm font-medium"
        >
          {@run.workflow}
        </.filter_link>
        <.tag :if={@run.environment}>{@run.environment}</.tag>
        <span class="ml-auto flex items-center gap-3 whitespace-nowrap font-mono text-xs text-muted">
          <span id={"#{@id}-started"}>{format_time(@run.started_at)}</span>
          <span id={"#{@id}-duration"}>{duration(@run.duration_ms)}</span>
        </span>
      </div>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted">
        <span :if={@run.source_branch} class="inline-flex min-w-0 items-center gap-1">
          <.icon name="hero-arrow-path-rounded-square-micro" class="size-3.5 shrink-0" />
          <span class="sr-only">Branch</span>
          <.filter_link
            id={"#{@id}-branch"}
            filter_to={@filter_to}
            patch={@patch}
            field="branch"
            value={@run.source_branch}
            class="break-all font-mono"
          >
            {@run.source_branch}
          </.filter_link>
        </span>
        <span :if={@run.source_commit} class="inline-flex items-center gap-1">
          <span class="sr-only">Commit</span>
          <.filter_link
            id={"#{@id}-commit"}
            filter_to={@filter_to}
            patch={@patch}
            field="commit"
            value={@run.source_commit}
            class="font-mono"
          >
            {short_sha(@run.source_commit)}
          </.filter_link>
          <span :if={@run.source_dirty} id={"#{@id}-dirty"} class="run-row-dirty">dirty</span>
        </span>
        <span id={"#{@id}-trigger"}>{trigger(@run.ci)}</span>
        <.text_link :if={ci_url(@run.ci)} id={"#{@id}-ci"} href={ci_url(@run.ci)}>
          CI run
        </.text_link>
        <span
          :if={@missing_parent}
          id={"#{@id}-missing-parent"}
          class="inline-flex items-center gap-1"
        >
          <.icon name="hero-arrow-turn-left-up-micro" class="size-3.5 shrink-0" />
          Called by a run that was not uploaded
        </span>
      </div>
      <.failed_jobs id={"#{@id}-failed-jobs"} names={@run.failed_jobs || []} />
      <div :if={@children != []}>
        <%= if @toggle do %>
          <button
            id={"#{@id}-expand"}
            type="button"
            class="run-row-expand"
            phx-click={JS.push(@toggle, value: %{run_id: @run.run_id})}
            aria-expanded={to_string(@expanded)}
            aria-controls={"#{@id}-children"}
          >
            <.icon
              name={if @expanded, do: "hero-chevron-down-micro", else: "hero-chevron-right-micro"}
              class="size-4"
            />
            {calls_label(length(@children))}
          </button>
        <% else %>
          <span id={"#{@id}-calls"} class="text-xs text-muted">
            {calls_label(length(@children))}
          </span>
        <% end %>
        <ul :if={@expanded} id={"#{@id}-children"} class="run-children">
          <.run_row
            :for={child <- @children}
            id={"#{@id}-child-#{child.run.run_id}"}
            run={child.run}
            to={@child_to.(child.run)}
            filter_to={@filter_to}
            patch={@patch}
            children={child.children}
            child_to={@child_to}
            expanded={true}
            nested
          />
        </ul>
      </div>
    </li>
    """
  end

  defp calls_label(1), do: "Calls 1 run"
  defp calls_label(count), do: "Calls #{count} runs"

  attr :id, :string, required: true
  attr :filter_to, :any, required: true
  attr :patch, :boolean, required: true
  attr :field, :string, required: true
  attr :value, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  defp filter_link(%{filter_to: nil} = assigns) do
    ~H"""
    <span id={@id} class={@class}>{render_slot(@inner_block)}</span>
    """
  end

  defp filter_link(assigns) do
    assigns = assign(assigns, :url, assigns.filter_to.(assigns.field, assigns.value))

    ~H"""
    <.link
      :if={@patch}
      id={@id}
      patch={@url}
      class={["run-filter-link", @class]}
      aria-label={"Filter by #{@field} #{@value}"}
    >
      {render_slot(@inner_block)}
    </.link>
    <.link
      :if={!@patch}
      id={@id}
      navigate={@url}
      class={["run-filter-link", @class]}
      aria-label={"Filter by #{@field} #{@value}"}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end
end
