defmodule GoodFlowsWeb.Router do
  @moduledoc "HTTP routes for browser and API clients."
  use GoodFlowsWeb, :router

  import GoodFlowsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GoodFlowsWeb.Layouts, :root}
    plug :protect_from_forgery
    # GoodFlowsWeb.Plugs.CSPNonce appends a per-request nonce to script-src.
    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'"
    }

    plug GoodFlowsWeb.Plugs.CSPNonce
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]

    plug CORSPlug,
      origin: &GoodFlowsWeb.CORS.origins/0,
      methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
      headers: ["Content-Type", "Authorization", "Accept"],
      max_age: 86_400

    plug OpenApiSpex.Plug.PutApiSpec, module: GoodFlowsWeb.ApiSpec
  end

  pipeline :api_authenticated do
    plug GoodFlowsWeb.Plugs.ApiAuth
  end

  pipeline :api_write do
    plug GoodFlowsWeb.Plugs.ApiAuth, :require_write_access
  end

  pipeline :load_account do
    plug GoodFlowsWeb.Plugs.LoadAccount
  end

  scope "/", GoodFlowsWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## JSON API

  # Spec and docs are public.
  scope "/api/v1" do
    pipe_through :api

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/v1/openapi"
    options "/*path", GoodFlowsWeb.Api.V1.PreflightController, :options
  end

  # Read endpoints: any valid API key.
  scope "/api/v1", GoodFlowsWeb.Api.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated]

    get "/me", MeController, :show

    get "/recipes", RecipeController, :index
    get "/recipes/:id", RecipeController, :show
    get "/recipes/:id/runs", RunController, :index
    get "/runs/:id", RunController, :show
    get "/sprites-credential", SpritesCredentialController, :show
  end

  # Write endpoints: private (sk_) API keys only.
  scope "/api/v1", GoodFlowsWeb.Api.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated, :api_write]

    post "/recipes", RecipeController, :create
    put "/recipes/:id", RecipeController, :update
    delete "/recipes/:id", RecipeController, :delete
    post "/recipes/:id/runs", RunController, :create
    put "/sprites-credential", SpritesCredentialController, :update
    delete "/sprites-credential", SpritesCredentialController, :delete
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:good_flows, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: GoodFlowsWeb.Telemetry,
        csp_nonce_assign_key: %{script: :csp_nonce, style: :csp_nonce}

      forward "/mailbox", Plug.Swoosh.MailboxPreview,
        csp_nonce_assign_key: %{script: :csp_nonce, style: :csp_nonce}
    end
  end

  ## Account-scoped dashboard

  scope "/dashboard/accounts/:account_id", GoodFlowsWeb do
    pipe_through [:browser, :require_authenticated_user, :load_account]

    live_session :account_scoped,
      on_mount: [
        {GoodFlowsWeb.UserAuth, :require_authenticated},
        {GoodFlowsWeb.UserAuth, :load_account_context}
      ],
      layout: {GoodFlowsWeb.Layouts, :dashboard} do
      live "/", DashboardLive, :index
      live "/api-keys", ApiKeyLive.Index, :index
    end
  end

  scope "/", GoodFlowsWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/dashboard", DashboardRedirectController, :index
  end

  ## Authentication routes

  scope "/", GoodFlowsWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{GoodFlowsWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", GoodFlowsWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{GoodFlowsWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
