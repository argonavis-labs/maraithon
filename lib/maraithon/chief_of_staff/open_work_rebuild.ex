defmodule Maraithon.ChiefOfStaff.OpenWorkRebuild do
  @moduledoc """
  Admin-triggered open-work rebuild for a single operator.

  This keeps the manual rebuild path on the same source acquisition,
  commitment-tracker, and todo-intelligence pipeline used by the Chief of Staff.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.ChiefOfStaff.Acquisition
  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.ChiefOfStaff.Skills.CommitmentTracker
  alias Maraithon.Effects.Effect
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.Runtime.Effects.LLMCallCommand
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @skill_id "commitment_tracker"
  @default_lookback_hours 24 * 14
  @default_calendar_forward_days 14
  @default_dismiss_limit 1_000
  @default_result_limit 100
  @default_llm_timeout_ms 1_200_000
  @zero_uuid "00000000-0000-0000-0000-000000000000"

  def run(user_id, opts \\ [])

  def run(user_id, opts) when is_binary(user_id) and is_list(opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:second)
    source_scope = Keyword.get(opts, :source_scope) || SourceScope.resolve(user_id)

    with {:ok, agent} <- chief_of_staff_agent(user_id),
         {:ok, dismissal} <- maybe_dismiss_existing(user_id, opts),
         {:ok, tracker_result} <- run_tracker(user_id, agent, source_scope, now, opts) do
      open_todos =
        user_id
        |> Todos.list_for_user(
          limit: positive_integer(Keyword.get(opts, :result_limit), @default_result_limit),
          statuses: ["open", "snoozed"]
        )
        |> Enum.map(&todo_summary/1)

      {status, restoration, open_todos} =
        maybe_restore_empty_rebuild(user_id, dismissal, tracker_result, open_todos, opts)

      {:ok,
       %{
         "status" => status,
         "user_id" => user_id,
         "agent_id" => agent.id,
         "dismissal" => dismissal,
         "restoration" => restoration,
         "tracker" => tracker_result,
         "open_todo_count" => length(open_todos),
         "open_todos" => open_todos,
         "completed_at" =>
           DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
       }}
    end
  end

  def run(_user_id, _opts), do: {:error, :invalid_user}

  def queue_job(user_id, opts \\ [])

  def queue_job(user_id, opts) when is_binary(user_id) and is_list(opts) do
    job_id = Keyword.get(opts, :job_id) || Ecto.UUID.generate()
    opts = Keyword.put(opts, :job_id, job_id)
    agent = chief_of_staff_agent_for_user(user_id)

    _ =
      record_job_event(user_id, agent && agent.id, job_id, "held", "Open work rebuild queued.", %{
        "lookback_hours" =>
          positive_integer(Keyword.get(opts, :lookback_hours), @default_lookback_hours),
        "dismiss_existing" => dismiss_existing?(opts)
      })

    case Task.Supervisor.start_child(Maraithon.Runtime.EffectSupervisor, fn ->
           run_and_record_safely(user_id, opts, agent && agent.id)
         end) do
      {:ok, _pid} ->
        {:ok, %{"status" => "queued", "job_id" => job_id, "user_id" => user_id}}

      {:error, reason} ->
        _ =
          record_job_event(
            user_id,
            agent && agent.id,
            job_id,
            "failed",
            "Open work rebuild did not start.",
            %{
              "error" => inspect(reason)
            }
          )

        {:error, reason}
    end
  end

  def queue_job(_user_id, _opts), do: {:error, :invalid_user}

  def job_status(user_id, job_id) when is_binary(user_id) and is_binary(job_id) do
    case ActionLedger.find_by_object(user_id, "open_work_rebuild_job_id", job_id) do
      [] ->
        {:error, :not_found}

      actions ->
        latest = hd(actions)

        {:ok,
         %{
           "job_id" => job_id,
           "user_id" => user_id,
           "status" => latest.status,
           "summary" => latest.model_summary,
           "updated_at" => normalize_json(latest.inserted_at),
           "events" => Enum.map(actions, &ActionLedger.redacted_action/1)
         }
         |> normalize_json()}
    end
  end

  def job_status(_user_id, _job_id), do: {:error, :not_found}

  def restore_recent_admin_dismissals(user_id, opts \\ [])

  def restore_recent_admin_dismissals(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = positive_integer(Keyword.get(opts, :limit), @default_result_limit)
    cutoff = Keyword.get(opts, :since)

    if match?(%DateTime{}, cutoff) do
      todos =
        Todo
        |> where([todo], todo.user_id == ^user_id)
        |> where([todo], todo.status == "dismissed")
        |> where([todo], todo.updated_at >= ^cutoff)
        |> where(
          [todo],
          fragment(
            "?->'assistant_feedback'->>'source' = ?",
            todo.metadata,
            "admin_open_work_rebuild"
          )
        )
        |> order_by([todo], asc: todo.updated_at)
        |> limit(^limit)
        |> Repo.all()

      restore_todo_records(user_id, todos, "manual_restore_after_zero_item_rebuild")
    else
      {:error, :missing_restore_since}
    end
  end

  def restore_recent_admin_dismissals(_user_id, _opts), do: {:error, :invalid_user}

  defp run_and_record(user_id, opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    agent = chief_of_staff_agent_for_user(user_id)

    _ =
      record_job_event(
        user_id,
        agent && agent.id,
        job_id,
        "running",
        "Open work rebuild started.",
        %{
          "lookback_hours" =>
            positive_integer(Keyword.get(opts, :lookback_hours), @default_lookback_hours),
          "dismiss_existing" => dismiss_existing?(opts)
        }
      )

    case run(user_id, opts) do
      {:ok, result} ->
        event_status = job_status_for_result(result)
        summary = job_summary_for_result(result)

        _ =
          record_job_event(
            user_id,
            result["agent_id"],
            job_id,
            event_status,
            summary,
            %{
              "dismissed_count" => get_in(result, ["dismissal", "dismissed_count"]),
              "open_todo_count" => result["open_todo_count"],
              "restored_count" => get_in(result, ["restoration", "restored_count"]),
              "restore_failed_count" => get_in(result, ["restoration", "failed_count"]),
              "tracker_event_type" => get_in(result, ["tracker", "event_type"]),
              "todo_count" => get_in(result, ["tracker", "payload", "todo_count"]),
              "todo_skipped_count" =>
                get_in(result, ["tracker", "payload", "todo_skipped_count"]),
              "source_telemetry" =>
                result
                |> get_in(["tracker", "source_telemetry"])
                |> compact_source_telemetry()
            }
          )

        {:ok, result}

      {:error, reason} ->
        _ =
          record_job_event(user_id, nil, job_id, "failed", "Open work rebuild failed.", %{
            "error" => inspect(reason)
          })

        {:error, reason}
    end
  end

  defp job_status_for_result(%{"status" => "empty_rebuild_restored"}), do: "failed"
  defp job_status_for_result(_result), do: "completed"

  defp job_summary_for_result(%{"status" => "empty_rebuild_restored"} = result) do
    restored_count = get_in(result, ["restoration", "restored_count"]) || 0
    "Open work rebuild produced zero items; restored #{restored_count} previous item(s)."
  end

  defp job_summary_for_result(result) do
    "Open work rebuild completed with #{result["open_todo_count"]} open item(s)."
  end

  defp run_and_record_safely(user_id, opts, fallback_agent_id) do
    run_and_record(user_id, opts)
  rescue
    exception ->
      stacktrace = __STACKTRACE__
      job_id = Keyword.fetch!(opts, :job_id)

      _ =
        record_job_event(
          user_id,
          fallback_agent_id,
          job_id,
          "failed",
          "Open work rebuild crashed.",
          %{
            "exception" => inspect(exception),
            "message" => Exception.message(exception),
            "stacktrace" => Exception.format_stacktrace(stacktrace) |> String.slice(0, 4_000)
          }
        )

      {:error, exception}
  catch
    kind, reason ->
      job_id = Keyword.fetch!(opts, :job_id)

      _ =
        record_job_event(
          user_id,
          fallback_agent_id,
          job_id,
          "failed",
          "Open work rebuild crashed.",
          %{
            "kind" => inspect(kind),
            "reason" => inspect(reason)
          }
        )

      {:error, {kind, reason}}
  end

  defp chief_of_staff_agent(user_id) do
    case chief_of_staff_agent_for_user(user_id) do
      %Agent{} = agent -> {:ok, agent}
      nil -> Runtime.install_chief_of_staff(user_id)
    end
  end

  defp chief_of_staff_agent_for_user(user_id) do
    Agents.list_agents(user_id: user_id)
    |> Enum.find(&(&1.behavior == "ai_chief_of_staff"))
  end

  defp maybe_dismiss_existing(user_id, opts) do
    if dismiss_existing?(opts) do
      dismiss_existing(user_id, opts)
    else
      {:ok,
       %{
         "dismiss_existing" => false,
         "matched_count" => 0,
         "dismissed_count" => 0,
         "failed_count" => 0,
         "failed" => []
       }}
    end
  end

  defp dismiss_existing?(opts) do
    Keyword.get(opts, :dismiss_existing?, true) != false
  end

  defp allow_empty_rebuild?(opts) do
    Keyword.get(opts, :allow_empty?, false) == true
  end

  defp dismiss_existing(user_id, opts) do
    limit = positive_integer(Keyword.get(opts, :dismiss_limit), @default_dismiss_limit)
    reason = Keyword.get(opts, :reason) || "Cleared before an admin open-work rebuild."

    todos = Todos.list_for_user(user_id, limit: limit, statuses: ["open", "snoozed"])

    {dismissed, failed} =
      Enum.reduce(todos, {[], []}, fn todo, {dismissed, failed} ->
        case Todos.dismiss(user_id, todo.id,
               note: reason,
               source: "admin_open_work_rebuild",
               skip_feedback?: true
             ) do
          {:ok, updated} ->
            {[dismissed_todo_summary(todo, updated) | dismissed], failed}

          {:error, reason} ->
            {dismissed, [%{"id" => todo.id, "reason" => inspect(reason)} | failed]}
        end
      end)

    dismissal = %{
      "dismiss_existing" => true,
      "matched_count" => length(todos),
      "dismissed_count" => length(dismissed),
      "failed_count" => length(failed),
      "dismissed" => Enum.reverse(dismissed),
      "failed" => Enum.reverse(failed)
    }

    if failed == [] do
      {:ok, dismissal}
    else
      {:error, {:todo_dismiss_failed, dismissal}}
    end
  end

  defp maybe_restore_empty_rebuild(user_id, dismissal, tracker_result, open_todos, opts) do
    cond do
      allow_empty_rebuild?(opts) ->
        {"completed", empty_restoration(), open_todos}

      length(open_todos) > 0 ->
        {"completed", empty_restoration(), open_todos}

      not restore_empty_rebuild?(dismissal, tracker_result) ->
        {"completed", empty_restoration(), open_todos}

      true ->
        restoration = restore_dismissed_todos(user_id, dismissal)

        restored_open_todos =
          user_id
          |> Todos.list_for_user(
            limit: positive_integer(Keyword.get(opts, :result_limit), @default_result_limit),
            statuses: ["open", "snoozed"]
          )
          |> Enum.map(&todo_summary/1)

        {"empty_rebuild_restored", restoration, restored_open_todos}
    end
  end

  defp restore_empty_rebuild?(dismissal, tracker_result) do
    dismissed_count = read_integer(dismissal, "dismissed_count")
    todo_count = get_in(tracker_result, ["payload", "todo_count"]) || 0

    dismissed_count > 0 and todo_count == 0
  end

  defp restore_dismissed_todos(user_id, dismissal) do
    dismissed = Map.get(dismissal, "dismissed", [])
    restored_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {restored, failed} =
      Enum.reduce(dismissed, {[], []}, fn todo, {restored, failed} ->
        todo_id = Map.get(todo, "id")

        attrs =
          restore_attrs(
            Map.get(todo, "restore_status", "open"),
            Map.get(todo, "restore_snoozed_until"),
            restored_at,
            "zero_item_rebuild_after_clear"
          )

        case Todos.update_for_user(user_id, todo_id, attrs,
               source: "admin_open_work_rebuild_restore"
             ) do
          {:ok, updated} ->
            {[todo_summary(updated) | restored], failed}

          {:error, reason} ->
            {restored, [%{"id" => todo_id, "reason" => inspect(reason)} | failed]}
        end
      end)

    %{
      "triggered" => true,
      "restored_count" => length(restored),
      "failed_count" => length(failed),
      "restored" => Enum.reverse(restored),
      "failed" => Enum.reverse(failed)
    }
  end

  defp restore_todo_records(user_id, todos, reason) when is_list(todos) do
    restored_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {restored, failed} =
      Enum.reduce(todos, {[], []}, fn todo, {restored, failed} ->
        attrs = restore_attrs("open", nil, restored_at, reason)

        case Todos.update_for_user(user_id, todo.id, attrs,
               source: "admin_open_work_rebuild_restore"
             ) do
          {:ok, updated} ->
            {[todo_summary(updated) | restored], failed}

          {:error, reason} ->
            {restored, [%{"id" => todo.id, "reason" => inspect(reason)} | failed]}
        end
      end)

    {:ok,
     %{
       "triggered" => true,
       "matched_count" => length(todos),
       "restored_count" => length(restored),
       "failed_count" => length(failed),
       "restored" => Enum.reverse(restored),
       "failed" => Enum.reverse(failed)
     }}
  end

  defp empty_restoration do
    %{
      "triggered" => false,
      "restored_count" => 0,
      "failed_count" => 0,
      "restored" => [],
      "failed" => []
    }
  end

  defp restore_attrs(status, snoozed_until, restored_at, reason) do
    %{
      "status" => status,
      "metadata" => %{
        "admin_open_work_rebuild_restore" => %{
          "restored_at" => restored_at,
          "reason" => reason
        }
      }
    }
    |> maybe_put("snoozed_until", snoozed_until)
  end

  defp run_tracker(user_id, %Agent{} = agent, source_scope, now, opts) do
    job_id = Keyword.get(opts, :job_id) || Ecto.UUID.generate()
    config = tracker_config(user_id, source_scope, opts)
    skill_configs = %{@skill_id => config}
    context = tracker_context(user_id, agent.id, now, job_id)
    {source_bundle, telemetry} = Acquisition.build(user_id, [@skill_id], skill_configs, context)

    context =
      context
      |> Map.put(:source_bundle, source_bundle)
      |> Map.put(:assistant_fetch_telemetry, telemetry)

    state = CommitmentTracker.init(config)

    case CommitmentTracker.handle_wakeup(state, context) do
      {:effect, {:llm_call, params}, pending_state} ->
        params = Map.put_new(params, "timeout_ms", @default_llm_timeout_ms)

        with {:ok, response} <- execute_llm(agent.id, params) do
          context
          |> then(
            &CommitmentTracker.handle_effect_result({:llm_call, response}, pending_state, &1)
          )
          |> tracker_result(telemetry)
        else
          {:error, reason} ->
            context
            |> then(&CommitmentTracker.handle_effect_error(:llm_call, reason, pending_state, &1))
            |> tracker_result(telemetry)
        end

      other ->
        tracker_result(other, telemetry)
    end
  end

  defp tracker_config(user_id, source_scope, opts) do
    CommitmentTracker.default_config()
    |> Map.merge(%{
      "user_id" => user_id,
      "assistant_behavior" => "ai_chief_of_staff",
      "source_policy" => "all_connected",
      "source_scope" => source_scope,
      "commitment_review_hour_local" => 0,
      "lookback_hours" =>
        positive_integer(Keyword.get(opts, :lookback_hours), @default_lookback_hours),
      "calendar_forward_days" =>
        positive_integer(
          Keyword.get(opts, :calendar_forward_days),
          @default_calendar_forward_days
        ),
      "email_scan_limit" => 200,
      "event_scan_limit" => 120,
      "slack_message_scan_limit" => 500,
      "local_message_scan_limit" => 500,
      "local_chat_scan_limit" => 200,
      "local_voice_memo_scan_limit" => 200,
      "local_note_scan_limit" => 200,
      "local_reminder_scan_limit" => 200,
      "local_file_scan_limit" => 200,
      "local_browser_visit_scan_limit" => 250,
      "llm_max_tokens" => 12_000,
      "llm_reasoning_effort" => "high"
    })
  end

  defp tracker_context(user_id, agent_id, now, job_id) do
    %{
      agent_id: agent_id,
      user_id: user_id,
      timestamp: now,
      assistant_cycle_id: job_id,
      trigger: %{
        type: :wakeup,
        source: "admin_open_work_rebuild",
        job_id: job_id,
        payload: %{
          "action" => "rebuild_open_work",
          "source" => "admin_open_work_rebuild",
          "job_id" => job_id
        }
      },
      last_message: "rebuild_open_work",
      last_message_id: job_id,
      last_message_metadata: %{
        "action" => "rebuild_open_work",
        "source" => "admin_open_work_rebuild",
        "job_id" => job_id
      }
    }
  end

  defp execute_llm(agent_id, params) do
    effect = %Effect{
      id: Ecto.UUID.generate(),
      agent_id: agent_id || @zero_uuid,
      idempotency_key: Ecto.UUID.generate(),
      effect_type: "llm_call",
      params: params
    }

    LLMCallCommand.execute(effect)
  end

  defp tracker_result({:emit, {event_type, payload}, _state}, telemetry) do
    {:ok,
     %{
       "event_type" => to_string(event_type),
       "payload" => normalize_json(payload),
       "source_telemetry" => normalize_json(telemetry)
     }}
  end

  defp tracker_result({:idle, _state}, telemetry) do
    {:ok,
     %{
       "event_type" => "idle",
       "payload" => %{},
       "source_telemetry" => normalize_json(telemetry)
     }}
  end

  defp tracker_result({:effect, _effect, _state}, telemetry) do
    {:ok,
     %{
       "event_type" => "pending_effect",
       "payload" => %{},
       "source_telemetry" => normalize_json(telemetry)
     }}
  end

  defp tracker_result(other, telemetry) do
    {:ok,
     %{
       "event_type" => "unknown",
       "payload" => %{"result" => inspect(other)},
       "source_telemetry" => normalize_json(telemetry)
     }}
  end

  defp compact_source_telemetry(%{} = telemetry) do
    %{
      "plan" =>
        telemetry
        |> Map.get("plan", %{})
        |> compact_plan(),
      "sources" =>
        telemetry
        |> Map.get("sources", %{})
        |> compact_sources()
    }
    |> normalize_json()
  end

  defp compact_source_telemetry(_telemetry), do: %{}

  defp compact_plan(%{} = plan) do
    [
      "lookback_hours",
      "forward_days",
      "inbox_limit",
      "sent_limit",
      "gmail_message_limit",
      "calendar_limit",
      "slack_channel_limit",
      "slack_message_limit",
      "local_calendar_limit",
      "local_message_limit",
      "local_chat_limit",
      "local_voice_memo_limit",
      "local_note_limit",
      "local_reminder_limit",
      "local_file_limit",
      "local_browser_visit_limit"
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case telemetry_value(plan, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp compact_plan(_plan), do: %{}

  defp compact_sources(%{} = sources) do
    Map.new(sources, fn {source, summary} -> {source, compact_source_summary(summary)} end)
  end

  defp compact_sources(_sources), do: %{}

  defp compact_source_summary(%{} = summary) do
    summary
    |> Map.take([
      "status",
      "mode",
      "message_count",
      "full_body_count",
      "body_missing_count",
      "event_count",
      "conversation_count",
      "workspace_count",
      "mention_count",
      "memo_count",
      "note_count",
      "open_due_soon",
      "recent_count",
      "visit_count",
      "feed_count",
      "item_count"
    ])
    |> maybe_put_count("provider_count", Map.get(summary, "providers"))
    |> maybe_put_count("team_count", Map.get(summary, "teams"))
    |> maybe_put_count("team_count", Map.get(summary, "team_ids"))
  end

  defp compact_source_summary(_summary), do: %{}

  defp maybe_put_count(summary, _key, nil), do: summary

  defp maybe_put_count(summary, key, values) when is_list(values),
    do: Map.put(summary, key, length(values))

  defp maybe_put_count(summary, _key, _values), do: summary

  defp telemetry_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp record_job_event(user_id, agent_id, job_id, status, summary, metadata) do
    ActionLedger.record(%{
      user_id: user_id,
      agent_id: agent_id,
      surface: "admin_api",
      event_type: "external_action.changed",
      status: status,
      model_summary: summary,
      result_object_refs: %{"open_work_rebuild_job_id" => job_id},
      metadata: metadata
    })
  end

  defp dismissed_todo_summary(%Todo{} = original, %Todo{} = dismissed) do
    dismissed
    |> todo_summary()
    |> Map.put("restore_status", restore_status(original.status))
    |> Map.put("restore_snoozed_until", normalize_json(original.snoozed_until))
  end

  defp todo_summary(%Todo{} = todo) do
    %{
      "id" => todo.id,
      "title" => todo.title,
      "summary" => todo.summary,
      "next_action" => todo.next_action,
      "status" => todo.status,
      "source" => todo.source,
      "source_item_id" => todo.source_item_id,
      "source_account_label" => todo.source_account_label,
      "due_at" => normalize_json(todo.due_at),
      "metadata" => normalize_json(todo.metadata || %{})
    }
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp read_integer(map, key, default \\ 0)

  defp read_integer(map, key, default) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_existing_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _value -> default
    end
  rescue
    ArgumentError -> default
  end

  defp read_integer(_map, _key, default), do: default

  defp parse_integer(value, default) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> default
    end
  end

  defp restore_status(status) when status in ["open", "snoozed"], do: status
  defp restore_status(_status), do: "open"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_json(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_json(value) when value in [nil, true, false], do: value
  defp normalize_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {normalize_json_key(key), normalize_json(item)} end)
  end

  defp normalize_json(value), do: value

  defp normalize_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_json_key(key), do: key
end
