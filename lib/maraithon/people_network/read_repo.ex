defmodule Maraithon.PeopleNetwork.ReadRepo do
  @moduledoc "A single connection reserved for background People projection work."
  use Ecto.Repo, otp_app: :maraithon, adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    base = Application.fetch_env!(:maraithon, Maraithon.Repo)

    {:ok,
     base
     |> Keyword.merge(config)
     |> Keyword.put(:pool_size, 1)
     |> Keyword.put(:timeout, 5_000)
     |> Keyword.put(:queue_target, 100)
     |> Keyword.put(:queue_interval, 1_000)
     |> Keyword.put(:telemetry_prefix, [:maraithon, :people_network, :repo])
     |> Keyword.put(:parameters, statement_timeout: "4000", lock_timeout: "500")}
  end
end
