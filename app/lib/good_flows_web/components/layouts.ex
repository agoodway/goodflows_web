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
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <span class="text-sm font-bold tracking-tight">GoodFlows</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center text-sm">
          <%= if @current_scope do %>
            <li class="hidden sm:block text-base-content/60">{@current_scope.user.email}</li>
            <li>
              <.link href={~p"/dashboard"} class="btn btn-ghost btn-sm">Dashboard</.link>
            </li>
            <li>
              <.link href={~p"/users/settings"} class="btn btn-ghost btn-sm">Settings</.link>
            </li>
            <li>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
                Log out
              </.link>
            </li>
          <% else %>
            <li>
              <.link navigate={~p"/users/register"} class="btn btn-ghost btn-sm">Register</.link>
            </li>
            <li>
              <.link navigate={~p"/users/log-in"} class="btn btn-primary btn-sm">Log in</.link>
            </li>
          <% end %>
          <li>
            <.theme_toggle />
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
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

  @doc "Renders the sidebar logo, navigation groups, and signed-in user."
  attr :active_nav, :atom, required: true
  attr :current_scope, :map, required: true
  attr :current_account, :map, default: nil

  def sidebar_content(assigns) do
    assigns = assign(assigns, :account_base, account_dashboard_path(assigns.current_account))

    ~H"""
    <%!-- Logo --%>
    <div class="flex h-14 shrink-0 items-center px-5 border-b border-white/[0.06]">
      <.link href={@account_base} class="flex items-center gap-2.5">
        <%!-- Replace with your logo --%>
        <span class="text-sm font-bold tracking-tight text-white/90">GoodFlows</span>
      </.link>
    </div>

    <%!-- Navigation --%>
    <nav class="flex flex-1 flex-col px-3 py-4">
      <ul role="list" class="flex flex-1 flex-col gap-y-5">
        <li>
          <p class="px-2 mb-2 text-[0.65rem] font-semibold uppercase tracking-widest text-white/30">
            Overview
          </p>
          <ul role="list" class="space-y-0.5">
            <.sidebar_nav_item
              href={@account_base}
              icon="hero-squares-2x2"
              label="Dashboard"
              active={@active_nav == :dashboard}
            />
          </ul>
        </li>

        <li>
          <p class="px-2 mb-2 text-[0.65rem] font-semibold uppercase tracking-widest text-white/30">
            Developers
          </p>
          <ul role="list" class="space-y-0.5">
            <.sidebar_nav_item
              href={"#{@account_base}/api-keys"}
              icon="hero-key"
              label="API Keys"
              active={@active_nav == :api_keys}
            />
          </ul>
        </li>

        <%!-- Bottom section --%>
        <li class="mt-auto">
          <ul role="list" class="space-y-0.5">
            <.sidebar_nav_item
              href={~p"/users/settings"}
              icon="hero-cog-6-tooth"
              label="Settings"
              active={@active_nav == :settings}
            />
          </ul>

          <%!-- User info --%>
          <div class="mt-3 pt-3 border-t border-white/[0.06]">
            <div class="flex items-center gap-2.5 px-2 py-1.5">
              <div class="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-white/10 text-xs font-bold text-white/70">
                {String.first(@current_scope.user.email) |> String.upcase()}
              </div>
              <div class="min-w-0 flex-1">
                <p class="truncate text-xs font-medium text-white/70">
                  {@current_scope.user.email}
                </p>
              </div>
            </div>
          </div>
        </li>
      </ul>
    </nav>
    """
  end

  @doc "Renders a single sidebar link, highlighted when `active`."
  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  def sidebar_nav_item(assigns) do
    ~H"""
    <li>
      <.link
        href={@href}
        class={[
          "group flex items-center gap-x-2.5 rounded-md px-2 py-1.5 text-[0.8125rem] font-medium transition-colors",
          if(@active,
            do: "bg-white/10 text-white",
            else: "text-white/60 hover:bg-white/[0.06] hover:text-white/80"
          )
        ]}
      >
        <.icon
          name={@icon}
          class={[
            "size-[1.125rem] shrink-0",
            if(@active,
              do: "text-primary",
              else: "text-white/30 group-hover:text-white/60"
            )
          ]}
        />
        {@label}
      </.link>
    </li>
    """
  end

  # --- Mobile Sidebar JS ---

  @doc "Slides the mobile sidebar in and focuses its first link."
  def show_mobile_sidebar do
    JS.show(
      to: "#mobile-sidebar-backdrop",
      transition: {"transition-opacity ease-linear duration-300", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "#mobile-sidebar-overlay",
      transition: {"transition-opacity ease-linear duration-300", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "#mobile-sidebar-panel",
      transition:
        {"transition ease-in-out duration-300 transform", "-translate-x-full", "translate-x-0"}
    )
    |> JS.focus_first(to: "#mobile-sidebar-panel")
  end

  @doc "Slides the mobile sidebar out."
  def hide_mobile_sidebar do
    JS.hide(
      to: "#mobile-sidebar-panel",
      transition:
        {"transition ease-in-out duration-300 transform", "translate-x-0", "-translate-x-full"}
    )
    |> JS.hide(
      to: "#mobile-sidebar-overlay",
      transition: {"transition-opacity ease-linear duration-300", "opacity-100", "opacity-0"}
    )
    |> JS.hide(
      to: "#mobile-sidebar-backdrop",
      transition: {"transition-opacity ease-linear duration-300", "opacity-100", "opacity-0"},
      time: 300
    )
  end

  defp account_dashboard_path(nil), do: ~p"/dashboard"
  defp account_dashboard_path(account), do: ~p"/dashboard/accounts/#{account.id}"

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
