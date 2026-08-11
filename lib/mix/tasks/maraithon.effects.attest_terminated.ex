defmodule Mix.Tasks.Maraithon.Effects.AttestTerminated do
  use Mix.Task

  alias Maraithon.Effects.TerminationAttestations
  alias Maraithon.Repo

  @shortdoc "Attests that one exact Effect task can no longer run"

  @moduledoc """
  Records separately authorized, task-bound physical-termination proof:

      mix maraithon.effects.attest_terminated \
        --effect-id UUID --claim-token UUID --owner-node NODE \
        --supervisor-id UUID --task-id UUID --evidence-id REFERENCE \
        --attested-by OPERATOR \
        --confirm PHYSICAL_TASK_TERMINATED

  Use only after external infrastructure evidence proves that the named BEAM
  task incarnation cannot still execute. Production requires
  `MARAITHON_INCIDENT_DATABASE_URL` using the canonical incident-operator role
  and independently rebuilt verified TLS. The task starts only Repo dependencies,
  atomically records an immutable attestation plus the exact external Task proof.
  Ordinary runtime reconciliation later settles the Effect; this incident command
  never receives ordinary Effect settlement DML and never claims provider outcome.
  """

  @switches [
    effect_id: :string,
    claim_token: :string,
    owner_node: :string,
    supervisor_id: :string,
    task_id: :string,
    evidence_id: :string,
    attested_by: :string,
    confirm: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("unexpected termination-attestation arguments")
    end

    configure_operator_storage!("MARAITHON_INCIDENT_DATABASE_URL")

    identity = %{
      effect_id: required!(opts, :effect_id),
      claim_token: required!(opts, :claim_token),
      owner_node: required!(opts, :owner_node),
      supervisor_id: required!(opts, :supervisor_id),
      task_id: required!(opts, :task_id)
    }

    result =
      case Ecto.Migrator.with_repo(Repo, fn _repo ->
             TerminationAttestations.record(
               identity,
               required!(opts, :evidence_id),
               required!(opts, :attested_by),
               opts[:confirm]
             )
           end) do
        {:ok, task_result, _started_apps} -> task_result
        {:error, reason} -> {:error, {:repository_start_failed, reason}}
      end

    case result do
      {:ok, %{attestation: attestation, task_assignment: nil}} ->
        Mix.shell().info(
          "Recorded uncoordinated termination attestation #{attestation.id}. " <>
            "Ordinary runtime reconciliation will settle the Effect."
        )

      {:ok, %{attestation: attestation, task_assignment: assignment}} ->
        Mix.shell().info(
          "Recorded termination attestation #{attestation.id}; " <>
            "assignment=#{assignment.id} proof=external_destroyed state=#{assignment.state}. " <>
            "Ordinary runtime reconciliation will settle the Effect."
        )

      {:error, reason} ->
        Mix.raise("Termination attestation refused: #{inspect(reason)}")
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
end
