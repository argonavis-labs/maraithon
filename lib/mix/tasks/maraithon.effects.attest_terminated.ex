defmodule Mix.Tasks.Maraithon.Effects.AttestTerminated do
  use Mix.Task

  alias Maraithon.Effects.Cancellation
  alias Maraithon.Effects.Effect
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
  task incarnation cannot still execute. The task starts only Repo dependencies,
  records an immutable attestation, and retries conservative cancellation
  settlement. It never claims to know the provider outcome.
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

    identity = %{
      effect_id: required!(opts, :effect_id),
      claim_token: required!(opts, :claim_token),
      owner_node: required!(opts, :owner_node),
      supervisor_id: required!(opts, :supervisor_id),
      task_id: required!(opts, :task_id)
    }

    result =
      case Ecto.Migrator.with_repo(Repo, fn _repo ->
             with {:ok, attestation} <-
                    TerminationAttestations.record(
                      identity,
                      required!(opts, :evidence_id),
                      required!(opts, :attested_by),
                      opts[:confirm]
                    ),
                  %Effect{agent_id: agent_id} <- Repo.get(Effect, attestation.effect_id),
                  settlement <- Cancellation.reconcile_agent(agent_id, 100) do
               {:ok, attestation, settlement}
             else
               nil -> {:error, :effect_not_found}
               {:error, _reason} = error -> error
             end
           end) do
        {:ok, task_result, _started_apps} -> task_result
        {:error, reason} -> {:error, {:repository_start_failed, reason}}
      end

    case result do
      {:ok, attestation, {:ok, summary}} ->
        Mix.shell().info(
          "Recorded termination attestation #{attestation.id}; " <>
            "settled=#{summary.claims_settled} unresolved=#{length(summary.unresolved)}"
        )

      {:ok, _attestation, {:pending, summary}} ->
        Mix.raise(
          "Termination attestation recorded but cancellation remains pending: " <>
            inspect(summary.unresolved)
        )

      {:ok, _attestation, {:error, reason}} ->
        Mix.raise(
          "Termination attestation recorded but reconciliation failed: #{inspect(reason)}"
        )

      {:error, reason} ->
        Mix.raise("Termination attestation refused: #{inspect(reason)}")
    end
  end

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> Mix.raise("missing --#{key |> Atom.to_string() |> String.replace("_", "-")}")
    end
  end
end
