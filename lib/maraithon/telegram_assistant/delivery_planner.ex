defmodule Maraithon.TelegramAssistant.DeliveryPlanner do
  @moduledoc """
  Model-backed planner for queued proactive Telegram delivery candidates.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.AssistantHarness
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant

  alias Maraithon.TelegramAssistant.{
    Context,
    ProactiveCandidate,
    ProactiveQualityGate,
    ProactiveQueue,
    PushBroker
  }

  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.TelegramAssistant.PushReceipt
  alias Maraithon.TelegramAssistant.TodoActions
  alias Maraithon.Todos
  alias Maraithon.Todos.AttentionRanker
  alias Maraithon.Todos.SurfaceQuality
  alias Maraithon.Todos.UserFacingCopy
  alias Maraithon.Tracing

  @default_batch_size 25
  @recent_push_limit 8

  def run_for_due_users(opts \\ []) when is_list(opts) do
    batch_size = opts |> Keyword.get(:batch_size, @default_batch_size) |> positive_integer()
    user_ids = Keyword.get(opts, :user_ids) || ProactiveQueue.pending_user_ids(limit: batch_size)

    Enum.reduce(user_ids, empty_due_summary(), fn user_id, acc ->
      case run_for_user(user_id, opts) do
        {:ok, result} ->
          %{
            acc
            | users: acc.users + 1,
              planned: acc.planned + result.planned,
              interrupt_now: acc.interrupt_now + result.interrupt_now,
              digest: acc.digest + result.digest,
              held: acc.held + result.held,
              delivered: acc.delivered + result.delivered,
              failed: acc.failed + result.failed
          }

        {:error, _reason} ->
          %{acc | users: acc.users + 1, failed: acc.failed + 1}
      end
    end)
  end

  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    Tracing.with_span("telegram_assistant.delivery_planner", %{user_id: user_id}, fn ->
      candidates = ProactiveQueue.list_pending_for_user(user_id, opts)

      case candidates do
        [] ->
          {:ok, empty_user_summary(user_id)}

        [_ | _] ->
          with chat_id when is_binary(chat_id) <- telegram_destination(user_id, opts),
               payload <- build_payload(user_id, chat_id, candidates, opts),
               {:ok, raw_plan} <- AssistantHarness.plan_delivery(payload, opts) do
            plan =
              raw_plan
              |> ProactiveQualityGate.verify_delivery_plan(payload, opts)
              |> apply_interruption_budget_to_plan(payload)

            planned = persist_plan(candidates, plan, payload)
            counts = disposition_counts(planned)
            record_planning_decision(user_id, candidates, plan, counts, payload)

            dispatch? = Keyword.get(opts, :dispatch, true)

            dispatch_counts =
              if dispatch? do
                dispatch(user_id, chat_id, planned, plan)
              else
                %{delivered: 0, failed: 0, held: 0}
              end

            {:ok,
             %{
               user_id: user_id,
               planned: length(planned),
               interrupt_now: counts.interrupt_now,
               digest: counts.digest,
               held: if(dispatch?, do: dispatch_counts.held, else: counts.hold),
               delivered: dispatch_counts.delivered,
               failed: dispatch_counts.failed
             }}
          else
            nil -> {:error, :telegram_not_connected}
            {:error, reason} -> {:error, reason}
          end
      end
    end)
  end

  def run_for_user(_user_id, _opts), do: {:error, :invalid_user}

  defp build_payload(user_id, chat_id, candidates, opts) do
    context =
      Keyword.get(opts, :context) ||
        Context.build(%{user_id: user_id, chat_id: chat_id || "unavailable"})

    recent_pushes =
      recent_pushes(user_id, Keyword.get(opts, :recent_push_limit, @recent_push_limit))

    ranked_candidates =
      candidates
      |> rank_candidates(context)
      |> Enum.with_index(1)

    %{
      user_id: user_id,
      chat_id: chat_id,
      candidates:
        Enum.map(ranked_candidates, fn {candidate, rank} ->
          candidate_snapshot(candidate, context, rank)
        end),
      context: context,
      recent_pushes: recent_pushes,
      interruption_budget: PushBroker.interruption_budget(user_id, now: now_from_context(context))
    }
  end

  defp candidate_snapshot(%ProactiveCandidate{} = candidate, context, rank) do
    related_todos = related_todos(candidate, context)
    profile = candidate_attention_profile(candidate, related_todos)

    %{
      id: candidate.id,
      source: candidate.source,
      source_id: candidate.source_id,
      dedupe_key: candidate.dedupe_key,
      title: candidate.title,
      body: delivery_text(candidate.body),
      urgency: candidate.urgency,
      why_now: candidate.why_now,
      structured_data: candidate.structured_data || %{},
      inserted_at: candidate.inserted_at,
      expires_at: candidate.expires_at,
      planning_rank: rank,
      attention_profile: profile,
      related_todos: Enum.map(related_todos, &compact_related_todo/1)
    }
  end

  defp rank_candidates(candidates, context) when is_list(candidates) do
    Enum.sort_by(candidates, fn candidate ->
      related_todos = related_todos(candidate, context)
      profile = candidate_attention_profile(candidate, related_todos)

      {
        profile["bucket_rank"],
        -profile["score"],
        -timestamp_sort_value(candidate.inserted_at)
      }
    end)
  end

  defp related_todos(%ProactiveCandidate{} = candidate, context) do
    structured_data = candidate.structured_data || %{}

    todo_ids =
      structured_data
      |> Map.get("todo_ids", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    if MapSet.size(todo_ids) == 0 do
      []
    else
      context
      |> context_todos()
      |> Enum.filter(fn todo ->
        case read_field(todo, "id") do
          id when is_binary(id) -> MapSet.member?(todo_ids, id)
          _ -> false
        end
      end)
    end
  end

  defp context_todos(context) when is_map(context) do
    direct_todos = read_field(context, "todos") || []
    open_loops = read_field(context, "open_loops") || %{}
    buckets = read_field(open_loops, "buckets") || %{}

    bucket_todos =
      if is_map(buckets) do
        buckets
        |> Map.values()
        |> Enum.flat_map(fn
          list when is_list(list) -> list
          _ -> []
        end)
      else
        []
      end

    (direct_todos ++ bucket_todos)
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&read_field(&1, "id"))
  end

  defp context_todos(_context), do: []

  defp candidate_attention_profile(%ProactiveCandidate{} = candidate, []) do
    urgency_score = round((candidate.urgency || 0.0) * 100)
    age_days = age_days(candidate.inserted_at)

    %{
      "bucket" => "other",
      "bucket_rank" => 5,
      "score" => urgency_score,
      "relationship_strength" => 0,
      "personal_family" => false,
      "actively_waiting" => false,
      "business_project" => false,
      "intro_request" => false,
      "meeting_request" => false,
      "stale_confirmation_candidate" => age_days >= 3 and urgency_score < 85,
      "age_days" => age_days,
      "context" => %{}
    }
  end

  defp candidate_attention_profile(%ProactiveCandidate{}, related_todos) do
    related_todos
    |> Enum.map(&AttentionRanker.profile/1)
    |> Enum.sort_by(fn profile -> {profile["bucket_rank"], -profile["score"]} end)
    |> List.first()
  end

  defp compact_related_todo(todo) when is_map(todo) do
    %{
      "id" => read_field(todo, "id"),
      "title" => read_field(todo, "title"),
      "summary" => read_field(todo, "summary"),
      "next_action" => read_field(todo, "next_action"),
      "due_at" => read_field(todo, "due_at"),
      "source_occurred_at" => read_field(todo, "source_occurred_at"),
      "inserted_at" => read_field(todo, "inserted_at"),
      "attention_profile" => AttentionRanker.profile(todo),
      "surface_quality" => SurfaceQuality.assess(todo)
    }
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :second)
  defp timestamp_sort_value(_datetime), do: 0

  defp age_days(%DateTime{} = datetime) do
    div(max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0), 86_400)
  end

  defp age_days(_datetime), do: 0

  defp persist_plan(candidates, plan, payload) do
    disposition_by_id =
      plan
      |> Map.get("dispositions", [])
      |> Map.new(fn disposition -> {disposition["candidate_id"], disposition} end)

    candidate_order = candidate_order(payload)

    candidates
    |> Enum.sort_by(&Map.get(candidate_order, &1.id, 999_999))
    |> Enum.flat_map(fn candidate ->
      disposition = Map.get(disposition_by_id, candidate.id)
      value = (disposition && disposition["disposition"]) || "hold"
      reason = (disposition && disposition["reason"]) || "No model disposition returned."

      case ProactiveQueue.mark_planned(candidate, value, reason) do
        {:ok, planned} -> [planned]
        {:error, _reason} -> []
      end
    end)
  end

  defp candidate_order(payload) do
    payload
    |> read_field("candidates")
    |> List.wrap()
    |> Enum.with_index()
    |> Map.new(fn {candidate, index} -> {read_field(candidate, "id"), index} end)
  end

  defp candidates_by_id(payload) do
    payload
    |> read_field("candidates")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Map.new(fn candidate -> {read_field(candidate, "id"), candidate} end)
  end

  defp dispatch(user_id, chat_id, planned, plan) do
    interrupt_now = Enum.filter(planned, &(&1.disposition == "interrupt_now"))
    digest = Enum.filter(planned, &(&1.disposition == "digest"))
    hold = Enum.filter(planned, &(&1.disposition == "hold"))

    interrupt_counts = dispatch_interrupts(interrupt_now, chat_id)
    digest_counts = dispatch_digest(user_id, chat_id, digest, plan)
    held_count = mark_held(hold)

    %{
      delivered: interrupt_counts.delivered + digest_counts.delivered,
      failed: interrupt_counts.failed + digest_counts.failed,
      held: held_count
    }
  end

  defp apply_interruption_budget_to_plan(plan, payload) when is_map(plan) do
    budget = read_field(payload, "interruption_budget") || %{}
    remaining = read_integer(budget, "remaining_immediate", 1)
    quiet_hours? = read_field(budget, "quiet_hours") == true
    candidates_by_id = candidates_by_id(payload)

    dispositions =
      plan
      |> read_field("dispositions")
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {disposition, index} ->
        candidate = Map.get(candidates_by_id, read_field(disposition, "candidate_id"))

        if read_field(disposition, "disposition") == "interrupt_now" and
             should_downgrade_interrupt?(
               candidate,
               index,
               remaining,
               quiet_hours?
             ) do
          disposition
          |> Map.put("disposition", "digest")
          |> Map.put("reason", budget_digest_reason(budget))
        else
          disposition
        end
      end)

    Map.put(plan, "dispositions", dispositions)
  end

  defp apply_interruption_budget_to_plan(plan, _payload), do: plan

  defp should_downgrade_interrupt?(candidate_snapshot, index, remaining, quiet_hours?) do
    profile = read_field(candidate_snapshot || %{}, "attention_profile") || %{}
    urgency = read_float(candidate_snapshot || %{}, "urgency", 0.0)

    protected? =
      read_field(profile, "personal_family") == true or
        read_field(profile, "bucket") == "strong_relationship_waiting" or
        urgency >= 0.95

    cond do
      protected? -> false
      remaining <= 0 -> true
      quiet_hours? -> true
      index >= remaining -> true
      true -> false
    end
  end

  defp budget_digest_reason(budget) do
    cond do
      read_field(budget, "quiet_hours") == true ->
        "Interruption budget: quiet hours active, so this is batched instead of interrupting."

      read_integer(budget, "remaining_immediate", 0) <= 0 ->
        "Interruption budget exhausted for the hour, so this is batched."

      true ->
        "Interruption budget kept this batched."
    end
  end

  defp dispatch_interrupts(candidates, chat_id) do
    Enum.reduce(candidates, %{delivered: 0, failed: 0}, fn candidate, acc ->
      case PushBroker.deliver(push_candidate(candidate, chat_id, interrupt_now: true)) do
        {:ok, %{decision: "sent_now", conversation_id: conversation_id}} ->
          {:ok, _candidate} = ProactiveQueue.mark_delivered(candidate)
          maybe_send_candidate_todo_cards(conversation_id, candidate)
          %{acc | delivered: acc.delivered + 1}

        {:ok, %{decision: "sent_now"}} ->
          {:ok, _candidate} = ProactiveQueue.mark_delivered(candidate)
          %{acc | delivered: acc.delivered + 1}

        {:ok, _result} ->
          {:ok, _candidate} = ProactiveQueue.mark_held(candidate)
          acc

        {:error, _reason} ->
          %{acc | failed: acc.failed + 1}

        {:fallback, _reason} ->
          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp dispatch_digest(_user_id, _chat_id, [], _plan), do: %{delivered: 0, failed: 0}

  defp dispatch_digest(user_id, chat_id, candidates, plan) do
    digest_intro = digest_intro(plan)
    digest_key = "delivery_digest:#{user_id}:#{Date.utc_today() |> Date.to_iso8601()}"

    parent_candidate = %{
      user_id: user_id,
      chat_id: chat_id,
      origin_type: "assistant_digest",
      origin_id: digest_key,
      dedupe_key: digest_key,
      title: "Maraithon digest",
      body: digest_intro,
      urgency: max_urgency(candidates),
      interrupt_now: true,
      why_now: Map.get(plan, "summary"),
      structured_data: %{
        "message_class" => "proactive_delivery_digest",
        "candidate_ids" => Enum.map(candidates, & &1.id)
      },
      telegram_opts: [parse_mode: "HTML"]
    }

    case PushBroker.deliver(parent_candidate) do
      {:ok, %{decision: "sent_now", conversation_id: conversation_id}} ->
        case load_conversation(conversation_id) do
          %Conversation{} = conversation ->
            send_digest_cards(conversation, candidates)

          nil ->
            %{delivered: 0, failed: length(candidates)}
        end

      {:ok, _result} ->
        %{delivered: 0, failed: length(candidates)}

      {:error, _reason} ->
        %{delivered: 0, failed: length(candidates)}

      {:fallback, _reason} ->
        %{delivered: 0, failed: length(candidates)}
    end
  end

  defp send_digest_cards(%Conversation{} = conversation, candidates) do
    Enum.reduce(candidates, %{delivered: 0, failed: 0}, fn candidate, acc ->
      case TelegramAssistant.send_turn(
             conversation,
             conversation.chat_id,
             delivery_text(candidate.body),
             send_mode: :send,
             turn_kind: "assistant_push",
             origin_type: origin_type(candidate),
             origin_id: candidate.source_id,
             structured_data:
               candidate_structured_data(candidate)
               |> Map.put("message_class", "proactive_candidate")
               |> Map.put("delivery_disposition", "digest")
               |> Map.put("candidate_id", candidate.id),
             telegram_opts: telegram_opts_to_keyword(candidate.telegram_opts)
           ) do
        {:ok, _conversation, turn, _telegram_result} ->
          {:ok, _candidate} = ProactiveQueue.mark_delivered(candidate)
          record_merged_receipt(candidate, turn.id)
          todo_counts = send_candidate_todo_cards(conversation, candidate)
          %{acc | delivered: acc.delivered + 1, failed: acc.failed + todo_counts.failed}

        {:error, _reason} ->
          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp mark_held(candidates) do
    Enum.reduce(candidates, 0, fn candidate, count ->
      case ProactiveQueue.mark_held(candidate) do
        {:ok, _candidate} -> count + 1
        {:error, _reason} -> count
      end
    end)
  end

  defp push_candidate(%ProactiveCandidate{} = candidate, chat_id, opts) do
    %{
      user_id: candidate.user_id,
      chat_id: chat_id,
      origin_type: origin_type(candidate),
      origin_id: candidate.source_id,
      linked_delivery_id: get_in(candidate.structured_data || %{}, ["linked_delivery_id"]),
      linked_insight_id: get_in(candidate.structured_data || %{}, ["linked_insight_id"]),
      dedupe_key: candidate.dedupe_key,
      title: candidate.title,
      body: delivery_text(candidate.body),
      urgency: candidate.urgency,
      interrupt_now: Keyword.get(opts, :interrupt_now, false),
      why_now: candidate.why_now,
      structured_data:
        candidate_structured_data(candidate)
        |> Map.put("candidate_id", candidate.id)
        |> Map.put("delivery_disposition", candidate.disposition),
      telegram_opts: telegram_opts_to_keyword(candidate.telegram_opts)
    }
  end

  defp origin_type(%ProactiveCandidate{source: "insight"}), do: "insight"
  defp origin_type(%ProactiveCandidate{source: "brief"}), do: "brief"
  defp origin_type(%ProactiveCandidate{source: "proactive_check_in"}), do: "assistant_digest"

  defp maybe_send_candidate_todo_cards(conversation_id, %ProactiveCandidate{} = candidate)
       when is_binary(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{} = conversation -> send_candidate_todo_cards(conversation, candidate)
      nil -> %{delivered: 0, failed: 0}
    end
  end

  defp maybe_send_candidate_todo_cards(_conversation_id, _candidate),
    do: %{delivered: 0, failed: 0}

  defp send_candidate_todo_cards(
         %Conversation{} = conversation,
         %ProactiveCandidate{} = candidate
       ) do
    todo_ids =
      candidate
      |> candidate_structured_data()
      |> Map.get("todo_ids", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

    message_class =
      candidate
      |> candidate_structured_data()
      |> Map.get("message_class")

    if candidate.source != "brief" and message_class == "todo_digest" and todo_ids != [] do
      candidate.user_id
      |> Todos.list_by_ids(todo_ids, statuses: ["open", "snoozed"])
      |> Enum.reduce(%{delivered: 0, failed: 0}, fn todo, acc ->
        payload = TodoActions.telegram_payload(todo)

        case TelegramAssistant.send_turn(
               conversation,
               conversation.chat_id,
               payload.text,
               send_mode: :send,
               turn_kind: "assistant_push",
               origin_type: origin_type(candidate),
               origin_id: candidate.source_id,
               structured_data: %{
                 "message_class" => "todo_item",
                 "linked_todo" => Todos.serialize_for_prompt(todo),
                 "surface_quality" => SurfaceQuality.assess(todo)
               },
               telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
             ) do
          {:ok, _conversation, _turn, _telegram_result} ->
            %{acc | delivered: acc.delivered + 1}

          {:error, _reason} ->
            %{acc | failed: acc.failed + 1}
        end
      end)
    else
      %{delivered: 0, failed: 0}
    end
  end

  defp candidate_structured_data(%ProactiveCandidate{} = candidate) do
    %{
      "title" => candidate.title,
      "why_now" => candidate.why_now,
      "urgency" => candidate.urgency
    }
    |> Map.merge(candidate.structured_data || %{})
  end

  defp telegram_opts_to_keyword(%{} = opts) do
    []
    |> maybe_put_option(:parse_mode, Map.get(opts, "parse_mode"))
    |> maybe_put_option(:reply_markup, Map.get(opts, "reply_markup"))
  end

  defp telegram_opts_to_keyword(_opts), do: []

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp record_merged_receipt(%ProactiveCandidate{} = candidate, turn_id) do
    case TelegramAssistant.record_push_receipt(%{
           user_id: candidate.user_id,
           dedupe_key: candidate.dedupe_key,
           origin_type: origin_type(candidate),
           origin_id: candidate.source_id,
           decision: "merged",
           conversation_turn_id: turn_id
         }) do
      {:ok, _receipt} -> :ok
      {:error, _reason} -> :ok
    end
  rescue
    _error -> :ok
  end

  defp record_planning_decision(user_id, candidates, plan, counts, payload) do
    ActionLedger.record(%{
      user_id: user_id,
      surface: "telegram",
      event_type: "proactive.delivery_planned",
      status: "completed",
      source_evidence: %{
        "candidate_ids" => Enum.map(candidates, & &1.id),
        "dedupe_keys" => Enum.map(candidates, & &1.dedupe_key)
      },
      model_summary: Map.get(plan, "summary"),
      result_object_refs: %{
        "candidate_ids" => Enum.map(candidates, & &1.id)
      },
      metadata: %{
        "interrupt_now_count" => counts.interrupt_now,
        "digest_count" => counts.digest,
        "hold_count" => counts.hold,
        "interruption_budget" =>
          Map.get(payload, :interruption_budget) || payload["interruption_budget"]
      }
    })

    :ok
  rescue
    _error -> :ok
  end

  defp recent_pushes(user_id, limit) when is_binary(user_id) do
    PushReceipt
    |> where([receipt], receipt.user_id == ^user_id)
    |> order_by([receipt], desc: receipt.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn receipt ->
      %{
        id: receipt.id,
        dedupe_key: receipt.dedupe_key,
        origin_type: receipt.origin_type,
        origin_id: receipt.origin_id,
        decision: receipt.decision,
        inserted_at: receipt.inserted_at
      }
    end)
  end

  defp load_conversation(conversation_id) when is_binary(conversation_id),
    do: Repo.get(Conversation, conversation_id)

  defp load_conversation(_conversation_id), do: nil

  defp telegram_destination(user_id, opts) do
    Keyword.get(opts, :chat_id) || ConnectedAccounts.telegram_destination(user_id)
  end

  defp disposition_counts(planned) do
    %{
      interrupt_now: Enum.count(planned, &(&1.disposition == "interrupt_now")),
      digest: Enum.count(planned, &(&1.disposition == "digest")),
      hold: Enum.count(planned, &(&1.disposition == "hold"))
    }
  end

  defp digest_intro(plan) do
    case Map.get(plan, "digest_intro") do
      value when is_binary(value) and value != "" -> delivery_text(value)
      _value -> "A few proactive updates are grouped here."
    end
  end

  defp delivery_text(value) when is_binary(value), do: UserFacingCopy.polish_text(value)
  defp delivery_text(value), do: value

  defp max_urgency(candidates) do
    candidates
    |> Enum.map(&(&1.urgency || 0.0))
    |> Enum.max(fn -> 0.0 end)
  end

  defp now_from_context(context) when is_map(context) do
    context
    |> read_field("current_time")
    |> read_field("now_utc")
    |> parse_datetime()
  end

  defp now_from_context(_context), do: DateTime.utc_now()

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> DateTime.utc_now()
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime
  defp parse_datetime(_value), do: DateTime.utc_now()

  defp empty_due_summary do
    %{users: 0, planned: 0, interrupt_now: 0, digest: 0, held: 0, delivered: 0, failed: 0}
  end

  defp empty_user_summary(user_id) do
    %{
      user_id: user_id,
      planned: 0,
      interrupt_now: 0,
      digest: 0,
      held: 0,
      delivered: 0,
      failed: 0
    }
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_batch_size
    end
  end

  defp positive_integer(_value), do: @default_batch_size

  defp read_field(%_{} = struct, key), do: read_field(Map.from_struct(struct), key)

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _ ->
          nil
      end)
  end

  defp read_field(_map, _key), do: nil

  defp read_integer(map, key, default) when is_map(map) do
    case read_field(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _other -> default
        end

      _other ->
        default
    end
  end

  defp read_integer(_map, _key, default), do: default

  defp read_float(map, key, default) when is_map(map) do
    case read_field(map, key) do
      value when is_float(value) ->
        value

      value when is_integer(value) ->
        value / 1

      value when is_binary(value) ->
        case Float.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _other -> default
        end

      _other ->
        default
    end
  end

  defp read_float(_map, _key, default), do: default
end
