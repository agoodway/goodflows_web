defmodule GoodFlowsWeb.ChangeRequestComponents do
  @moduledoc """
  Change request pieces shared by `GoodFlowsWeb.ChangeRequestLive.Index`
  (the list) and `GoodFlowsWeb.ChangeRequestLive.Show` (the detail page):

  - `verdict_badge/1`: a verdict state in words on a `status_badge/1`.
    `mergeable` is `primary`, `blocked` is `error`, and `pending` and
    `needs_review` are `neutral` with a dot, told apart by their words.
  - `state_badge/1`: a change request state (`draft`, `open`, `merged`,
    `closed`).
  - `verdict_label/1`: the readable name of a verdict state, for text
    outside a badge.
  - `format_time/1`: a timestamp as `YYYY-MM-DD HH:MM UTC`.
  """
  use Phoenix.Component

  import GoodFlowsWeb.CoreComponents

  @verdicts %{
    "mergeable" => "Mergeable",
    "needs_review" => "Needs review",
    "pending" => "Pending",
    "blocked" => "Blocked"
  }

  @states %{"draft" => "Draft", "open" => "Open", "merged" => "Merged", "closed" => "Closed"}

  @doc "The readable name of a verdict state."
  @spec verdict_label(String.t()) :: String.t()
  def verdict_label(state), do: Map.get(@verdicts, state, state)

  @doc "Renders a verdict state with `status_badge/1`."
  attr :state, :string, required: true

  def verdict_badge(assigns) do
    assigns =
      assign(assigns,
        kind: verdict_kind(assigns.state),
        dot: assigns.state in ~w(pending needs_review),
        label: verdict_label(assigns.state)
      )

    ~H"""
    <.status_badge kind={@kind} dot={@dot}>{@label}</.status_badge>
    """
  end

  defp verdict_kind("mergeable"), do: "primary"
  defp verdict_kind("blocked"), do: "error"
  defp verdict_kind(_state), do: "neutral"

  @doc "Renders a change request state with `status_badge/1`."
  attr :state, :string, required: true

  def state_badge(assigns) do
    assigns = assign(assigns, :label, Map.get(@states, assigns.state, assigns.state))

    ~H"""
    <.status_badge kind={if @state == "open", do: "primary", else: "neutral"}>
      {@label}
    </.status_badge>
    """
  end

  @doc "Formats a timestamp as `YYYY-MM-DD HH:MM UTC`."
  @spec format_time(DateTime.t() | nil) :: String.t() | nil
  def format_time(nil), do: nil
  def format_time(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end
