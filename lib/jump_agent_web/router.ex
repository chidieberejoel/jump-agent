defmodule JumpAgentWeb.Router do
  use JumpAgentWeb, :router

  import JumpAgentWeb.Plugs.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {JumpAgentWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_auth do
    plug :require_authenticated_user
  end

  pipeline :redirect_if_auth do
    plug :redirect_if_authenticated
  end

  scope "/", JumpAgentWeb do
    pipe_through [:browser, :redirect_if_auth]

    get "/", PageController, :home
  end

  # Authentication routes
  scope "/auth", JumpAgentWeb do
    pipe_through :browser

    # Logout is always accessible
    get "/logout", AuthController, :logout

    # OAuth routes should redirect if already authenticated
    scope "/" do
      pipe_through [:redirect_if_auth]

      get "/:provider", AuthController, :request
      get "/:provider/callback", AuthController, :callback
    end
  end

  scope "/", JumpAgentWeb do
    pipe_through [:browser, :require_auth]

    get "/dashboard", DashboardController, :index

    live_session :require_authenticated_user,
      on_mount: [{JumpAgentWeb.LiveAuth, :require_authenticated_user}] do
      live "/dashboard/live", DashboardLive, :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", JumpAgentWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:jump_agent, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: JumpAgentWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # Catch-all route for 404s - must be at the very end
  scope "/", JumpAgentWeb do
    pipe_through :browser

    get "/*path", PageController, :not_found
  end
end
