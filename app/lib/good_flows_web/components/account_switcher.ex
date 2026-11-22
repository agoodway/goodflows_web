defmodule GoodFlowsWeb.Components.AccountSwitcher do
  @moduledoc """
  Account switcher at the foot of the dashboard sidebar.

  Links use `href` (full page load) rather than `navigate` so the request
  passes through `GoodFlowsWeb.Plugs.LoadAccount`, which records the
  account as the session's `last_account_id`.
  """
  use GoodFlowsWeb, :live_component

  alias GoodFlows.AccountContext

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div :if={!@multiple_accounts?} class="flex items-center gap-2.5 px-2.5 py-2">
        <.account_identity account={@current_account} role={@current_role} />
      </div>

      <div :if={@multiple_accounts?} class="dropdown dropdown-top w-full">
        <div
          tabindex="0"
          role="button"
          aria-label="Switch account"
          class="flex w-full cursor-pointer items-center gap-2.5 rounded-sm border border-transparent px-2.5 py-2 transition-colors hover:border-base-300 hover:bg-base-300/30"
        >
          <.account_identity account={@current_account} role={@current_role} />
          <.icon name="hero-chevron-up-down-mini" class="size-4 shrink-0 text-muted" />
        </div>

        <ul tabindex="0" class="dropdown-content menu-panel z-20 mb-1 w-full">
          <li :for={{account, role} <- @accessible_accounts}>
            <div
              :if={account.id == @current_account.id}
              class="menu-item text-muted"
              aria-current="true"
            >
              <span class="min-w-0 flex-1 truncate">{account.name}</span>
              <.icon name="hero-check-mini" class="size-4 shrink-0 text-primary" />
            </div>
            <.link
              :if={account.id != @current_account.id}
              href={~p"/dashboard/accounts/#{account.id}"}
              class="menu-item"
            >
              <span class="min-w-0 flex-1 truncate">{account.name}</span>
              <span class="font-mono text-[10px] uppercase text-muted">{role}</span>
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :account, :map, required: true
  attr :role, :atom, default: nil

  defp account_identity(assigns) do
    ~H"""
    <div
      aria-hidden="true"
      class="flex size-7 shrink-0 items-center justify-center rounded-sm border border-primary/25 bg-primary/15 font-mono text-xs font-bold text-primary"
    >
      {@account.name |> String.first() |> String.upcase()}
    </div>
    <div class="min-w-0 flex-1">
      <div class="truncate text-sm font-medium">{@account.name}</div>
      <div :if={@role} class="font-mono text-[10px] uppercase tracking-wider text-muted">
        {@role}
      </div>
    </div>
    """
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    accessible_accounts =
      socket.assigns[:accessible_accounts] ||
        AccountContext.list_user_accounts(assigns.current_scope.user)

    current_role =
      Enum.find_value(accessible_accounts, fn {account, role} ->
        account.id == socket.assigns.current_account.id && role
      end)

    {:ok,
     socket
     |> assign(:accessible_accounts, accessible_accounts)
     |> assign(:current_role, current_role)
     |> assign(:multiple_accounts?, match?([_, _ | _], accessible_accounts))}
  end
end
