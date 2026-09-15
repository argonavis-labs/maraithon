defmodule Maraithon.Delegations.Execution do
  @moduledoc "Freeze an approved turn and enter its existing prepared-action executor once."
  import Ecto.Query
  alias Maraithon.{Repo, TelegramAssistant}
  alias Maraithon.AssistantChat.Execution, as: ChatExecution

  alias Maraithon.Delegations.{
    Actions,
    Authority,
    Binding,
    Gates,
    Jobs,
    Policy,
    Preferences,
    Turn
  }

  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.TelegramAssistant.{ActionReconciliation, PreparedAction}

  def prepare!(d, grant, event, now) do
    context = Jobs.context!(d, event)

    if context.turn.status == "dispatched" and is_binary(context.turn.prepared_action_id) and
         Authority.current?(context, context.run.prompt_snapshot[Binding.key()]) and
         Authority.workflow_current?(d) do
      d
    else
      prepare_action(d, grant, context, now)
    end
  end

  defp prepare_action(d, grant, context, now) do
    decision = context.turn.data["decision"]
    binding = context.run.prompt_snapshot[Binding.key()]
    prefs = Preferences.get(d.user_id)

    with true <- Authority.current?(context, binding) and Authority.workflow_current?(d),
         true <- Gates.scope_enabled?(d, grant),
         true <- context.turn.status == "validated" and context.turn.prepared_action_id == nil,
         {:ok, _} <- Policy.validate(context, decision),
         true <- Policy.approved?(decision, context.turn.data["policy_review"]),
         :ok <- send_capacity(context, now),
         {:ok, type, payload} <- payload(context, decision) do
      undo =
        prefs[
          if(d.actor == "as_user", do: "as_user_undo_seconds", else: "as_assistant_undo_seconds")
        ]

      available_at = now |> DateTime.add(undo) |> Preferences.next_work_time(prefs)

      action = %PreparedAction{
        id: Ecto.UUID.generate(),
        user_id: d.user_id,
        run_id: context.run.id,
        chat_id: context.run.chat_id,
        surface: "delegation",
        authorization_kind: "delegation_grant",
        delegation_id: d.id,
        delegation_turn_id: context.turn.id,
        grant_version: grant.version,
        action_type: type,
        payload: payload |> Map.put("user_id", d.user_id) |> Map.put(Binding.key(), binding)
      }

      with {:ok, frozen} <- TelegramAssistant.freeze_granted_payload(action) do
        action =
          action
          |> PreparedAction.changeset(%{
            payload: frozen,
            status: "confirmed",
            confirmed_at: now,
            expires_at: DateTime.add(available_at, 1, :hour),
            target_type: if(type == "gmail_send", do: "email", else: "calendar"),
            preview_text: decision["body"] || "Book the agreed meeting."
          })
          |> Repo.insert!()

        context.turn
        |> Turn.changeset(%{
          status: "dispatched",
          prepared_action_id: action.id,
          available_at: available_at
        })
        |> Repo.update!()

        Jobs.enqueue!("delegation_send", d, binding, available_at, %{"action_id" => action.id})

        case ActionReconciliation.enqueue(action, scheduled_at: DateTime.add(available_at, 60)) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        %{d | state: "sending", next_wake_at: nil}
      else
        {:error, reason} -> hold(d, reason, now)
      end
    else
      {:error, reason} -> hold(d, reason, now)
      _ -> hold(d, :decision_no_longer_current, now)
    end
  end

  def execute(%BackgroundJob{job_type: "delegation_send"} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    ChatExecution.with_authority(job, fn ->
      result =
        with {:ok, %{turn: turn} = context} <- Jobs.transaction(job, & &1),
             true <- turn.prepared_action_id == job.payload["action_id"],
             %PreparedAction{} = action <-
               Repo.get_by(PreparedAction, id: turn.prepared_action_id, user_id: job.user_id),
             action = PreparedAction.hydrate_payload(action) do
          case fresh_source(job, context, action) do
            :ok -> send_action(job, action)
            {:error, reason} -> source_hold(job, reason)
          end
        else
          {:ok, :superseded} -> {:ok, :superseded}
          {:error, _} = error -> error
          _ -> {:error, :delegation_action_mismatch}
        end

      Jobs.finish(result, job)
    end)
  end

  # Called with the worker, delegation, turn, run and action locks held. There
  # is no HTTP here, and the normal executor's heartbeat owns the provider call.
  def admit_entry(action, now) do
    context = Authority.lock_action_scope!(action)
    binding = action.payload[Binding.key()]

    cond do
      not Authority.current?(context, binding) or
          not Authority.workflow_current?(context.delegation) ->
        {:error, :decision_no_longer_current}

      not Gates.scope_enabled?(context.delegation, context.grant) ->
        {:error, :sends_disabled}

      context.turn.status != "dispatched" or context.delegation.state != "sending" ->
        {:error, :delegation_admission_required}

      DateTime.compare(now, context.turn.available_at) == :lt ->
        {:error, :undo_window_open}

      DateTime.compare(now, action.expires_at) != :lt ->
        {:error, :delegated_action_expired}

      true ->
        send_capacity(context, now, action.id)
    end
  end

  defp send_action(job, action) do
    case TelegramAssistant.execute_granted_action(action) do
      {:ok, _, _} ->
        {:ok, %{state: "sent", action_id: action.id}}

      {:ok, _, _, :already_executed} ->
        {:ok, %{state: "sent", action_id: action.id}}

      {:error, _, _, :manual_reconciliation} ->
        {:ok, %{state: "reconciling", action_id: action.id}}

      {:error, _, _, :permanent_failure} ->
        {:ok, %{state: "failed", action_id: action.id}}

      {:error, _, :prepared_action_execution_in_progress} ->
        {:ok, %{state: "sending"}, {:reschedule_in, 30_000}}

      {:error, _, :undo_window_open} ->
        {:ok, %{state: "undo_window"}, {:reschedule_in, 30_000}}

      {:error, _, reason} ->
        source_hold(job, reason)

      {:error, _, _, _} ->
        source_hold(job, :send_needs_review)
    end
  end

  defp fresh_source(_job, _context, action) when action.status != "confirmed", do: :ok

  defp fresh_source(job, context, action) do
    if Actions.unentered?(action),
      do: Maraithon.Delegations.Sources.verify_before_send(job, context),
      else: :ok
  end

  defp source_hold(job, reason) do
    case reason do
      {:rate_limited, seconds, _} ->
        {:error, {:retry_after, max(seconds, 30), :source_rate_limited}}

      {:rate_limited, _} ->
        {:error, {:retry_after, 30, :source_rate_limited}}

      _ ->
        Jobs.transaction(job, fn context ->
          Jobs.result!(context, "failure", %{
            "question" =>
              "The conversation changed or the send could not be verified. Please review it before I continue."
          })

          %{state: "needs_user"}
        end)
    end
  end

  defp payload(context, %{"kind" => kind} = decision) when kind in ~w(send propose_times) do
    d = context.delegation
    scope = context.grant.data["scope"]
    parent = List.last(context.run.prompt_snapshot["sources"]["messages"])

    if d.provider == "gmail" and (d.provider_thread_id == nil or is_map(parent)) do
      {:ok, "gmail_send",
       %{
         "account_id" => d.connected_account_id,
         "from" => scope["identity"]["email"],
         "to" => Enum.join(scope["to"], ", "),
         "cc" => Enum.join(scope["cc"], ", "),
         "subject" => scope["subject"],
         "body" => Policy.email_body(scope, decision["body"]),
         "todo_id" => d.todo_id,
         "thread_id" => d.provider_thread_id,
         "reply_to_message_id" => if(d.provider_thread_id, do: parent["message_id"])
       }}
    else
      {:error, :source_gap}
    end
  end

  defp payload(context, %{"kind" => "book", "accepted_slot_id" => id}) do
    scope = context.grant.data["scope"]
    slot = Enum.find(context.delegation.data["offered_slots"] || [], &(Policy.slot_id(&1) == id))
    ids = context.delegation.data["offered_calendar_account_ids"] || []

    if slot && ids != [] do
      {:ok, "calendar_create_event",
       Map.merge(slot, %{
         "account_id" => hd(ids),
         "calendar_account_ids" => ids,
         "attendees" => scope["to"] ++ scope["cc"],
         "title" => scope["outcome"],
         "description" => "Arranged by Maraithon.",
         "todo_id" => context.delegation.todo_id
       })}
    else
      {:error, :unoffered_slot}
    end
  end

  defp payload(_, _), do: {:error, :unsupported_delegated_action}

  defp send_capacity(context, now, excluded_id \\ nil) do
    d = context.delegation
    limits = Map.merge(Preferences.defaults(), context.grant.data["scope"]["limits"] || %{})
    cutoff = DateTime.add(now, -7, :day)

    query =
      from a in PreparedAction,
        where: a.delegation_id == ^d.id and a.authorization_kind == "delegation_grant",
        where:
          a.status in ~w(confirmed execution_unknown) or
            (a.status == "executed" and a.confirmed_at >= ^cutoff)

    query = if excluded_id, do: where(query, [a], a.id != ^excluded_id), else: query

    cond do
      d.deadline_at && DateTime.compare(now, d.deadline_at) != :lt ->
        {:error, :delegation_deadline_reached}

      Repo.aggregate(query, :count) >= limits["sends_per_7d"] ->
        {:error, :send_limit}

      context.turn.data["reminder"] == true and
          d.reminder_count_cycle >= limits["reminders_per_cycle"] ->
        {:error, :reminder_limit}

      true ->
        :ok
    end
  end

  defp hold(d, reason, now) do
    Actions.supersede_unentered!(d)
    capacity? = reason in [:send_limit, :reminder_limit, :sends_disabled]

    %{
      d
      | state: if(capacity?, do: "waiting_capacity", else: "needs_user"),
        next_wake_at: if(capacity?, do: DateTime.add(now, 6, :hour)),
        data:
          Map.merge(d.data, %{
            "hold_reason" => Atom.to_string(reason),
            "question" => "Please review this conversation before I continue."
          })
    }
  end
end
