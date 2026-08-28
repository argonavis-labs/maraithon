defmodule Mix.Tasks.Maraithon.Tasks.AttestTerminated do
  use Mix.Task

  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.TaskTerminationAttestations

  @shortdoc "Attests that one exact background-job Task assignment can no longer run"

  @moduledoc """
  Records separately authorized, identity-bound physical-termination proof for
  a coordinated background-job Task assignment:

      mix maraithon.tasks.attest_terminated \\
        --assignment-id UUID --job-id UUID --claim-token UUID \\
        --node-incarnation-id UUID --supervisor-id UUID --task-id UUID \\
        --evidence-id REFERENCE --attested-by OPERATOR \\
        --confirm PHYSICAL_TASK_TERMINATED

  Use only after external infrastructure evidence proves that the node
  incarnation which owned the assignment cannot still execute (for example a
  verified Cloud Run revision deletion). Production requires
  `MARAITHON_INCIDENT_DATABASE_URL` using the canonical incident-operator role
  and independently rebuilt verified TLS. The task starts only Repo
  dependencies and atomically records the exact `external_destroyed` Task
  proof. Ordinary runtime reconciliation later settles the job as
  `provider_outcome_ambiguous` and releases its partition; this command never
  claims a provider outcome.

  Every identity value must match the stored `runtime_task_assignments` row
  exactly (`id`, `work_id`, `claim_token`, `node_incarnation_id`,
  `supervisor_id`, `local_task_id`).
  """

  @switches [
    assignment_id: :string,
    job_id: :string,
    claim_token: :string,
    node_incarnation_id: :string,
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
      Mix.raise("unexpected task termination-attestation arguments")
    end

    configure_operator_storage!("MARAITHON_INCIDENT_DATABASE_URL")

    identity = %{
      assignment_id: required!(opts, :assignment_id),
      job_id: required!(opts, :job_id),
      claim_token: required!(opts, :claim_token),
      node_incarnation_id: required!(opts, :node_incarnation_id),
      supervisor_id: required!(opts, :supervisor_id),
      task_id: required!(opts, :task_id)
    }

    result =
      case Ecto.Migrator.with_repo(Repo, fn _repo ->
             TaskTerminationAttestations.record(
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
      {:ok, %{task_assignment: assignment}} ->
        Mix.shell().info(
          "Recorded external termination proof for assignment=#{assignment.id} " <>
            "state=#{assignment.state}. Ordinary runtime reconciliation will settle the job " <>
            "and release partition #{assignment.partition_id}."
        )

      {:error, reason} ->
        Mix.raise("Task termination attestation refused: #{inspect(reason)}")
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
