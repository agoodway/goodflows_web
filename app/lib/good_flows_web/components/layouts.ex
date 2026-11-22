defmodule GoodFlowsWeb.Layouts do
  @moduledoc """
  Application layouts and theme helpers shared by every page.
  """
  use GoodFlowsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-100 px-4 py-3 sm:px-6">
      <a href="/" class="flex items-center gap-3" aria-label="GoodFlows home">
        <span class="brand-mark" aria-hidden="true">GF</span>
        <span class="text-sm font-semibold">GoodFlows</span>
      </a>
      <nav aria-label="Account" class="flex flex-wrap items-center gap-2">
        <%= if @current_scope do %>
          <span class="hidden font-mono text-xs text-muted sm:block">
            {@current_scope.user.email}
          </span>
          <.button href={~p"/dashboard"} variant="subtle" size="sm">Dashboard</.button>
          <.button href={~p"/users/settings"} variant="subtle" size="sm">Settings</.button>
          <.button href={~p"/users/log-out"} method="delete" variant="subtle" size="sm">
            Log out
          </.button>
        <% else %>
          <.button navigate={~p"/users/register"} variant="subtle" size="sm">Register</.button>
          <.button navigate={~p"/users/log-in"} variant="primary" size="sm">Log in</.button>
        <% end %>
        <.theme_toggle />
      </nav>
    </header>

    <main class="bg-grid min-h-[calc(100vh-3.5rem)] px-4 py-8 sm:px-6 sm:py-12 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # --- Sidebar ---

  @doc "Renders the sidebar brand, navigation groups, and account switcher."
  attr :active_nav, :atom, default: nil
  attr :current_scope, :map, required: true
  attr :current_account, :map, default: nil

  def sidebar_content(assigns) do
    assigns = assign(assigns, :account_base, account_dashboard_path(assigns.current_account))

    ~H"""
    <div class="relative flex items-center justify-between border-b border-base-300/50 p-4">
      <.link href={@account_base} class="flex items-center gap-3">
        <span class="brand-mark" aria-hidden="true">GF</span>
        <span class="flex flex-col">
          <span class="text-sm font-semibold tracking-tight text-base-content">GoodFlows</span>
          <span class="font-mono text-[10px] uppercase tracking-wider text-muted">Workflows</span>
        </span>
      </.link>
      <button
        type="button"
        class="-mr-2 rounded-sm p-2 text-muted hover:bg-base-300/50 lg:hidden"
        phx-click={hide_mobile_sidebar()}
        aria-label="Close menu"
      >
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </div>

    <nav aria-label="Main" class="relative flex-1 space-y-1 overflow-y-auto px-2 py-1">
      <div class="nav-section-header">// Overview</div>
      <.sidebar_nav_item
        href={@account_base}
        icon="hero-squares-2x2"
        label="Dashboard"
        active={@active_nav == :dashboard}
      />

      <div class="nav-section-header">// Developers</div>
      <.sidebar_nav_item
        href={"#{@account_base}/api-keys"}
        icon="hero-key"
        label="API keys"
        active={@active_nav == :api_keys}
      />

      <div class="nav-section-header">// You</div>
      <.sidebar_nav_item
        href={~p"/users/settings"}
        icon="hero-cog-6-tooth"
        label="Settings"
        active={@active_nav == :settings}
      />
    </nav>

    <div :if={@current_account} class="relative border-t border-base-300/50 p-3">
      <.live_component
        module={GoodFlowsWeb.Components.AccountSwitcher}
        id="account-switcher"
        current_scope={@current_scope}
        current_account={@current_account}
      />
    </div>
    """
  end

  @doc "Renders a single sidebar link, highlighted when `active`."
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  def sidebar_nav_item(assigns) do
    ~H"""
    <.link href={@href} class={["nav-item", @active && "active"]} aria-current={@active && "page"}>
      <.icon name={@icon} class="size-5 shrink-0" />
      <span>{@label}</span>
    </.link>
    """
  end

  # --- Mobile Sidebar JS ---

  @doc "Opens the sidebar drawer below the `lg` breakpoint and focuses its first link."
  def show_mobile_sidebar do
    JS.add_class("sidebar-open", to: "#sidebar")
    |> JS.focus_first(to: "#sidebar")
  end

  @doc "Closes the sidebar drawer."
  def hide_mobile_sidebar do
    JS.remove_class("sidebar-open", to: "#sidebar")
  end

  defp account_dashboard_path(nil), do: ~p"/dashboard"
  defp account_dashboard_path(account), do: ~p"/dashboard/accounts/#{account.id}"

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      role="group"
      aria-label="Theme"
      class="flex items-center gap-px rounded border border-base-300 bg-base-300/50 p-px"
    >
      <button
        :for={
          {theme, label, icon} <- [
            {"system", "System theme", "hero-computer-desktop-micro"},
            {"light", "Light theme", "hero-sun-micro"},
            {"dark", "Dark theme", "hero-moon-micro"}
          ]
        }
        type="button"
        class="theme-toggle-btn flex rounded-sm p-1 text-muted transition-colors hover:bg-base-200 hover:text-base-content"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme={theme}
        aria-label={label}
        title={label}
      >
        <.icon name={icon} class="size-3" />
      </button>
    </div>
    """
  end
end
