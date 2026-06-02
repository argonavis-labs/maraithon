# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :maraithon,
  ecto_repos: [Maraithon.Repo],
  generators: [timestamp_type: :utc_datetime]

# Use a custom Postgrex types module so pgvector types are registered.
config :maraithon, Maraithon.Repo, types: Maraithon.PostgrexTypes

# Maraithon runtime configuration
config :maraithon, Maraithon.Runtime,
  # Intervals
  heartbeat_interval_ms: :timer.minutes(15),
  checkpoint_interval_ms: :timer.minutes(10),
  effect_poll_interval_ms: :timer.seconds(1),
  effect_claim_timeout_ms: :timer.minutes(5),
  effect_batch_size: 10,
  scheduler_poll_interval_ms: :timer.seconds(5),
  scheduler_dispatch_timeout_ms: :timer.minutes(1),
  briefing_cron_interval_ms: :timer.minutes(1),
  health_report_interval_ms: :timer.minutes(1),
  proactive_check_in_interval_ms: :timer.minutes(10),
  proactive_check_in_initial_delay_ms: :timer.minutes(10),
  proactive_check_in_batch_size: 25,
  todo_completion_sweep_interval_ms: :timer.minutes(30),
  todo_completion_sweep_initial_delay_ms: :timer.minutes(30),
  todo_completion_sweep_user_limit: 100,
  oauth_refresh_interval_ms: :timer.minutes(5),
  oauth_refresh_lookahead_seconds: 15 * 60,
  oauth_refresh_batch_size: 100,
  tool_allowed_paths: [File.cwd!(), System.tmp_dir!()],
  # Timeouts
  llm_timeout_ms: :timer.seconds(120),
  tool_timeout_ms: :timer.seconds(30),
  # Retries
  max_effect_attempts: 3,
  # LLM provider
  llm_provider: nil,
  llm_provider_name: "unconfigured",
  llm_model: "gpt-5.4",
  anthropic_model: "claude-sonnet-4-20250514",
  openai_model: "gpt-5.4",
  openrouter_model: "qwen/qwen3.7-max",
  openrouter_reasoning_effort: "medium",
  openai_reasoning_effort: "high",
  llm_primary_max_tokens: 32_000

config :maraithon, :telegram_assistant,
  chat_reasoning_effort: "none",
  telegram_proactive_checkins_enabled: false,
  proactive_delivery_planner_enabled: true,
  proactive_candidate_ttl_minutes: 120

# Configure the endpoint
config :maraithon, MaraithonWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: MaraithonWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Maraithon.PubSub,
  live_view: [signing_salt: "CbxGKvU2"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :logger,
  backends: [:console, Maraithon.LogBufferBackend]

config :logger, Maraithon.LogBufferBackend, level: :debug

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :maraithon, Maraithon.LogBuffer, max_entries: 500

config :maraithon, Maraithon.FlyLogs,
  api_token: "",
  api_base_url: "https://api.fly.io/api/v1",
  apps: [],
  region: nil,
  receive_timeout_ms: 3_000

config :maraithon, Maraithon.WebSearch,
  enabled: true,
  base_url: "https://duckduckgo.com/html/",
  limit: 3

# OpenTelemetry — traces export is disabled by default and turned on in
# config/runtime.exs only when LOGFIRE_WRITE_TOKEN is present.
#
# The sampler drops root-level Ecto query spans (background-poller noise)
# while keeping Ecto queries that are children of a real trace — see
# Maraithon.Telemetry.OtelSampler. Wrapped in :parent_based so children
# follow their parent's decision.
config :opentelemetry,
  traces_exporter: :none,
  sampler: {:parent_based, %{root: {Maraithon.Telemetry.OtelSampler, %{}}}},
  resource: %{service: %{name: "maraithon"}}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
