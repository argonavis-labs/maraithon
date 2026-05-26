import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :maraithon, Maraithon.Repo,
  username: System.get_env("PGUSER") || System.get_env("USER") || "postgres",
  password: System.get_env("PGPASSWORD") || "",
  hostname: "localhost",
  database: "maraithon_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :maraithon, MaraithonWeb.Endpoint,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "vvoIwP8nNJp8lGFZ9RR6Y7P31JfQ2raSNyk9Yev1qEa74gLVB0jW7aP8eFztubBE",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Allow insecure vault in test (uses deterministic key, NOT for production)
config :maraithon, allow_insecure_vault: true

# Disable background workers that poll the database (Scheduler, EffectRunner)
# Tests should start these explicitly if needed
config :maraithon, start_background_workers: false

config :maraithon, Maraithon.Runtime,
  llm_provider: Maraithon.LLM.MockProvider,
  llm_provider_name: "mock",
  llm_model: "mock-v1",
  anthropic_model: "claude-sonnet-4-20250514",
  openai_model: "gpt-5.4",
  openai_reasoning_effort: "high"

config :maraithon, :todos, mock_llm_when_unconfigured: true

config :maraithon, :memory_intelligence, mock_llm_when_unconfigured: true

# Disable post-write async embedding refresh in tests so we don't race the
# Ecto sandbox during teardown.
config :maraithon, Maraithon.Crm.PersonEmbeddings, async_enabled: false

# Same reason: keep post-reply async work synchronous in tests so the spawned
# Task doesn't outlive the sandbox checkout.
config :maraithon, Maraithon.TelegramAssistant.Runner,
  user_memory_async_enabled: false,
  compaction_async_enabled: false

config :maraithon, Maraithon.ContextCache.Builder, async_enabled: false

# Process inbound Telegram messages synchronously in tests so existing
# straight-line assertions on handle_telegram_event still hold.
config :maraithon, Maraithon.TelegramAssistant.ChatWorker, async_enabled: false

config :maraithon, Maraithon.AssistantChat.ThreadWorker, async_enabled: false

config :maraithon, Maraithon.WebSearch, enabled: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
