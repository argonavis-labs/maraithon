defmodule Mix.Tasks.Maraithon.Coordination.Activate do
  use Mix.Task
  alias Maraithon.Runtime.Coordination.Protocol
  @shortdoc "Irreversibly activates partition-fenced runtime coordination"

  @moduledoc """
  Performs the one-way, stopped-fleet runtime-coordination activation.
  Production requires `MARAITHON_ACTIVATION_DATABASE_URL` using the canonical
  activation-operator role and independently rebuilt verified TLS.
  """

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          confirm: :string,
          evidence_id: :string,
          evidence_digest: :string,
          activated_by: :string,
          exact_revision: :string,
          lock_timeout_ms: :integer
        ],
        aliases: [c: :confirm]
      )

    if rest != [] or invalid != [], do: Mix.raise("unexpected activation arguments")

    configure_operator_storage!("MARAITHON_ACTIVATION_DATABASE_URL")

    activation_opts =
      [
        confirmation: opts[:confirm],
        evidence_id: opts[:evidence_id],
        evidence_digest: opts[:evidence_digest],
        activated_by: opts[:activated_by],
        exact_revision: opts[:exact_revision]
      ]
      |> maybe_put(:lock_timeout_ms, opts[:lock_timeout_ms])

    result =
      Ecto.Migrator.with_repo(Maraithon.Repo, fn _ -> Protocol.activate(activation_opts) end)

    case result do
      {:ok, {:ok, status}, _} when status in [:activated, :already_active] ->
        Mix.shell().info("Partition-fenced runtime coordination #{status}")

      {:ok, {:error, reason}, _} ->
        Mix.raise("Coordination activation refused: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("Repository start failed: #{inspect(reason)}")
    end
  end

  defp configure_operator_storage!(env_name) do
    Mix.Task.run("app.config")
    Maraithon.DatabaseTLS.configure_operator_repo_from_env!(env_name, Mix.env() == :prod)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
