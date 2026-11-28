defmodule GoodFlowsWeb.StoredChangeComponents do
  @moduledoc """
  Stored change pieces shared by `GoodFlowsWeb.StoredChangeLive.Index`
  (the Changes list), `GoodFlowsWeb.StoredChangeLive.Show` (a change's
  detail page) and the Changes card of `GoodFlowsWeb.ProjectLive.Show`:

  - `change_status_badge/1`: a change status (`proposed`, `approved`,
    `archived`) in words. `approved` is `primary`, `proposed` is
    `neutral` with a dot and `archived` is `neutral`.
  - `push_empty_state/1`: the empty state of a project with no stored
    changes, explaining `goodflows change push`.
  - `not_given/1`: the muted text of a field the server stored as null.
  """
  use Phoenix.Component
  use GoodFlowsWeb, :verified_routes

  import GoodFlowsWeb.CoreComponents

  @statuses %{"proposed" => "Proposed", "approved" => "Approved", "archived" => "Archived"}

  @doc "Renders a stored change status with `status_badge/1`."
  attr :status, :string, required: true

  def change_status_badge(assigns) do
    assigns = assign(assigns, :label, Map.get(@statuses, assigns.status, assigns.status))

    ~H"""
    <.status_badge
      kind={if @status == "approved", do: "primary", else: "neutral"}
      dot={@status == "proposed"}
    >
      {@label}
    </.status_badge>
    """
  end

  @doc "Renders the empty state of a project with no stored changes."
  attr :id, :string, required: true
  attr :account, :any, required: true

  def push_empty_state(assigns) do
    ~H"""
    <.empty_state id={@id} icon="hero-document-duplicate" title="No changes stored yet">
      Run <code>goodflows change push</code>
      in the repository with an API key: each push of a <code>goodflows/changes/&lt;id&gt;/</code>
      directory is stored here as a new version. The command needs a goodflows release newer than 0.10.0.
      <:actions>
        <.button
          id={"#{@id}-api-keys"}
          variant="outline"
          navigate={~p"/dashboard/accounts/#{@account.id}/api-keys"}
        >
          API keys
        </.button>
      </:actions>
    </.empty_state>
    """
  end

  @doc "Renders the muted text of a field stored as null."
  attr :label, :string, default: "Not given"

  def not_given(assigns) do
    ~H|<span class="text-muted">{@label}</span>|
  end
end
