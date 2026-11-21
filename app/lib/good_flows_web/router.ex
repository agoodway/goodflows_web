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

  # Cache routes are the only routes that accept cache (`ck_`) keys.
  pipeline :api_cache_authenticated do
    plug GoodFlowsWeb.Plugs.ApiAuth, :allow_cache_keys
  end

  # After `:load_project`: refuses `pk_` keys and other projects' `ck_`
  # keys, then responds `503` while no cache bucket is configured.
  pipeline :cache_access do
    plug GoodFlowsWeb.Plugs.RequireCacheAccess
  end

  pipeline :api_write do
    plug GoodFlowsWeb.Plugs.ApiAuth, :require_write_access
    plug GoodFlowsWeb.Plugs.RequireParsedBody
  end

  # Resolves the `:project` path segment; always the last plug of a scope.
  pipeline :load_project do
    plug GoodFlowsWeb.Plugs.LoadProject
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
    get "/projects", ProjectController, :index
    get "/runs/:id", RunController, :show
    get "/sprites-credential", SpritesCredentialController, :show
  end

  # Project-scoped reads: any valid API key, then the URL's project.
  scope "/api/v1/projects/:project", GoodFlowsWeb.Api.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated, :load_project]

    get "/", ProjectController, :show
    get "/recipes", RecipeController, :index
    get "/recipes/:id", RecipeController, :show
    get "/recipes/:id/runs", RunController, :index
    # Any valid key. The project is resolved before the action runs.
    get "/workflow-runs", WorkflowRunController, :index
    get "/workflow-runs/:run_id", WorkflowRunController, :show
    get "/review-policy", ReviewPolicyController, :show
    get "/review-policy/versions", ReviewPolicyController, :index
    get "/review-policy/versions/:version", ReviewPolicyController, :show_version
    get "/change-requests", ChangeRequestController, :index
    get "/change-requests/:number", ChangeRequestController, :show
    get "/change-requests/:number/git-facts/:head", ChangeRequestController, :show_git_facts
    get "/change-requests/:number/claims/:head", ChangeRequestController, :show_claims
    get "/change-requests/:number/verdict", ChangeRequestController, :verdict
    get "/change-requests/:number/scenario-sets", ScenarioSetController, :index

    get "/change-requests/:number/scenario-sets/:source/versions/:version",
        ScenarioSetController,
        :show

    get "/change-requests/:number/scenario-sets/:source/compare", ScenarioSetController, :compare
    get "/verify-runs", VerifyRunController, :index
    get "/verify-runs/:run_id", VerifyRunController, :show
    get "/feature-index", FeatureIndexController, :show
    get "/feature-index/versions", FeatureIndexController, :index
    get "/feature-index/versions/:version", FeatureIndexController, :show_version
    get "/events", EventController, :index
    get "/defects", DefectController, :index
    get "/calibration", CalibrationController, :show
  end

  # Cache lookup, reserve and commit: `sk_` and `ck_` keys. The per-scope
  # check needs the request's `scope`, so it runs in the controller.
  scope "/api/v1/projects/:project/caches", GoodFlowsWeb.Api.V1, as: :api_v1 do
    pipe_through [:api, :api_cache_authenticated, :load_project, :cache_access]

    get "/entries/:key", CacheEntryController, :show
    get "/entries", CacheEntryController, :lookup
    post "/entries/:key", CacheEntryController, :reserve
    post "/uploads/:upload_id/commit", CacheUploadController, :commit
  end

  # Write endpoints: private (sk_) API keys only.
  scope "/api/v1", GoodFlowsWeb.Api.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated, :api_write]

    post "/projects", ProjectController, :create
    put "/sprites-credential", SpritesCredentialController, :update
    delete "/sprites-credential", SpritesCredentialController, :delete
  end

  # Project-scoped writes: private (sk_) API keys only, then the URL's project.
  scope "/api/v1/projects/:project", GoodFlowsWeb.Api.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated, :api_write, :load_project]

    patch "/", ProjectController, :update
    delete "/", ProjectController, :delete
    post "/recipes", RecipeController, :create
    put "/recipes/:id", RecipeController, :update
    delete "/recipes/:id", RecipeController, :delete
    post "/recipes/:id/runs", RunController, :create
    post "/test-reports", TestReportController, :create
    # Private keys only. Auth and LoadProject run before WorkflowRunBody.
    post "/workflow-runs", WorkflowRunController, :create
    # Owner or admin only, checked before the body is read.
    put "/review-policy", ReviewPolicyController, :update
    # Any private key. The number and body are resolved in the controller.
    post "/change-requests", ChangeRequestController, :create
    post "/change-requests/:number/ready", ChangeRequestController, :ready
    post "/change-requests/:number/draft", ChangeRequestController, :draft
    post "/change-requests/:number/close", ChangeRequestController, :close
    post "/change-requests/:number/reopen", ChangeRequestController, :reopen
    post "/change-requests/:number/merged", ChangeRequestController, :merged
    post "/change-requests/:number/git-facts", ChangeRequestController, :report_git_facts
    post "/change-requests/:number/claims", ChangeRequestController, :upload_claims
    post "/change-requests/:number/scenario-sets", ScenarioSetController, :create

    post "/change-requests/:number/scenario-sets/:source/approvals",
         ScenarioSetController,
         :approve

    post "/change-requests/:number/scenario-sets/:source/rejections",
         ScenarioSetController,
         :reject

    get "/change-requests/:number/review", ReviewController, :show

    post "/change-requests/:number/review/items/:item_id/answers",
         ReviewController,
         :answer

    get "/change-requests/:number/tasks", ReviewController, :tasks
    post "/change-requests/:number/tasks/:task_id/done", ReviewController, :done

    post "/verify-runs", VerifyRunController, :create
    post "/verify-runs/:run_id/commit", VerifyRunController, :commit
    post "/feature-index", FeatureIndexController, :create

    put "/change-requests/:number/parent", ChangeRequestController, :set_parent
    delete "/change-requests/:number/parent", ChangeRequestController, :clear_parent
    post "/change-requests/:number/retarget", ChangeRequestController, :retarget
    post "/change-requests/:number/merge-lease", MergeLeaseController, :acquire
    post "/merge-leases/:lease_id/heartbeat", MergeLeaseController, :heartbeat
    delete "/merge-leases/:lease_id", MergeLeaseController, :release
    post "/defects", DefectController, :create
  end

  # Cache listing and purging: private (sk_) keys only, and `503` while no
  # cache bucket is configured.
  scope "/api/v1/projects/:project", GoodFlowsWeb.Api.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated, :api_write, :load_project, :cache_access]

    get "/caches", CacheEntryController, :index
    delete "/caches/entries/:key", CacheEntryController, :delete
    delete "/caches/entries", CacheEntryController, :delete_matching
  end

  # Cache-key minting, listing and revoking: private (sk_) keys only. They
  # work without a cache bucket.
  scope "/api/v1/projects/:project", GoodFlowsWeb.Api.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated, :api_write, :load_project]

    get "/cache-keys", CacheKeyController, :index
    post "/cache-keys", CacheKeyController, :create
    delete "/cache-keys/:id", CacheKeyController, :delete
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
