defmodule Mix.Tasks.Maraithon.Effects.AttestActivation do
  use Mix.Task
  alias Maraithon.Runtime.Coordination.Protocol
  @shortdoc "One-way stopped-fleet evidence attestation for exact Effect activation"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          evidence_id: :string,
          evidence_digest: :string,
          activated_by: :string,
          exact_revision: :string
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("unexpected attestation arguments")

    attestation = [
      evidence_id: opts[:evidence_id],
      evidence_digest: opts[:evidence_digest],
      activated_by: opts[:activated_by],
      exact_revision: opts[:exact_revision]
    ]

    result =
      Ecto.Migrator.with_repo(
        Maraithon.Repo,
        fn _ -> Protocol.attest_effect_activation_evidence(attestation) end
      )

    case result do
      {:ok, {:ok, status}, _} when status in [:attested, :already_attested] ->
        Mix.shell().info("Exact Effect activation evidence #{status}")

      {:ok, {:error, reason}, _} ->
        Mix.raise("Effect attestation refused: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("Repository start failed: #{inspect(reason)}")
    end
  end
end
