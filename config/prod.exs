import Config

# Note: SSL is handled by Cloud Run, not the app
# Health check endpoint excluded from any SSL checks

# Serve digested (content-hashed) assets built by `mix assets.deploy`.
config :maraithon, MaraithonWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

# Production logging - JSON format for Cloud Logging
config :logger, :default_formatter,
  format: {Maraithon.LogFormatter, :format},
  utc_log: true,
  # Pass complete Logger metadata to the custom formatter. LogFormatter keeps
  # an explicit output allowlist, so operational fields are available without
  # dumping arbitrary metadata into production logs.
  metadata: :all

config :logger,
  level: :info,
  backends: [:console, Maraithon.LogBufferBackend]

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
