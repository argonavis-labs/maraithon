defmodule Maraithon.Delegations.Decision do
  @moduledoc "A bounded read-only model continuation with a separate scope review."
  alias Maraithon.{LLM, PromptBudget, Repo}
  alias Maraithon.AssistantChat.Execution

  alias Maraithon.Delegations.{
    Authority,
    Binding,
    Budget,
    Gates,
    Jobs,
    Ledger,
    PeopleContext,
    Policy,
    Scheduling,
    SchedulingLinks,
    Turn,
    Toolbox,
    Voice
  }

  alias Maraithon.Runtime.{BackgroundJob, DatabaseClock, PeriodicJobs}
  alias Maraithon.TelegramAssistant.{Continuation, Run}

  @opts [max_wall_clock_ms: 120_000, max_llm_turns: 3, max_tool_steps: 1]
  @prompt_version 5
  def prompt_version, do: @prompt_version

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

  # The validated turn and decision event were committed with the completed Run.
  # A retry only republishes its pending wake; it cannot reopen the model phase.
  defp resume(_job, %{turn: %{status: "validated"}, run: %{status: "completed"} = run}),
    do: {:ok, %{state: "decided", run_id: run.id}}

  defp resume(_job, %{run: %{result_summary: %{"state" => "waiting_capacity"}} = run}),
    do: {:ok, %{state: "waiting_capacity", run_id: run.id}}

  defp resume(job, context) do
    with {:ok, %{run: _} = context} <- prepare(job, context),
         {:ok, checkpoint, _profile, state} <- Continuation.load(context.run, attrs(context)) do
      case checkpoint["phase"] do
        "ready" ->
          call(
            job,
            context,
            checkpoint,
            state,
            checkpoint["retry_stage"] || "compose",
            checkpoint["delegation_decision"]
          )

        "decision" ->
          continue(job, context, checkpoint, state)

        "model_entered" ->
          hold(job, :model_response_unknown)
      end
    else
      {:ok, :superseded} -> {:ok, :superseded}
      {:error, reason} -> read_error(job, reason)
    end
  end

  defp prepare(job, context) do
    if Continuation.present?(context.run) do
      {:ok, context}
    else
      with {:ok, scheduling} <- scheduling(context) do
        Jobs.transaction(job, fn current ->
          unless is_map(current.run.prompt_snapshot["sources"]), do: Repo.rollback(:source_gap)

          snapshot =
            current.run.prompt_snapshot
            |> Map.put("scheduling", scheduling)
            |> Map.put("fact_ledger", Ledger.snapshot(current))
            |> Voice.freeze(job.user_id, current.grant.data["scope"])
            |> PeopleContext.freeze(job.user_id, current.grant.data["scope"])

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

  defp scheduling(%{delegation: %{kind: "scheduling"} = d} = context),
    do: find_times(context, d.data["offered_scheduling_request"])

  defp scheduling(_), do: {:ok, %{}}

  defp find_times(context, request) do
    now = DateTime.utc_now()

    with {:ok, opts} <-
           if(is_nil(request),
             do: {:ok, %{window: {now, DateTime.add(now, 14, :day)}}},
             else: Scheduling.request_options(request)
           ),
         {:ok, scheduling} <-
           Scheduling.propose_slots(
             context.delegation.user_id,
             Map.put(opts, :default_account_id, context.grant.data["scope"]["source_account_id"])
           ) do
      {:ok,
       scheduling
       |> Map.put("request", request)
       |> Map.put(
         "links",
         SchedulingLinks.snapshot(context, scheduling["coverage"]["duration_min"])
       )}
    end
  end

  defp continue(job, context, checkpoint, state) do
    response = checkpoint["response"]
    decision = response["decision"] || checkpoint["delegation_decision"]

    with :ok <- read_phase(response["stage"], decision),
         {:ok, context} <- recall(job, context, decision),
         {:ok, decision} <-
           if(Policy.read_request?(decision),
             do: {:ok, decision},
             else: Policy.validate(context, decision)
           ) do
      case {response["stage"], decision["kind"]} do
        {"compose", kind} when kind in ~w(read_evidence read_history find_times) ->
          call(job, context, checkpoint, state, "researched", nil)

        {stage, _} when stage in ~w(compose researched repair) ->
          call(job, context, checkpoint, state, "policy", decision)

        {"policy", _} ->
          if Policy.approved?(decision, response["verdict"]),
            do: publish(job, decision, response["verdict"]),
            else: hold(job, :policy_review_required)

        _ ->
          hold(job, :invalid_execution_checkpoint)
      end
    else
      {:ok, :superseded} ->
        {:ok, :superseded}

      {:error, reason}
      when reason in [:invalid_message, :unverified_slot_wording, :invalid_question] ->
        if response["stage"] == "compose" do
          call(job, context, checkpoint, state, "repair", decision)
        else
          hold(job, reason)
        end

      {:error, reason} ->
        read_error(job, reason)
    end
  end

  defp read_error(job, reason) do
    case PeriodicJobs.retry_after_seconds_for(reason) do
      {:ok, seconds} -> Jobs.provider_wait(job, seconds, reason)
      :none -> hold(job, reason)
    end
  end

  defp read_phase(stage, %{"kind" => kind} = decision)
       when kind in ~w(read_evidence read_history find_times) do
    if stage == "compose" and Policy.read_request?(decision) do
      :ok
    else
      {:error,
       if(kind == "find_times", do: :invalid_scheduling_request, else: :invalid_evidence_request)}
    end
  end

  defp read_phase(_, _), do: :ok

  defp recall(job, context, decision) do
    with {:ok, recalled, history} <- read_sources(context, decision),
         {:ok, scheduling} <- requested_scheduling(context, decision) do
      if recalled == (context.run.prompt_snapshot["recalled_sources"] || []) and
           scheduling == context.run.prompt_snapshot["scheduling"] and
           history == context.run.prompt_snapshot["history_read"] do
        {:ok, context}
      else
        Jobs.transaction(job, fn current ->
          snapshot =
            Map.merge(current.run.prompt_snapshot, %{
              "recalled_sources" => recalled,
              "history_read" => history,
              "scheduling" => scheduling
            })

          run =
            current.run
            |> Run.changeset(%{prompt_snapshot: snapshot})
            |> Repo.update!()

          %{current | run: run}
        end)
      end
    end
  end

  defp read_sources(context, %{"kind" => "read_history"} = decision),
    do: Toolbox.history(context, decision)

  defp read_sources(context, decision) do
    with {:ok, recalled} <- Toolbox.read(context, decision),
         do: {:ok, recalled, context.run.prompt_snapshot["history_read"]}
  end

  defp requested_scheduling(context, %{"kind" => "find_times"} = decision) do
    request = Map.take(decision, Scheduling.request_fields())
    saved = context.run.prompt_snapshot["scheduling"] || %{}

    cond do
      context.delegation.kind != "scheduling" ->
        {:error, :scheduling_not_granted}

      saved["request"] == request ->
        {:ok, saved}

      true ->
        find_times(context, request)
    end
  end

  defp requested_scheduling(context, _), do: {:ok, context.run.prompt_snapshot["scheduling"]}

  defp call(job, context, checkpoint, state, stage, decision) do
    with true <- LLM.provider_name() == "openrouter",
         true <- Gates.scope_enabled?(context.delegation, context.grant),
         remaining when remaining > 1_000 <- Continuation.remaining_ms(checkpoint),
         messages = messages(context, stage, decision),
         true <- PromptBudget.encoded_bytes(messages) <= 64_000,
         {:ok, quote} <- Budget.quote(context.turn.model) do
      params = %{
        "messages" => messages,
        "model" => quote["model"],
        "_expected_model" => quote["model"],
        "provider" => quote["provider"],
        "max_tokens" => quote["max_tokens"],
        "response_format" => %{"type" => "json_object"},
        "temperature" => 0.2,
        "reasoning_effort" => "low",
        "timeout_ms" => min(remaining, 60_000)
      }

      result =
        LLM.complete_with_admission(params, fn request ->
          case enter(job, context, checkpoint, state, stage, decision, quote) do
            {:ok, {next_checkpoint, next_state}} ->
              {:entered, next_checkpoint, next_state, request.()}

            other ->
              other
          end
        end)

      case result do
        {:entered, next_checkpoint, next_state, {:ok, response}} ->
          save_response(job, context, next_checkpoint, next_state, stage, decision, response)

        {:entered, _, _, {:error, {:rate_limited, delay}}} ->
          # The provider returned a definite rejection. Retry from fresh sources
          # after its cooldown; retain the reservation without a billing receipt.
          capacity(job, :rate_limited, delay)

        {:entered, _, _, {:error, reason}} ->
          hold(job, reason)

        {:error, {reason, delay}} when reason in [:rate_limited, :llm_busy] ->
          capacity(job, reason, delay)

        {:error, reason} ->
          call_error(job, reason)

        {:ok, :superseded} ->
          {:ok, :superseded}
      end
    else
      false ->
        hold(job, :decision_unavailable)

      {:error, reason} ->
        call_error(job, reason)

      _ ->
        hold(job, :decision_deadline_reached)
    end
  end

  defp messages(context, "repair", decision), do: Policy.repair_messages(context, decision)

  defp messages(context, "researched", _) do
    Policy.messages(context, nil) ++
      [
        %{
          "role" => "user",
          "content" =>
            "The requested evidence is in last_messages or older_messages; history_read describes any bounded history selection, and calendar results are in available_slots. The read step is used. Return a decision, not another read request. Save supported task-relevant facts with their source IDs."
        }
      ]
  end

  defp messages(context, _, decision), do: Policy.messages(context, decision)

  defp call_error(job, reason)
       when reason in [
              :delegation_cost_limit,
              :user_cost_limit,
              :model_call_limit,
              :account_cost_hold
            ],
       do: capacity(job, reason)

  defp call_error(job, reason), do: hold(job, reason)

  defp enter(job, context, checkpoint, state, stage, decision, quote) do
    Jobs.transaction(job, fn current ->
      unless Gates.scope_enabled?(current.delegation, current.grant),
        do: Repo.rollback(:sends_disabled)

      if Continuation.remaining_ms(checkpoint) <= 1_000,
        do: Repo.rollback(:decision_deadline_reached)

      case Budget.reserve!(current, stage, quote) do
        :ok ->
          next_state = %{state | llm_turns: state.llm_turns + 1, sequence: state.sequence + 2}

          checkpoint =
            checkpoint
            |> Map.delete("retry_stage")
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
                "decision" =>
                  if(stage in ~w(compose researched repair), do: value, else: decision),
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
      with {:ok, _} <- Policy.validate(current, decision),
           {:ok, ledger} <- Ledger.merge(current, decision, DatabaseClock.now!()) do
        current.delegation
        |> Maraithon.Delegations.Delegation.changeset(%{
          data: Map.put(current.delegation.data, "ledger", ledger)
        })
        |> Repo.update!()

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

        # The reviewed decision already lives on the turn. The wake needs only
        # its kind and user question, not another copy of its body and facts.
        Jobs.result!(current, "decision", Map.take(decision, ~w(kind question)))
        %{state: "decided", run_id: current.run.id}
      else
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
            Policy.review_explanation(Continuation.response(context.run)) ||
              "I need your review before taking the next step in this conversation."

          :invalid_scheduling_request ->
            "I couldn't resolve the requested meeting length and dates. Please clarify those details."

          :booking_receipt_required ->
            "The meeting has not been confirmed on your calendar. Please review the scheduling details."

          reason
          when reason in [
                 :invalid_evidence_request,
                 :unverified_evidence,
                 :recalled_evidence_changed
               ] ->
            "I couldn't verify the older message needed for this reply. Please add the relevant details to this task."

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

      Jobs.result!(context, "failure", %{
        "question" => question,
        "failure_code" => Maraithon.Redaction.error_class(reason)
      })

      %{state: "needs_user", run_id: context.run.id}
    end)
  end

  defp capacity(job, reason, delay \\ nil) do
    Jobs.transaction(job, fn context ->
      context.run
      |> Run.changeset(%{
        status: "degraded",
        error: Atom.to_string(reason),
        finished_at: DatabaseClock.now!(),
        result_summary: %{"state" => "waiting_capacity"}
      })
      |> Repo.update!()

      Jobs.result!(context, "capacity_hold", %{
        "reason" => Atom.to_string(reason),
        "retry_after_ms" => delay
      })

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
