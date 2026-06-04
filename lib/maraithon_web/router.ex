defmodule MaraithonWeb.Router do
  use MaraithonWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug MaraithonWeb.Plugs.FetchCurrentUser
    plug :fetch_live_flash
    plug :put_root_layout, html: {MaraithonWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_authenticated_user do
    plug MaraithonWeb.Plugs.RequireAuthenticatedUser
  end

  pipeline :browser_admin do
    plug MaraithonWeb.Plugs.RequireAdmin
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_auth do
    plug MaraithonWeb.Plugs.RequireApiToken
  end

  pipeline :mobile_api_auth do
    plug MaraithonWeb.Plugs.RequireMobileSession
  end

  pipeline :companion_auth do
    plug MaraithonWeb.Plugs.CompanionDeviceAuth
  end

  # Health check endpoint
  scope "/health", MaraithonWeb do
    get "/", HealthController, :index
  end

  # Sparkle appcast for the Mac companion app. Public by design — every
  # installed app must be able to read it without device credentials.
  scope "/companion", MaraithonWeb do
    get "/appcast.xml", AppcastController, :show
  end

  # Public auth routes
  scope "/", MaraithonWeb do
    pipe_through :browser

    get "/", HomeController, :index
    get "/login", HomeController, :login
    get "/privacy", MarketingController, :privacy
    get "/terms", MarketingController, :terms
    get "/support", MarketingController, :support
    get "/changelog", ChangelogController, :index
    post "/auth/magic-link", SessionController, :create_magic_link
    get "/auth/magic/:token", SessionController, :consume_magic_link
    delete "/logout", SessionController, :delete
  end

  # OAuth routes
  scope "/auth", MaraithonWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/google", OAuthController, :google
    get "/google/callback", OAuthController, :google_callback
    get "/github", OAuthController, :github
    get "/github/callback", OAuthController, :github_callback
    get "/slack", OAuthController, :slack
    get "/slack/callback", OAuthController, :slack_callback
    get "/linear", OAuthController, :linear
    get "/linear/callback", OAuthController, :linear_callback
    get "/notion", OAuthController, :notion
    get "/notion/callback", OAuthController, :notion_callback
    get "/notaui", OAuthController, :notaui
    get "/notaui/callback", OAuthController, :notaui_callback
  end

  # Web UI - authenticated user pages
  scope "/", MaraithonWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/connectors", ConnectorsController, :index
    get "/connectors/:provider", ConnectorsController, :show
    post "/connectors/:provider/disconnect", ConnectorsController, :disconnect
    get "/conenctors", ConnectorsController, :legacy_redirect
    get "/how-it-works", HowItWorksController, :index

    # Companion desktop app pairing flow
    get "/companion/auth", CompanionAuthController, :show
    post "/companion/auth/approve", CompanionAuthController, :approve
    get "/companion/auth/denied", CompanionAuthController, :deny
  end

  # Web UI - admin-only pages
  scope "/", MaraithonWeb do
    pipe_through [:browser, :browser_admin]

    get "/admin", AdminPageController, :index
    get "/admin/companion-devices", AdminPageController, :companion_devices
    get "/settings", SettingsController, :index
  end

  scope "/", MaraithonWeb do
    pipe_through :browser

    live_session :authenticated,
      on_mount: [{MaraithonWeb.LiveUserAuth, :ensure_authenticated}] do
      live "/agents/library/:behavior", AgentLibraryLive, :show
      live "/agents/new", AgentBuilderLive, :new
      live "/agents", AgentsLive, :index
      live "/dashboard", DashboardLive, :index
      live "/insights", InsightsLive, :index
      live "/todos", TodosLive, :index
      live "/operator/people", PeopleLive, :index
      live "/operator/memories", MemoriesLive, :index
    end
  end

  # API v1
  scope "/api/mobile", MaraithonWeb do
    pipe_through :api

    post "/auth/magic-link", MobileAuthController, :create_magic_link
    post "/auth/magic-code", MobileAuthController, :consume_magic_code
    get "/auth/magic/:token", MobileAuthController, :consume_magic_link
    post "/auth/magic/:token", MobileAuthController, :consume_magic_link
  end

  scope "/api/mobile", MaraithonWeb do
    pipe_through [:api, :mobile_api_auth]

    get "/me", MobileAuthController, :me
    delete "/session", MobileAuthController, :delete
    get "/todo-activity", MobileTodoController, :activity
    get "/todos", MobileTodoController, :index
    post "/todos", MobileTodoController, :create
    get "/todos/:id", MobileTodoController, :show
    post "/todos/:id/chat", MobileTodoController, :chat_thread
    patch "/todos/:id", MobileTodoController, :update
    delete "/todos/:id", MobileTodoController, :delete
    post "/todos/:id/actions/:action", MobileTodoController, :perform_action
    get "/people", MobilePeopleController, :index
    post "/people", MobilePeopleController, :create
    get "/people/:id", MobilePeopleController, :show
    patch "/people/:id", MobilePeopleController, :update
    delete "/people/:id", MobilePeopleController, :delete
    post "/people/:id/merge", MobilePeopleController, :merge
    get "/chat/threads", MobileChatController, :index
    post "/chat/threads", MobileChatController, :create
    get "/chat/threads/:id", MobileChatController, :show
    patch "/chat/threads/:id", MobileChatController, :update
    post "/chat/threads/:thread_id/messages", MobileChatController, :create_message
    delete "/chat/threads/:thread_id/messages/:message_id", MobileChatController, :delete_message
    get "/chat/runs/:id", MobileChatController, :show_run
    post "/chat/prepared-actions/:id/decision", MobileChatController, :decide_prepared_action
  end

  scope "/api/v1", MaraithonWeb do
    pipe_through [:api, :api_auth]

    # Agent management
    get "/agent-architecture", AgentController, :architectures
    post "/agents", AgentController, :create
    get "/agents", AgentController, :index
    get "/agents/:id", AgentController, :show
    patch "/agents/:id", AgentController, :update
    delete "/agents/:id", AgentController, :delete
    post "/agents/:id/start", AgentController, :start
    post "/agents/:id/ask", AgentController, :ask
    post "/agents/:id/stop", AgentController, :stop
    get "/agents/:id/events", AgentController, :events
    get "/agents/:id/spend", AgentController, :spend
    post "/control", ControlController, :handle
    get "/admin/dashboard", AdminController, :dashboard
    post "/admin/diagnostics/export", AdminController, :diagnostics_export
    get "/admin/agents/:id/inspection", AdminController, :agent_inspection
    get "/admin/fly/logs", AdminController, :fly_logs
    get "/admin/connections", AdminController, :connections
    get "/admin/gmail/recent", AdminController, :gmail_recent
    get "/admin/todos", AdminController, :todos
    post "/admin/todos/dismiss", AdminController, :dismiss_todos
    post "/admin/open-work/rebuild", AdminController, :rebuild_open_work
    get "/admin/open-work/rebuild/:job_id", AdminController, :open_work_rebuild_status
    post "/admin/open-work/restore-recent", AdminController, :restore_recent_open_work
    post "/admin/operator-state/reset", AdminController, :reset_operator_state
    post "/admin/telegram/push", AdminController, :push_telegram
    post "/admin/insights/refresh", AdminController, :refresh_insights
    post "/admin/chief_of_staff/ensure", AdminController, :ensure_chief_of_staff
    post "/admin/chief-of-staff/ensure", AdminController, :ensure_chief_of_staff
    delete "/admin/connections/:provider", AdminController, :disconnect_connection

    # Spend tracking
    get "/spend", AgentController, :total_spend

    # System health with details
    get "/health", HealthController, :detailed

    # Event ingress - external systems publish events here
    post "/events", EventController, :publish
    get "/events/topics", EventController, :topics

    # Integration sync endpoints
    post "/integrations/notaui/sync", NotauiController, :sync
  end

  # Companion desktop app endpoints (bearer auth via per-device token).
  scope "/api/v1/companion", MaraithonWeb do
    pipe_through [:api, :companion_auth]

    post "/messages", CompanionController, :ingest
    post "/notes", CompanionController, :ingest_notes
    post "/voice-memos", CompanionController, :ingest_voice_memos
    post "/calendar-events", CompanionController, :ingest_calendar_events
    post "/reminders", CompanionController, :ingest_reminders
    post "/files", CompanionController, :ingest_files
    post "/browser-history", CompanionController, :ingest_browser_history
    post "/recall", CompanionController, :recall
    post "/device-keys", CompanionController, :upload_device_key
    get "/device-keys/me", CompanionController, :current_device_key
    get "/whoami", CompanionController, :whoami
    get "/devices", CompanionController, :list_devices
    post "/devices/:id/revoke", CompanionController, :revoke_device
    delete "/devices/:id/data", CompanionController, :purge_device_data
    delete "/devices/:id/data/:source", CompanionController, :purge_device_data
    delete "/devices/:id/messages", CompanionController, :purge_messages
    delete "/devices/:id", CompanionController, :delete_device
  end

  # Hosted MCP endpoint for tool-capable clients.
  scope "/", MaraithonWeb do
    pipe_through [:api, :api_auth]

    post "/mcp", McpController, :handle
  end

  # Webhooks from external services (connectors)
  scope "/webhooks", MaraithonWeb do
    pipe_through :api

    post "/github", WebhookController, :github
    post "/google/calendar", WebhookController, :google_calendar
    post "/google/gmail", WebhookController, :google_gmail
    post "/slack", WebhookController, :slack
    get "/whatsapp", WebhookController, :whatsapp
    post "/whatsapp", WebhookController, :whatsapp
    post "/linear", WebhookController, :linear
    post "/telegram/:secret_path", WebhookController, :telegram
  end
end
