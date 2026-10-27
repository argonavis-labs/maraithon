defmodule Mix.Tasks.Maraithon.Agents.AttestTerminated do
  use Mix.Task

  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentTerminationProof
  alias Maraithon.Runtime.AgentTerminations

  @shortdoc "Attests destruction of one exact Agent node incarnation"

  @moduledoc """
  Records separately authorized, signed physical-termination evidence:

      mix maraithon.agents.attest_terminated \
        --incident-id UUID --evidence-id REFERENCE \
        --evidence-digest-hex SHA256_HEX --signature-base64 ED25519_SIGNATURE \
        --proved-by OPERATOR

  Production requires `MARAITHON_INCIDENT_DATABASE_URL` with the canonical
  incident-operator role and independently rebuilt verified TLS. The task
  writes immutable evidence only. A runtime-role reconciliation pass consumes
  the proof and removes the exact lease; the incident role cannot delete it.
  """

  @switches [
    incident_id: :string,
    evidence_id: :string,
    evidence_digest_hex: :string,
    signature_base64: :string,
    proved_by: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("unexpected Agent termination-attestation arguments")
    end

    configure_operator_storage!("MARAITHON_INCIDENT_DATABASE_URL")

    attrs = %{
      evidence_id: required!(opts, :evidence_id),
      evidence_digest: decode_hex!(required!(opts, :evidence_digest_hex)),
      signature: decode_base64!(required!(opts, :signature_base64)),
      proved_by: required!(opts, :proved_by)
    }

    result =
      case Ecto.Migrator.with_repo(Repo, fn _repo ->
             AgentTerminations.attest_external(required!(opts, :incident_id), attrs)
           end) do
        {:ok, task_result, _started_apps} -> task_result
        {:error, reason} -> {:error, {:repository_start_failed, reason}}
      end

    case result do
      {:attested, %AgentTerminationProof{} = proof} ->
        Mix.shell().info(
          "Recorded Agent termination proof #{proof.id}; runtime reconciliation is pending"
        )

      {:error, reason} ->
        Mix.raise("Agent termination attestation refused: #{inspect(reason)}")
    end
  end

  defp configure_operator_storage!(env_name) do
    Mix.Task.run("app.config")
    Maraithon.DatabaseTLS.configure_operator_repo_from_env!(env_name, Mix.env() == :prod)
  end

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> Mix.raise("missing --#{key |> Atom.to_string() |> String.replace("_", "-")}")
    end
  end

  defp decode_hex!(encoded) do
    case Base.decode16(encoded, case: :mixed) do
      {:ok, value} when byte_size(value) == 32 -> value
      _ -> Mix.raise("--evidence-digest-hex must be exactly 32 bytes of hexadecimal")
    end
  end

  defp decode_base64!(encoded) do
    decoded =
      case Base.decode64(encoded) do
        {:ok, value} -> {:ok, value}
        :error -> Base.decode64(encoded, padding: false)
      end

    case decoded do
      {:ok, value} when byte_size(value) == 64 -> value
      _ -> Mix.raise("--signature-base64 must encode one 64-byte Ed25519 signature")
    end
  end
end
