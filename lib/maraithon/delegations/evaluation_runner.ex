defmodule Maraithon.Delegations.EvaluationRunner do
  @moduledoc "Bounded Kent-to-Kent provider evals, driven by durable background job checkpoints."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo, TelegramAssistant}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.Connectors.{Gmail, GoogleAccount, GoogleCalendar}
  alias Maraithon.Delegations.{Evaluation, Gates, Ingress, Turn}
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs, JobAuthority}
  alias Maraithon.TelegramAssistant.{ActionReconciliation, PreparedAction, Run}
  alias Maraithon.Todos.{Todo, Workflow}
  alias Maraithon.Tools.GmailApiHelpers

  @user "kent@runner.now"
  @counterparty "kent.fenwick@gmail.com"
  @job_type "delegation_eval"

  def start(scenario_id)
      when scenario_id in ~w(information_reply schedule_and_book accepted_slot_becomes_busy) do
    with true <- Gates.sends_enabled?(@user, "gmail") and eval_only?(),
         %{} = scenario <-
           Enum.find(Evaluation.scenarios()["scenarios"], &(&1["id"] == scenario_id)),
         %{"accounts_ready" => true, "model_ready" => true} = report <- Evaluation.preflight() do
      accounts = Map.new(report["accounts"], &{&1["email"], &1["account_id"]})
      id = Ecto.UUID.generate()

      payload = %{
        "scenario" => scenario,
        "sender_account_id" => accounts[@counterparty],
        "owner_account_id" => accounts[@user],
        "deadline" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 60, :minute)),
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
            dedupe_key: "delegation-eval:#{id}",
            payload: payload
          })

        %{job_id: job.id, scenario: scenario_id, phase: "queued"}
      end)
    else
      _ -> {:error, :eval_preflight_required}
    end
  end

  def start(_), do: {:error, :unsupported_eval_scenario}

  def execute(%BackgroundJob{job_type: @job_type, user_id: @user} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    Execution.with_authority(job, fn ->
      with {:ok, :ok} <- JobAuthority.transaction(job, fn -> :ok end),
           true <- eval_only?() and Gates.sends_enabled?(@user, "gmail"),
           {:ok, deadline, _} <- DateTime.from_iso8601(job.payload["deadline"]),
           :gt <- DateTime.compare(deadline, DateTime.utc_now()) do
        state = job.result || %{}

        case step(job, state) do
          {:wait, next} -> {:ok, next, {:reschedule_in, 30_000}}
          {:done, next} -> {:ok, next}
          {:error, reason} -> fail(job, state, reason)
        end
      else
        _ -> fail(job, job.result || %{}, :eval_stopped)
      end
    end)
  end

  def status do
    Repo.all(
      from j in BackgroundJob,
        where: j.job_type == @job_type and j.user_id == @user,
        order_by: [desc: j.inserted_at],
        limit: 5
    )
    |> Enum.map(fn row ->
      job = BackgroundJob.hydrate_payloads(row)
      %{job_id: job.id, status: job.status, result: job.result, error: job.last_error}
    end)
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
        reply(job, state, d)

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
          "actor" => "as_user",
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

    with {:ok, initial} <-
           action(job, "initial", %{"body" => job.payload["scenario"]["initial_email"]}),
         initial = PreparedAction.hydrate_payload(initial),
         thread = initial.payload["_maraithon_execution_result"]["thread_id"],
         {:ok, token} <- GoogleAccount.access_token(@user, job.payload["sender_account_id"]),
         {:ok, messages} <- Gmail.fetch_thread_content(token, thread, access_token: true),
         parent when not is_nil(parent) <-
           Enum.find(Enum.reverse(messages), fn m ->
             Enum.any?(
               Gmail.message_participants(m),
               &(&1["role"] == "from" and &1["identifier"]["email"] == @user)
             ) and "DRAFT" not in m.labels
           end),
         :ok <- verify_received_offer(job, d, parent),
         :ok <- maybe_make_busy(job, d, count),
         {:ok, action} <-
           action(job, reply_key(count), %{
             "body" => Enum.at(job.payload["scenario"]["counterparty_replies"], count),
             "thread_id" => thread,
             "reply_to_message_id" => parent.message_id
           }),
         {:ok, sent} <- deliver(action),
         {:ok, message} <- inbox_message(job, sent),
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
         "received_offer_verified" => d.kind == "scheduling"
       })}
    else
      nil -> {:wait, state}
      :wait -> {:wait, state}
      error -> error
    end
  end

  defp verify_received_offer(job, %{kind: "scheduling"} = d, message),
    do:
      Evaluation.verify_offer(
        job.payload["scenario"],
        d.data["offered_slots"],
        message.text_body,
        job.inserted_at
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
          "to" => @user,
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

  defp inbox_message(job, sent) do
    account = Repo.get!(Maraithon.Accounts.ConnectedAccount, job.payload["owner_account_id"])

    # A positive send receipt identifies the sender's exact message even when
    # Gmail replaces our RFC Message-ID. Never guess from subject or timestamp.
    with {:ok, sender_token} <-
           GoogleAccount.access_token(@user, job.payload["sender_account_id"]),
         {:ok, delivered} <-
           Gmail.fetch_message_content(
             sender_token,
             sent.payload["_maraithon_execution_result"]["message_id"],
             access_token: true
           ),
         true <- "SENT" in delivered.labels and is_binary(delivered.internet_message_id),
         {:ok, ids} <-
           GmailApiHelpers.list_message_ids(
             %{"user_id" => @user, "provider" => account.provider, "exact_account" => true},
             "in:anywhere rfc822msgid:#{delivered.internet_message_id}",
             2
           ),
         [id] <- ids,
         {:ok, token} <- GoogleAccount.access_token(@user, account.id),
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
         {:ok, message} <- inbox_message(job, action) do
      next =
        Map.merge(state, %{
          "reply_count" => count,
          "reply_message_id" => message.message_id,
          "accepted_slot" =>
            Enum.at(
              d.data["offered_slots"] || [],
              if(job.payload["scenario"]["id"] == "schedule_and_book", do: 1, else: 0)
            ),
          "offered_slots_count" => length(d.data["offered_slots"] || [])
        })

      verify_outcome(job, next, d)
    else
      :wait -> {:wait, Map.put(state, "phase", "waiting_for_reply_evidence")}
      _ -> {:error, :eval_completion_without_reply}
    end
  end

  defp verify_outcome(job, state, d) do
    todo = Repo.get!(Todo, d.todo_id)
    turns = Repo.all(from t in Turn, where: t.delegation_id == ^d.id)
    evidence_ids = Enum.map(d.data["evidence"] || [], & &1["id"])

    common = %{
      "model_calls" => Enum.sum(Enum.map(turns, & &1.model_calls)),
      "turns" => length(turns),
      "cost_micro_usd" => d.lifetime_micro_usd,
      "agent_messages" => d.lifetime_sends,
      "todo_state" => Workflow.current(todo)["state"],
      "completion_cites_reply" => state["reply_message_id"] in evidence_ids
    }

    if d.kind == "scheduling" do
      verify_calendar(job, Map.merge(state, common), d, todo)
    else
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

        true ->
          {:wait,
           Map.merge(state, %{
             "phase" => "calendar_verified",
             "event_id" => id,
             "verified_booked_action_id" => action.id,
             "recipient_calendar_copy" => true,
             "booked_events" => bookings,
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
