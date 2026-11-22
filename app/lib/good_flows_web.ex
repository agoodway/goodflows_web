defmodule GoodFlowsWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use GoodFlowsWeb, :controller
      use GoodFlowsWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  @doc "Static asset paths served by `Plug.Static` and known to verified routes."
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @doc "Imports for `use GoodFlowsWeb, :router`."
  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @doc "Imports for `use GoodFlowsWeb, :channel`."
  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  @doc "Imports for `use GoodFlowsWeb, :controller`."
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: GoodFlowsWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @doc "Imports for `use GoodFlowsWeb, :live_view`, including the Sentry on_mount hook."
  def live_view do
    quote do
      use Phoenix.LiveView

      on_mount Sentry.LiveViewHook

      unquote(html_helpers())
    end
  end

  @doc "Imports for `use GoodFlowsWeb, :live_component`."
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @doc "Imports for `use GoodFlowsWeb, :html` function component modules."
  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: GoodFlowsWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import GoodFlowsWeb.CoreComponents
      import GoodFlowsWeb.DashboardComponents

      # Common modules used in templates
      alias GoodFlowsWeb.Layouts
      alias Phoenix.LiveView.JS

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  @doc "Enables the `~p` sigil against `GoodFlowsWeb.Router`."
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: GoodFlowsWeb.Endpoint,
        router: GoodFlowsWeb.Router,
        statics: GoodFlowsWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
