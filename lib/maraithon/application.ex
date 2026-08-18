defmodule Maraithon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = Maraithon.Vault.validate_config!()
    :ok = Maraithon.DurablePayloadBinding.validate_config!()

    # OpenTelemetry auto-instrumentation. Must run before the supervisor starts
    # so :telemetry handlers are attached before the first request. No-op for
    # export when traces_exporter is :none (default dev/test).
    # Bandit creates its span before Endpoint plugs run. Never allowlist the
    # Telegram secret-token header (or other request credentials) into spans.
    OpentelemetryBandit.setup(request_headers: [])
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:maraithon, :repo])

    children = [
      MaraithonWeb.Telemetry,
      # Encryption vault (must start before Repo for encrypted fields)
      Maraithon.Vault,
      Maraithon.Repo,
      # A zero proof is an irreversible PostgreSQL write fence. Refuse to
      # start any new web/runtime writer still configured to use that tag.
      Maraithon.KeyRetirementBootGuard,
      # Stable exact-Agent guardian. It must outlive Runtime.Supervisor so an
      # AgentSupervisor subtree restart/shutdown still yields the original
      # monitor's exact DOWN proof.
      Supervisor.child_spec(Maraithon.Runtime.AgentWatcher, shutdown: 30_000),
      Maraithon.Accounts.AdminBootstrap,
      {DNSCluster, query: Application.get_env(:maraithon, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Maraithon.PubSub},
      # APNs requires HTTP/2; one small dedicated pool per Apple host.
      {Finch,
       name: Maraithon.Push.Finch,
       pools: %{
         "https://api.push.apple.com" => [protocols: [:http2], count: 1],
         "https://api.sandbox.push.apple.com" => [protocols: [:http2], count: 1]
       }},
      Maraithon.LogBuffer,
      Maraithon.ContextCache,
      Maraithon.UserIdentity,
      Maraithon.TelegramAssistant.LivenessSupervisor,
      Maraithon.TelegramAssistant.RunStreamPreview,
      # Per-chat inbound-message workers: keep webhook acks fast and serialize
      # concurrent messages within a chat.
      {Registry, keys: :unique, name: Maraithon.TelegramAssistant.ChatRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Maraithon.TelegramAssistant.ChatSupervisor},
      {Registry, keys: :unique, name: Maraithon.AssistantChat.ThreadRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Maraithon.AssistantChat.ThreadSupervisor},
      # Todo ingestion remains PostgreSQL-authoritative even while the
      # experimental multinode runtime is intentionally disabled.
      {Task.Supervisor, name: Maraithon.Todos.IngestionTaskSupervisor},
      Maraithon.Todos.IngestionCoordinator,
      # Maraithon runtime supervisor (agents, scheduler, effect runner)
      Maraithon.Runtime.Supervisor,
      # Start to serve requests, typically the last entry
      MaraithonWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options. Intensity is raised above
    # the OTP default so a flapping child (e.g. during a DB outage) backs off
    # via its own resilience machinery instead of shutting the node down.
    opts = [strategy: :one_for_one, name: Maraithon.Supervisor, max_restarts: 10, max_seconds: 60]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MaraithonWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
