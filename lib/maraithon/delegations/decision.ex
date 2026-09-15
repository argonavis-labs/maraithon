defmodule Maraithon.Delegations.Decision do
  @moduledoc "A bounded read-only model continuation with a separate scope review."
  alias Maraithon.{LLM, Repo}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.Delegations.{Authority, Binding, Budget, Gates, Jobs, Policy, Scheduling, Turn}
  alias Maraithon.Runtime.{BackgroundJob, DatabaseClock}
  alias Maraithon.TelegramAssistant.{Continuation, Run}

  @opts [max_wall_clock_ms: 120_000, max_llm_turns: 3, max_tool_steps: 1]

  def execute(%BackgroundJob{job_type: "delegation_decide"} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    Execution.with_authority(job, fn ->
      LLM.UserModel.with_user(job.user_id, fn ->
        result = with {:ok, context} <- Jobs.transaction(job, & &1), do: resume(job, context)
        Jobs.finish(result, job)
      end)
    end)
  end

  defp resume(_job, :superseded), do: {:ok, :superseded}

  defp resume(job, context) do
    with {:ok, %{run: _} = context} <- prepare(job, context),
         {:ok, checkpoint, _profile, state} <- Continuation.load(context.run, attrs(context)) do
      case checkpoint["phase"] do
        "ready" -> compose(job, context, checkpoint, state)
        "decision" -> continue(job, context, checkpoint, state)
        "model_entered" -> hold(job, :model_response_unknown)
      end
    else
      {:ok, :superseded} -> {:ok, :superseded}
      {:error, reason} -> hold(job, reason)
    end
  end

  defp prepare(job, context) do
    if Continuation.present?(context.run) do
      {:ok, context}
    else
      with {:ok, scheduling} <- scheduling(context) do
        Jobs.transaction(job, fn current ->
          unless is_map(current.run.prompt_snapshot["sources"]), do: Repo.rollback(:source_gap)
          snapshot = Map.put(current.run.prompt_snapshot, "scheduling", scheduling)

          run =
            current.run
            |> Run.changeset(%{status: "running", prompt_snapshot: snapshot})
            |> Repo.update!()

          profile = %{tier: :chat, model: run.model_name, llm_opts: @opts}

          case Continuation.start(run, attrs(current), profile, @opts) do
            {:ok, _} -> %{current | run: Repo.get!(Run, run.id) |> Run.hydrate_payloads()}
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    end
  end

  defp scheduling(%{delegation: %{kind: "scheduling", user_id: user_id}}) do
    now = DateTime.utc_now()
    Scheduling.propose_slots(user_id, %{window: {now, DateTime.add(now, 14, :day)}})
  end

  defp scheduling(_), do: {:ok, %{}}

  defp compose(job, context, checkpoint, state),
    do: call(job, context, checkpoint, state, "compose", nil)

  defp continue(job, context, checkpoint, state) do
    response = checkpoint["response"]
    decision = response["decision"] || checkpoint["delegation_decision"]

    with {:ok, decision} <- Policy.validate(context, decision) do
      case response["stage"] do
        "compose" ->
          call(job, context, checkpoint, state, "policy", decision)

        "policy" ->
          if Policy.approved?(decision, response["verdict"]),
            do: publish(job, decision, response["verdict"]),
            else: hold(job, :policy_review_required)

        _ ->
          hold(job, :invalid_execution_checkpoint)
      end
    else
      {:error, reason} -> hold(job, reason)
    end
  end

  defp call(job, context, checkpoint, state, stage, decision) do
    with true <- LLM.provider_name() == "openrouter",
         true <- Gates.sends_enabled?(job.user_id, context.delegation.provider),
         remaining when remaining > 1_000 <- Continuation.remaining_ms(checkpoint),
         messages = Policy.messages(context, decision),
         true <- byte_size(Jason.encode!(messages)) <= 32_000,
         {:ok, quote} <- Budget.quote(context.turn.model),
         {:ok, entered} <- enter(job, context, checkpoint, state, stage, decision, quote) do
      if entered == :superseded do
        {:ok, :superseded}
      else
        {next_checkpoint, next_state} = entered

        params = %{
          "messages" => messages,
          "model" => quote["model"],
          "_expected_model" => quote["model"],
          "provider" => quote["provider"],
          "max_tokens" => quote["max_tokens"],
          "response_format" => %{"type" => "json_object"},
          "temperature" => 0.2,
          "reasoning_effort" => "low",
          "timeout_ms" => min(Continuation.remaining_ms(next_checkpoint), 60_000)
        }

        case LLM.complete(params) do
          {:ok, result} ->
            save_response(job, context, next_checkpoint, next_state, stage, decision, result)

          {:error, reason} ->
            hold(job, reason)
        end
      end
    else
      false ->
        hold(job, :decision_unavailable)

      {:error, reason}
      when reason in [
             :delegation_cost_limit,
             :user_cost_limit,
             :model_call_limit,
             :account_cost_hold
           ] ->
        capacity(job, reason)

      {:error, reason} ->
        hold(job, reason)

      _ ->
        hold(job, :decision_deadline_reached)
    end
  end

  defp enter(job, context, checkpoint, state, stage, decision, quote) do
    Jobs.transaction(job, fn current ->
      unless Gates.sends_enabled?(job.user_id, current.delegation.provider),
        do: Repo.rollback(:sends_disabled)

      if Continuation.remaining_ms(checkpoint) <= 1_000,
        do: Repo.rollback(:decision_deadline_reached)

      case Budget.reserve!(current, stage, quote) do
        :ok ->
          next_state = %{state | llm_turns: state.llm_turns + 1, sequence: state.sequence + 2}

          checkpoint =
            checkpoint
            |> Map.put("delegation_stage", stage)
            |> Map.put("delegation_decision", decision)

          case Continuation.save(context.run, checkpoint, "model_entered", next_state) do
            {:ok, saved} -> {saved, next_state}
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp save_response(job, context, checkpoint, state, stage, decision, result) do
    parsed = Jason.decode(result.content)

    saved =
      Budget.settle(job, stage, result, fn current ->
        cond do
          not Authority.current?(current, job.payload) ->
            :superseded

          result.model != current.turn.model ->
            {:error, :model_changed}

          true ->
            with {:ok, value} when is_map(value) <- parsed do
              response = %{
                "status" => "final",
                "stage" => stage,
                "tool_calls" => [],
                "decision" => if(stage == "compose", do: value, else: decision),
                "verdict" => if(stage == "policy", do: value)
              }

              Continuation.save(current.run, checkpoint, "decision", state, response)
            else
              _ -> {:error, :invalid_model_decision}
            end
        end
      end)

    case saved do
      {:ok, {:ok, checkpoint}} -> continue(job, context, checkpoint, state)
      {:ok, :superseded} -> {:ok, :superseded}
      {:ok, {:error, reason}} -> hold(job, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish(job, decision, verdict) do
    Jobs.transaction(job, fn current ->
      case Policy.validate(current, decision) do
        {:ok, _} ->
          current.turn
          |> Turn.changeset(%{
            status: "validated",
            data:
              Map.merge(
                current.turn.data,
                %{"decision" => decision, "policy_review" => verdict}
              )
          })
          |> Repo.update!()

          current.run
          |> Run.changeset(%{status: "completed", finished_at: DatabaseClock.now!()})
          |> Repo.update!()

          Jobs.result!(current, "decision", decision)
          %{state: "decided", run_id: current.run.id}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp hold(job, reason) do
    Jobs.transaction(job, fn context ->
      question =
        case reason do
          :model_response_unknown ->
            "The last decision was interrupted. Please review this conversation before I continue."

          :policy_review_required ->
            "I need your review before taking the next step in this conversation."

          _ ->
            "I couldn't verify a safe next step. Please review this conversation."
        end

      context.run
      |> Run.changeset(%{
        status: "degraded",
        error: Maraithon.Redaction.error_class(reason),
        finished_at: DatabaseClock.now!()
      })
      |> Repo.update!()

      Jobs.result!(context, "failure", %{"question" => question})
      %{state: "needs_user", run_id: context.run.id}
    end)
  end

  defp capacity(job, reason) do
    Jobs.transaction(job, fn context ->
      Jobs.result!(context, "capacity_hold", %{"reason" => Atom.to_string(reason)})
      %{state: "waiting_capacity", run_id: context.run.id}
    end)
  end

  defp attrs(context),
    do: %{
      durable_processing: true,
      surface: "delegation",
      user_id: context.run.user_id,
      source_message_id: context.turn.data["event_id"],
      delegation_binding: context.run.prompt_snapshot[Binding.key()]
    }
end
