defmodule Maraithon.Delegations.EvaluationMemory do
  @moduledoc "Read-only recall of saved facts from one completed controlled information eval."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Delegations.{Delegation, Evaluation, Grant, Ledger, Policy, Toolbox, Turn}
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.TelegramAssistant.Run

  def run(id) do
    spec = Evaluation.scenarios()
    user = spec["owner"]["email"]

    with {:ok, id} <- Ecto.UUID.cast(id),
         %BackgroundJob{status: "completed"} = job <-
           Repo.get_by(BackgroundJob, id: id, user_id: user, job_type: "delegation_eval")
           |> BackgroundJob.hydrate_payloads(),
         %{"phase" => "passed", "delegation_id" => delegation_id} <- job.result,
         "information_reply" <- get_in(job.payload, ["scenario", "id"]),
         %Delegation{provider: "gmail", state: "completed"} = d <-
           Delegations.get(user, delegation_id),
         %Turn{} = turn <-
           Repo.one(
             from t in Turn,
               where: t.user_id == ^user and t.delegation_id == ^d.id,
               order_by: [desc: t.seq],
               limit: 1
           )
           |> Turn.hydrate(),
         %Grant{} = grant <-
           Repo.get_by(Grant, user_id: user, delegation_id: d.id, version: turn.grant_version)
           |> Grant.hydrate(),
         %Run{} = run <-
           Repo.get_by(Run, id: turn.run_id, user_id: user) |> Run.hydrate_payloads() do
      # Remove only the in-memory prompt cache so the production toolbox must
      # retrieve the cited message. No turn, run, grant or ledger is changed.
      snapshot = %{
        "fact_ledger" => d.data["ledger"] || %{},
        "sources" => %{"account_id" => d.connected_account_id, "messages" => []},
        "recalled_sources" => []
      }

      context = %{
        delegation: d,
        turn: turn,
        grant: grant,
        run: %{run | prompt_snapshot: snapshot}
      }

      inspect_memory(context, job, spec)
    else
      _ -> %{"phase" => "unavailable", "reason" => "completed_information_eval_required"}
    end
  end

  defp inspect_memory(context, job, spec) do
    facts = Ledger.facts(context)
    refs = Ledger.references(context)
    ids = refs |> Enum.map(& &1["message_id"]) |> Enum.uniq()
    expected = get_in(job.payload, ["scenario", "expect", "answer_contains"])

    recalled =
      if length(refs) in 1..6,
        do: Toolbox.read(context, %{"evidence" => ids}),
        else: {:error, :bounded_saved_evidence_required}

    checks = %{
      "expected_fact_saved" =>
        is_binary(expected) and expected != "" and
          Enum.any?(facts, fn {_key, fact} ->
            String.contains?(String.downcase(fact["text"]), String.downcase(expected)) and
              Enum.any?(fact["evidence"], &(&1["message_id"] == job.result["reply_message_id"]))
          end),
      "completion_independently_reviewed" =>
        context.turn.data["decision"]["kind"] == "complete" and
          Policy.approved?(context.turn.data["decision"], context.turn.data["policy_review"]),
      "configured_model_used" => context.turn.model == spec["model"],
      "cited_sources_recalled" =>
        match?({:ok, items} when length(items) == length(refs), recalled),
      "ledger_within_limit" => Ledger.valid_storage?(Ledger.snapshot(context))
    }

    %{
      "phase" =>
        if(Enum.all?(checks, fn {_, passed} -> passed end), do: "passed", else: "failed"),
      "job_id" => job.id,
      "delegation_id" => context.delegation.id,
      "turn_id" => context.turn.id,
      "actor" => job.payload["actor"],
      "fact_count" => map_size(facts),
      "reference_count" => length(refs),
      "checks" => checks,
      "recall_error" =>
        case recalled do
          {:ok, _} -> nil
          {:error, reason} -> Maraithon.Redaction.error_class(reason)
        end,
      "model_calls" => 0,
      "messages_sent" => 0,
      "events_created" => 0,
      "conversation_writes" => 0,
      "prompt_cache_cleared_in_memory" => true
    }
  end
end
