defmodule GoodFlowsWeb.DashboardLive do
  @moduledoc """
  Account dashboard home page.
  """
  use GoodFlowsWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Dashboard",
       active_nav: :dashboard,
       breadcrumbs: [%{label: "Dashboard"}],
       me_url: url(~p"/api/v1/me")
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="dashboard" class="mx-auto max-w-5xl space-y-4 lg:space-y-6">
      <.header icon="hero-squares-2x2">
        {@current_account.name}
        <:subtitle><code>{@current_account.slug}</code></:subtitle>
        <:actions>
          <.button
            href={~p"/dashboard/accounts/#{@current_account.id}/api-keys"}
            variant="primary"
            size="sm"
            icon="hero-key"
          >
            API keys
          </.button>
        </:actions>
      </.header>

      <div class="grid items-start gap-4 lg:grid-cols-3 lg:gap-6">
        <.panel
          id="get-started"
          title="Make your first API call"
          icon="hero-command-line"
          class="lg:col-span-2"
        >
          <ol class="space-y-5 text-sm">
            <li class="flex items-start gap-3">
              <.tag>1</.tag>
              <div class="min-w-0 flex-1">
                <p class="font-medium">Create an API key</p>
                <p class="mt-1 text-muted">
                  A key authenticates requests as you, within this account.
                  <.text_link href={~p"/dashboard/accounts/#{@current_account.id}/api-keys"}>
                    Go to API keys
                  </.text_link>
                </p>
              </div>
            </li>
            <li class="flex items-start gap-3">
              <.tag>2</.tag>
              <div class="min-w-0 flex-1">
                <p class="font-medium">Check that the key works</p>
                <p class="mt-1 text-muted">
                  This returns the user and account the key belongs to.
                </p>
                <.code_block class="mt-2">
                  <:line>curl -H "Authorization: Bearer $GOODFLOWS_API_KEY" {@me_url}</:line>
                </.code_block>
              </div>
            </li>
            <li class="flex items-start gap-3">
              <.tag>3</.tag>
              <div class="min-w-0 flex-1">
                <p class="font-medium">Browse the endpoints</p>
                <p class="mt-1 text-muted">
                  The API reference lists every endpoint and lets you try requests.
                  <.text_link href={~p"/api/v1/docs"}>Open the API reference</.text_link>
                </p>
              </div>
            </li>
          </ol>
        </.panel>

        <.panel id="account-details" title="Account" icon="hero-building-office">
          <.list>
            <:item title="Name">{@current_account.name}</:item>
            <:item title="Slug"><code>{@current_account.slug}</code></:item>
            <:item title="ID"><code>{@current_account.id}</code></:item>
            <:item title="Signed in as">{@current_scope.user.email}</:item>
          </.list>
        </.panel>
      </div>
    </div>
    """
  end
end
