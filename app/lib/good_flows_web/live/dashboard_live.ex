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
      <.page_header icon="hero-squares-2x2">
        <:title>{@current_account.name}</:title>
        <:subtitle>{@current_account.slug}</:subtitle>
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
      </.page_header>

      <div class="grid items-start gap-4 lg:grid-cols-3 lg:gap-6">
        <.section_card id="get-started" icon="hero-command-line" class="lg:col-span-2">
          <:title>Make your first API call</:title>
          <ol class="space-y-5 text-sm">
            <li class="flex gap-3">
              <span class="tag-badge h-fit">1</span>
              <div class="min-w-0 flex-1">
                <p class="font-medium">Create an API key</p>
                <p class="mt-1 text-muted">
                  A key authenticates requests as you, within this account.
                  <.link
                    href={~p"/dashboard/accounts/#{@current_account.id}/api-keys"}
                    class="text-primary underline-offset-2 hover:underline"
                  >
                    Go to API keys
                  </.link>
                </p>
              </div>
            </li>
            <li class="flex gap-3">
              <span class="tag-badge h-fit">2</span>
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
            <li class="flex gap-3">
              <span class="tag-badge h-fit">3</span>
              <div class="min-w-0 flex-1">
                <p class="font-medium">Browse the endpoints</p>
                <p class="mt-1 text-muted">
                  The API reference lists every endpoint and lets you try requests.
                  <.link
                    href={~p"/api/v1/docs"}
                    class="text-primary underline-offset-2 hover:underline"
                  >
                    Open the API reference
                  </.link>
                </p>
              </div>
            </li>
          </ol>
        </.section_card>

        <.section_card id="account-details" icon="hero-building-office">
          <:title>Account</:title>
          <.detail_row>
            <:label>Name</:label>
            {@current_account.name}
          </.detail_row>
          <.detail_row>
            <:label>Slug</:label>
            <code>{@current_account.slug}</code>
          </.detail_row>
          <.detail_row>
            <:label>ID</:label>
            <code>{@current_account.id}</code>
          </.detail_row>
          <.detail_row>
            <:label>Signed in as</:label>
            {@current_scope.user.email}
          </.detail_row>
        </.section_card>
      </div>
    </div>
    """
  end
end
