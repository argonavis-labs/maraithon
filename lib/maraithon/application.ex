defmodule Maraithon.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # OpenTelemetry auto-instrumentation. Must run before the supervisor starts
    # so :telemetry handlers are attached before the first request. No-op for
    # export when traces_exporter is :none (default dev/test).
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryEcto.setup([:maraithon, :repo])

    children = [
      MaraithonWeb.Telemetry,
      # Encryption vault (must start before Repo for encrypted fields)
      Maraithon.Vault,
      Maraithon.Repo,
      Maraithon.Accounts.AdminBootstrap,
      {DNSCluster, query: Application.get_env(:maraithon, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Maraithon.PubSub},
      Maraithon.LogBuffer,
      Maraithon.ContextCache,
      Maraithon.TelegramAssistant.LivenessSupervisor,
      Maraithon.TelegramAssistant.RunStreamPreview,
      # Per-chat inbound-message workers: keep webhook acks fast and serialize
      # concurrent messages within a chat.
      {Registry, keys: :unique, name: Maraithon.TelegramAssistant.ChatRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Maraithon.TelegramAssistant.ChatSupervisor},
      {Registry, keys: :unique, name: Maraithon.AssistantChat.ThreadRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Maraithon.AssistantChat.ThreadSupervisor},
      Maraithon.AssistantChat.RunRecovery,
      # Maraithon runtime supervisor (agents, scheduler, effect runner)
      Maraithon.Runtime.Supervisor,
      # Start to serve requests, typically the last entry
      MaraithonWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Maraithon.Supervisor]
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
