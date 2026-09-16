defmodule Maraithon.Delegations.EvaluationRunner do
  @moduledoc "Bounded Kent-to-Kent provider evals, driven by durable background job checkpoints."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo, TelegramAssistant}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.Connectors.{Gmail, GoogleCalendar}
  alias Maraithon.Delegations.{
    Evaluation,
    EvaluationCanary,
    EvaluationRecovery,
    Gates,
    Ingress,
    Policy,
    Turn
  }
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs, JobAuthority}
  alias Maraithon.TelegramAssistant.{ActionReconciliation, PreparedAction, Run}
  alias Maraithon.Todos.{Todo, Workflow}
  alias Maraithon.Tools.GmailApiHelpers

  @user "kent@runner.now"
  @counterparty "kent.fenwick@gmail.com"
  @job_type "delegation_eval"

  def start(scenario_id, actor \\ "as_user")

  def start(scenario_id, actor)
      when scenario_id in ~w(information_reply schedule_and_book requested_scheduling accepted_slot_becomes_busy durable_memory) and
             actor in ~w(as_user as_assistant) do
    with true <- Gates.sends_enabled?(@user, "gmail") and eval_only?(),
         :ok <- budget_preflight(),
         %{} = scenario <-
           Enum.find(Evaluation.scenarios()["scenarios"], &(&1["id"] == scenario_id)),
         %{"accounts_ready" => true, "model_ready" => true} = report <-
           Evaluation.preflight(actor),
         %{"account_id" => sender_id} <-
           Enum.find(report["accounts"], &(&1["email"] == @counterparty)),
         {:ok, %{"email" => @counterparty} = sender_identity} <-
           Maraithon.AssistantIdentities.gmail_snapshot(@user, "as_user", sender_id),
         {:ok, scheduled_at, deadline} <-
           Evaluation.window(DateTime.utc_now(), Maraithon.Delegations.Preferences.get(@user)) do
      accounts = Map.new(report["accounts"], &{&1["email"], &1["account_id"]})
      id = Ecto.UUID.generate()

      deadline =
        if scenario_id == "durable_memory",
          do: DateTime.add(scheduled_at, 3, :day),
          else: deadline

      payload = %{
        "actor" => actor,
        "scenario" => scenario,
        "sender_account_id" => accounts[@counterparty],
        "sender_identity" => sender_identity,
        "owner_account_id" => accounts[@user],
        "deadline" => DateTime.to_iso8601(deadline),
        "subject" => "[Maraithon eval] #{scenario_id} #{id}"
      }

      Repo.transaction(fn ->
        Maraithon.PrivacyErasure.WriteFence.lock_user_writable!(@user)

        {:ok, job} =
          BackgroundJobs.enqueue(@job_type, %{
            user_id: @user,
            queue: "runtime_provider_account",
            partition_key: "delegation-eval:#{@user}",
            rate_limit_key: "google",
            max_attempts: 3,
            scheduled_at: scheduled_at,
            dedupe_key:
              if(scenario_id == "durable_memory",
                do: "delegation-canary:#{@user}:#{actor}",
                else: "delegation-eval:#{id}"
              ),
            payload: payload
          })

        %{
          job_id: job.id,
          scenario: scenario_id,
          phase: job.result["phase"] || "queued",
          scheduled_at: job.scheduled_at
        }
      end)
    else
      {:error, :account_cost_hold} = error -> error
      {:error, :eval_work_window_too_short} = error -> error
      %{"phase" => "preflight"} = report -> {:error, {:eval_preflight_required, report}}
      _ -> {:error, :eval_preflight_required}
    end
  end

  def start(_, _), do: {:error, :unsupported_eval_scenario}

  defp budget_preflight do
    if Maraithon.Delegations.Budget.account_budget_ok?(DateTime.utc_now()),
      do: :ok,
      else: {:error, :account_cost_hold}
  end

  def execute(%BackgroundJob{job_type: @job_type, user_id: @user} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    Execution.with_authority(job, fn ->
      with {:ok, :ok} <- JobAuthority.transaction(job, fn -> :ok end),
           true <- eval_only?() and Gates.sends_enabled?(@user, "gmail"),
           {:ok, deadline, _} <- DateTime.from_iso8601(job.payload["deadline"]),
           :gt <- DateTime.compare(deadline, DateTime.utc_now()) do
        state = job.result || %{}

        case step(job, state) do
          {:wait, next} ->
            {:ok, next, {:reschedule_in, 30_000}}

          {:wait_until, next, at} ->
            {:ok, next, {:reschedule_at, at}}

          {:done, next} ->
            {:ok, next}

          {:error, reason} ->
            EvaluationRecovery.wait(state, reason) || fail(job, state, reason)
        end
      else
        _ -> fail(job, job.result || %{}, :eval_stopped)
      end
    end)
  end

  def status(id \\ nil) do
    query =
      from j in BackgroundJob,
        where: j.job_type == @job_type and j.user_id == @user,
        order_by: [desc: j.inserted_at],
        limit: 5

    query = if id in [nil, ""], do: query, else: where(query, [j], j.id == ^id)

    Repo.all(query)
    |> Enum.map(fn row ->
      job = BackgroundJob.hydrate_payloads(row)

      %{
        job_id: job.id,
        status: job.status,
        scheduled_at: job.scheduled_at,
        result: job.result,
        error: job.last_error,
        observation: EvaluationCanary.observation(job)
      }
      |> then(fn report ->
        if id in [nil, ""], do: report, else: Map.put(report, :details, details(job))
      end)
    end)
  end

  defp details(job) do
    if d = Delegations.get(@user, (job.result || %{})["delegation_id"]) do
      rows =
        Repo.all(
          from t in Turn,
            where: t.user_id == @user and t.delegation_id == ^d.id,
            order_by: [desc: t.seq],
            limit: 11
        )

      turns = rows |> Enum.take(10) |> Enum.map(&Turn.hydrate/1)
      chat = "delegation-eval:#{job.id}"

      %{
        state: d.state,
        kind: d.kind,
        source_revision: d.source_revision,
        last_action_id: d.last_action_id,
        older_turns_omitted: length(rows) > 10,
        model_usage: Maraithon.Delegations.Reports.model_usage(turns),
        decisions:
          Enum.map(turns, fn turn ->
            decision = turn.data["decision"] || %{}
            kind = decision["kind"]

            %{
              turn_id: turn.id,
              kind: if(kind in ~w(send propose_times book complete wait needs_user), do: kind),
              reviewed: Policy.approved?(decision, turn.data["policy_review"]),
              evidence_count: length(decision["evidence"] || [])
            }
          end),
        actions:
          Repo.all(
            from a in PreparedAction,
              where: a.user_id == @user and (a.delegation_id == ^d.id or a.chat_id == ^chat),
              order_by: [desc: a.inserted_at],
              limit: 12,
              select: map(a, [:id, :action_type, :status, :delegation_id, :inserted_at])
          ),
        trace: Maraithon.Delegations.Audit.page(@user, d.id)
      }
    end
  end

  defp step(job, %{"phase" => "calendar_verified", "delegation_id" => id} = state) do
    d = Delegations.get(@user, id)

    action =
      Repo.get!(PreparedAction, state["verified_booked_action_id"])
      |> PreparedAction.hydrate_payload()

    with :ok <- cleanup_calendar(job, d, action), :ok <- cleanup_busy(job, d) do
      {:done, Map.merge(state, %{"phase" => "passed", "calendar_cleanup" => "completed"})}
    else
      :wait -> {:wait, state}
      error -> error
    end
  end

  defp step(job, %{"delegation_id" => id} = state) do
    d = Delegations.get(@user, id)

    cond do
      is_nil(d) ->
        {:error, :eval_delegation_removed}

      d.state == "completed" ->
        verify(job, state, d)

      d.state == "waiting_capacity" and d.data["hold_reason"] in ~w(rate_limited llm_busy) ->
        {:wait, Map.put(state, "phase", "waiting_for_model_capacity")}

      d.state in ~w(needs_user paused stopped expired waiting_capacity) ->
        {:error, {:conversation_held, d.state}}

      d.state == "waiting_reply" and reply_due?(job, state, d) ->
        case EvaluationCanary.before_reply(job, state, d, reply_count(state)) do
          {:ready, next} -> reply(job, next, d)
          other -> other
        end

      true ->
        {:wait, Map.put(state, "phase", "waiting_for_agent")}
    end
  end

  defp step(job, state) do
    with {:ok, action} <-
           action(job, "initial", %{"body" => job.payload["scenario"]["initial_email"]}),
         {:ok, sent} <- deliver(action),
         {:ok, message} <- inbox_message(job, sent) do
      delegate(job, state, message)
    else
      :wait -> {:wait, Map.put(state, "phase", "waiting_for_initial_email")}
      error -> error
    end
  end

  defp delegate(job, state, message) do
    key = "delegation-eval:#{job.id}"

    with {:ok, todo} <-
           JobAuthority.transaction(job, fn ->
             Repo.get_by(Todo, user_id: @user, dedupe_key: key) ||
               Repo.insert!(%Todo{
                 user_id: @user,
                 owner_user_id: @user,
                 title: job.payload["subject"],
                 summary: job.payload["scenario"]["outcome"],
                 source: "gmail",
                 source_account_id: job.payload["owner_account_id"],
                 source_item_id: message.message_id,
                 next_action:
                   if(job.payload["scenario"]["kind"] == "scheduling",
                     do: "Offer a few available meeting times.",
                     else: "Ask Kent for the test project colour."
                   ),
                 dedupe_key: key
               })
           end),
         {:ok, d} <- ensure_delegation(job, todo) do
      {:wait,
       Map.merge(state, %{
         "phase" => "waiting_for_agent",
         "delegation_id" => d.id,
         "todo_id" => todo.id
       })}
    end
  end

  defp ensure_delegation(job, todo) do
    case Delegations.for_todo(@user, todo.id) do
      nil ->
        attrs = %{
          "actor" => job.payload["actor"] || "as_user",
          "kind" => job.payload["scenario"]["kind"],
          "outcome" => job.payload["scenario"]["outcome"],
          "expected_revision" => Workflow.current(todo)["revision"],
          "request_id" => "eval:#{job.id}:delegate"
        }

        with {:ok, scope} <- Delegations.preview(@user, todo.id, attrs),
             do:
               Delegations.delegate(
                 @user,
                 todo.id,
                 Map.put(attrs, "scope_hash", scope["scope_hash"])
               )

      d ->
        {:ok, d}
    end
  end

  defp reply_due?(job, state, d) do
    count = reply_count(state)
    count < length(job.payload["scenario"]["counterparty_replies"]) and d.lifetime_sends > count
  end

  defp reply_count(state),
    do: state["reply_count"] || if(state["reply_action_id"], do: 1, else: 0)

  defp reply_key(0), do: "reply"
  defp reply_key(n), do: "reply#{n + 1}"

  defp reply(job, state, d) do
    count = reply_count(state)

    with %PreparedAction{status: "executed", action_type: "gmail_send"} = latest <-
           Repo.get_by(PreparedAction, id: d.last_action_id, delegation_id: d.id, user_id: @user)
           |> PreparedAction.hydrate_payload(),
         {:ok, parent} <- inbox_message(job, latest, job.payload["sender_account_id"]),
         :ok <- verify_received_identity(d, parent),
         :ok <- verify_received_offer(job, d, parent),
         :ok <- maybe_make_busy(job, d, count),
         {:ok, action} <-
           action(job, reply_key(count), %{
             "body" => Enum.at(job.payload["scenario"]["counterparty_replies"], count),
             "to" => d.data["identity"]["email"],
             "thread_id" => parent.thread_id,
             "reply_to_message_id" => parent.message_id
           }),
         {:ok, sent} <- deliver(action),
         {:ok, message} <- inbox_message(job, sent, d.connected_account_id),
         {:ok, :ok} <-
           JobAuthority.transaction(job, fn ->
             Ingress.gmail!(@user, d.connected_account_id, message)
           end) do
      Maraithon.Delegations.Outbox.publish_pending(@user)

      {:wait,
       Map.merge(state, %{
         "phase" => "waiting_for_completion",
         "reply_action_id" => action.id,
         "reply_count" => count + 1,
         "reply_message_id" => message.message_id,
         "reply_message_ids" =>
           Map.put(
             state["reply_message_ids"] || %{},
             Integer.to_string(count),
             message.message_id
           ),
         "sending_identity_verified" => true,
         "received_offer_verified" => d.kind == "scheduling"
       })}
    else
      nil -> {:wait, state}
      :wait -> {:wait, state}
      error -> error
    end
  end

  defp verify_received_identity(d, message) do
    identity = d.data["identity"]
    signature = String.trim(identity["signature"] || "")

    from? =
      Enum.any?(
        Gmail.message_participants(message),
        &(&1["role"] == "from" and &1["identifier"]["email"] == identity["email"])
      )

    name = identity["display_name"]

    name? =
      not is_binary(name) or name == "" or String.contains?(message.from || "", name) or
        String.contains?(message.from || "", Base.encode64(name))

    if from? and name? and "DRAFT" not in message.labels and
         String.ends_with?(String.trim(message.text_body || ""), signature),
       do: :ok,
       else: {:error, :received_identity_not_proven}
  end

  defp verify_received_offer(job, %{kind: "scheduling"} = d, message),
    do:
      Evaluation.verify_offer(
        job.payload["scenario"],
        d.data["offered_slots"],
        message.text_body,
        d.inserted_at,
        d.actor
      )

  defp verify_received_offer(_, _, _), do: :ok

  defp action(job, key, content, type \\ "gmail_send") do
    id = deterministic_id(job.id, key)

    JobAuthority.transaction(job, fn ->
      Repo.get(PreparedAction, id) |> PreparedAction.hydrate_payload() ||
        create_action!(job, id, content, type)
    end)
  end

  defp create_action!(job, id, content, type) do
    run_id = deterministic_id(job.id, "run")
    chat = "delegation-eval:#{job.id}"

    unless Repo.get(Run, run_id) do
      %Run{id: run_id}
      |> Run.changeset(%{
        user_id: @user,
        chat_id: chat,
        surface: "telegram",
        trigger_type: "inbound_message",
        status: "completed",
        model_provider: "none",
        model_name: "fixture",
        prompt_snapshot: %{"eval_job_id" => job.id},
        result_summary: %{},
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()
    end

    payload =
      if type == "gmail_send" do
        Map.merge(content, %{
          "user_id" => @user,
          "account_id" => job.payload["sender_account_id"],
          "from" => @counterparty,
          "from_name" => job.payload["sender_identity"]["display_name"],
          "body" =>
            Policy.email_body(%{"identity" => job.payload["sender_identity"]}, content["body"]),
          "html_body" =>
            Maraithon.Delegations.EmailBody.html(
              %{"identity" => job.payload["sender_identity"]},
              content["body"]
            ),
          "to" => Map.get(content, "to", @user),
          "cc" => "",
          "subject" => job.payload["subject"]
        })
      else
        content
        |> Map.put_new("account_id", job.payload["owner_account_id"])
        |> Map.put("user_id", @user)
      end

    %PreparedAction{id: id}
    |> PreparedAction.changeset(%{
      user_id: @user,
      run_id: run_id,
      chat_id: chat,
      surface: "telegram",
      action_type: type,
      target_type: if(type == "gmail_send", do: "email", else: "calendar"),
      payload: payload,
      preview_text: "Kent's authorised controlled conversation eval.",
      expires_at: DateTime.add(DateTime.utc_now(), 1, :hour)
    })
    |> Repo.insert!()
  end

  defp deliver(action) do
    case TelegramAssistant.confirm_and_execute(action, durable: false) do
      {:ok, sent, _} -> {:ok, sent}
      {:ok, sent, _, :already_executed} -> {:ok, sent}
      {:error, _, _, :manual_reconciliation} -> :wait
      {:error, _, :prepared_action_execution_in_progress} -> :wait
      _ -> {:error, :eval_send_failed}
    end
  end

  defp inbox_message(job, sent, account_id \\ nil) do
    account =
      Repo.get!(
        Maraithon.Accounts.ConnectedAccount,
        account_id || job.payload["owner_account_id"]
      )

    # A positive send receipt identifies the sender's exact message even when
    # Gmail replaces our RFC Message-ID. Never guess from subject or timestamp.
    with {:ok, sender_token} <-
           Maraithon.Connectors.GmailAccess.for_account(@user, sent.payload["account_id"]),
         {:ok, delivered} <-
           Gmail.fetch_message_content(
             sender_token,
             sent.payload["_maraithon_execution_result"]["message_id"],
             access_token: true
           ),
         true <- "SENT" in delivered.labels and is_binary(delivered.internet_message_id),
         query =
           URI.encode_query(%{
             q: "in:anywhere rfc822msgid:#{delivered.internet_message_id}",
             maxResults: 2
           }),
         {:ok, listing} <-
           GmailApiHelpers.get_for_account(@user, account.id, "/users/me/messages?#{query}"),
         ids = Enum.map(listing["messages"] || [], & &1["id"]),
         [id] <- ids,
         {:ok, token} <- Maraithon.Connectors.GmailAccess.for_account(@user, account.id),
         {:ok, message} <- Gmail.fetch_message_content(token, id, access_token: true) do
      {:ok, message}
    else
      [] -> :wait
      [_ | _] -> {:error, :ambiguous_eval_message}
      false -> {:error, :eval_sender_receipt_not_proven}
      error -> error
    end
  end

  defp maybe_make_busy(job, d, 0) do
    if job.payload["scenario"]["id"] == "accepted_slot_becomes_busy" do
      with [slot | _] <- d.data["offered_slots"],
           [account_id | _] <- d.data["offered_calendar_account_ids"],
           true <- account_id == job.payload["owner_account_id"],
           {:ok, action} <-
             action(
               job,
               "busy",
               Map.merge(slot, %{
                 "title" => "[Maraithon eval] Busy #{job.id}",
                 "todo_id" => d.todo_id,
                 "attendees" => [],
                 "description" => "Temporary conflict for the controlled scheduling eval."
               }),
               "calendar_create_event"
             ),
           {:ok, _} <- deliver(action) do
        :ok
      else
        :wait -> :wait
        {:error, _} = error -> error
        _ -> {:error, :eval_calendar_account_mismatch}
      end
    else
      :ok
    end
  end

  defp maybe_make_busy(_, _, _), do: :ok

  defp verify(job, state, d) do
    # Gmail search can lag the webhook that completed the conversation. Recover
    # the exact seeded reply identity before checking its source evidence.
    count = length(job.payload["scenario"]["counterparty_replies"])

    action =
      Repo.get(PreparedAction, deterministic_id(job.id, reply_key(count - 1)))
      |> PreparedAction.hydrate_payload()

    with %PreparedAction{status: "executed"} <- action,
         {:ok, message} <- inbox_message(job, action, d.connected_account_id) do
      next =
        Map.merge(state, %{
          "reply_count" => count,
          "reply_message_id" => message.message_id,
          "reply_message_ids" =>
            Map.put(state["reply_message_ids"] || %{}, to_string(count - 1), message.message_id),
          "accepted_slot" =>
            Enum.at(
              d.data["offered_slots"] || [],
              (job.payload["scenario"]["expect"]["accepted_slot"] || 1) - 1
            ),
          "offered_slots_count" => length(d.data["offered_slots"] || [])
        })

      verify_outcome(job, next, d)
    else
      :wait -> {:wait, Map.put(state, "phase", "waiting_for_reply_evidence")}
      {:error, _} = error -> error
      _ -> {:error, :eval_completion_without_reply}
    end
  end

  defp verify_outcome(job, state, d) do
    todo = Repo.get!(Todo, d.todo_id)
    turns =
      Repo.all(from t in Turn, where: t.delegation_id == ^d.id) |> Enum.map(&Turn.hydrate/1)
    evidence_ids = Enum.map(d.data["evidence"] || [], & &1["id"])

    common =
      Map.merge(Maraithon.Delegations.Reports.model_usage(turns), %{
        "model_calls" => Enum.sum(Enum.map(turns, & &1.model_calls)),
        "turns" => length(turns),
        "cost_micro_usd" => d.lifetime_micro_usd,
        "agent_messages" => d.lifetime_sends,
        "configured_model_used" =>
          Maraithon.Delegations.Reports.model_receipts_verified?(
            turns,
            Evaluation.scenarios()["model"]
          ),
        "todo_state" => Workflow.current(todo)["state"],
        "completion_cites_reply" => state["reply_message_id"] in evidence_ids
      })

    research_verified? =
      Enum.any?(turns, fn turn ->
        Map.has_key?(turn.data["model_entries"] || %{}, "researched") and
          turn.model_calls == 3 and turn.data["decision"]["kind"] == "propose_times" and
          Policy.approved?(turn.data["decision"], turn.data["policy_review"])
      end)

    common = Map.put(common, "reviewed_scheduling_research", research_verified?)

    cond do
      not common["configured_model_used"] ->
        {:error, :configured_model_not_proven}

      job.payload["scenario"]["expect"]["reviewed_research_turn"] == true and
          not research_verified? ->
        {:error, :reviewed_research_not_proven}

      d.kind == "scheduling" ->
        verify_calendar(job, Map.merge(state, common), d, todo)

      EvaluationCanary.scenario?(job) ->
        {:done, EvaluationCanary.verify(job, Map.merge(state, common), d, todo, turns)}

      true ->
        passed =
          todo.status == "done" and common["completion_cites_reply"] and
            String.contains?(
              String.downcase(get_in(d.data, ["ledger", "latest_outcome"]) || ""),
              "indigo"
            ) and
            d.lifetime_sends in 1..2 and d.lifetime_micro_usd <= 100_000

        {:done,
         Map.merge(state, Map.put(common, "phase", if(passed, do: "passed", else: "failed")))}
    end
  end

  defp verify_calendar(job, state, d, todo) do
    action = Repo.get!(PreparedAction, d.last_action_id) |> PreparedAction.hydrate_payload()
    id = ActionReconciliation.calendar_event_id(action.id)

    bookings =
      Repo.aggregate(
        from(a in PreparedAction,
          where:
            a.delegation_id == ^d.id and a.action_type == "calendar_create_event" and
              a.status == "executed"
        ),
        :count
      )

    with "calendar_create_event" <- action.action_type,
         {:ok, event} <-
           GoogleCalendar.get_event(@user, id, account_id: action.payload["account_id"]),
         true <- is_binary(event.ical_uid),
         {:ok, copies} <-
           GoogleCalendar.events_in_window(
             @user,
             job.payload["sender_account_id"],
             event.start,
             event.end
           ) do
      copy = Enum.find(copies, &(&1.ical_uid == event.ical_uid and &1.status != "cancelled"))
      conflict? = job.payload["scenario"]["id"] == "accepted_slot_becomes_busy"

      proof =
        action.payload["account_id"] == job.payload["owner_account_id"] and bookings == 1 and
          state["offered_slots_count"] == 3 and is_map(state["accepted_slot"]) and
          same_instant?(event.start, state["accepted_slot"]["start_at"]) and
          same_instant?(event.end, state["accepted_slot"]["end_at"]) and
          event.summary == action.payload["title"] and
          (event.description || "") == (action.payload["description"] || "") and
          same_instant?(event.start, action.payload["start_at"]) and
          same_instant?(event.end, action.payload["end_at"]) and
          Enum.any?(event.attendees, &(&1.email == @counterparty)) and
          Workflow.current(todo)["state"] == "waiting" and state["completion_cites_reply"] and
          d.lifetime_micro_usd <= 250_000 and
          (not conflict? or (d.data["slot_reoffers"] == 1 and outside_busy?(job, event)))

      cond do
        not proof ->
          {:error, :calendar_outcome_not_proven}

        is_nil(copy) and (state["copy_checks"] || 0) < 12 ->
          {:wait,
           Map.merge(state, %{
             "phase" => "waiting_for_calendar_copy",
             "copy_checks" => (state["copy_checks"] || 0) + 1
           })}

        is_nil(copy) ->
          {:error, :recipient_calendar_copy_missing}

        DateTime.compare(copy.start, event.start) != :eq or
            DateTime.compare(copy.end, event.end) != :eq or copy.summary != event.summary ->
          {:error, :recipient_calendar_copy_changed}

        true ->
          {:wait,
           Map.merge(state, %{
             "phase" => "calendar_verified",
             "event_id" => id,
             "verified_booked_action_id" => action.id,
             "recipient_calendar_copy" => true,
             "booked_events" => bookings,
             "booked_duration_min" => div(DateTime.diff(event.end, event.start), 60),
             "invitation_description_verified" => true,
             "reoffered" => conflict?
           })}
      end
    else
      error -> {:error, {:calendar_verification, error}}
    end
  end

  defp cleanup_busy(job, d) do
    case Repo.get(PreparedAction, deterministic_id(job.id, "busy"))
         |> PreparedAction.hydrate_payload() do
      %PreparedAction{status: "executed"} = action -> cleanup_calendar(job, d, action)
      _ -> :ok
    end
  end

  defp cleanup_calendar(job, d, created) do
    with {:ok, action} <-
           action(
             job,
             "cleanup:#{created.id}",
             %{
               "event_id" => ActionReconciliation.calendar_event_id(created.id),
               "account_id" => created.payload["account_id"],
               "todo_id" => d.todo_id,
               "notify_attendees" => true
             },
             "calendar_cancel_event"
           ),
         {:ok, _} <- deliver(action),
         do: :ok
  end

  defp same_instant?(actual, expected) do
    with {:ok, expected, _} <- DateTime.from_iso8601(expected),
         do: DateTime.compare(actual, expected) == :eq
  end

  defp outside_busy?(job, event) do
    busy =
      Repo.get!(PreparedAction, deterministic_id(job.id, "busy"))
      |> PreparedAction.hydrate_payload()

    {:ok, first, _} = DateTime.from_iso8601(busy.payload["start_at"])
    {:ok, last, _} = DateTime.from_iso8601(busy.payload["end_at"])
    DateTime.compare(event.end, first) != :gt or DateTime.compare(event.start, last) != :lt
  end

  defp fail(job, state, reason) do
    if id = state["delegation_id"] do
      if d = Delegations.get(@user, id) do
        if d.state not in ~w(completed stopped expired) do
          Delegations.stop(@user, id, %{
            "request_id" => "eval-stop:#{id}",
            "expected_revision" => d.revision
          })
        end
      end
    end

    cleanup = cleanup_failed_eval(job, state)

    next =
      Map.merge(state, %{
        "phase" => "failed",
        "reason" => Maraithon.Redaction.error_class(reason),
        "calendar_cleanup" => if(cleanup == :ok, do: "completed", else: "pending"),
        "cleanup_checks" => (state["cleanup_checks"] || 0) + 1
      })

    if cleanup == :wait and next["cleanup_checks"] < 12,
      do: {:ok, next, {:reschedule_in, 30_000}},
      else: {:ok, next}
  end

  defp cleanup_failed_eval(job, %{"delegation_id" => id}) do
    d = Delegations.get(@user, id)

    actions =
      Repo.all(
        from a in PreparedAction,
          where:
            a.user_id == @user and a.action_type == "calendar_create_event" and
              (a.delegation_id == ^id or a.id == ^deterministic_id(job.id, "busy"))
      )
      |> Enum.map(&PreparedAction.hydrate_payload/1)

    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case action.status do
        "executed" ->
          case cleanup_calendar(job, d, action) do
            :ok -> {:cont, :ok}
            result -> {:halt, result}
          end

        "execution_unknown" ->
          {:halt, :wait}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp cleanup_failed_eval(_, _), do: :ok

  defp deterministic_id(job_id, key) do
    <<id::binary-size(16), _::binary>> = :crypto.hash(:sha256, "#{job_id}:#{key}")
    Ecto.UUID.load!(id)
  end

  defp eval_only?, do: Application.get_env(:maraithon, :delegation_eval_only, false) == true
end
