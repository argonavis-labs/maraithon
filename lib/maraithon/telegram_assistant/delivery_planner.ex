defmodule Maraithon.TelegramAssistant.DeliveryPlanner do
  @moduledoc """
  Model-backed planner for queued proactive Telegram delivery candidates.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.AssistantHarness
  alias Maraithon.BriefingSchedules
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightFeedback
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.InsightNotifications.MemoryGate
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

            dispatch? = Keyword.get(opts, :dispatch, true)

            dispatch_counts =
              if dispatch? do
                dispatch(user_id, chat_id, planned, plan)
              else
                %{delivered: 0, failed: 0, held: 0, hold_reasons: %{}}
              end

            # Recorded after dispatch so this reflects the enforced outcome
            # (post budget/quiet-hours gate), not just the model's plan.
            record_planning_decision(user_id, candidates, plan, counts, payload, dispatch_counts)

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
      interruption_budget:
        PushBroker.interruption_budget(user_id, now: now_from_context(context, user_id)),
      operator_feedback: operator_feedback_examples(user_id),
      # SPEC 07 R4: preference/instruction/relationship memories recalled
      # with this batch's candidate titles as the query, so a "never surface
      # X" memory can inform the model's hold/interrupt_now/digest call for
      # a matching candidate — same recall path `insight_notifications.ex`
      # uses for the legacy gate, just folded into this batch decision
      # instead of a second gatekeeping model call.
      interrupt_memory: interrupt_memory_context(user_id, candidates)
    }
  end

  # Good/bad interruption examples for this specific operator, so the model
  # calibrates against real thumbs feedback instead of only a scalar
  # threshold it never otherwise reads.
  defp operator_feedback_examples(user_id) do
    feedback = InsightFeedback.prompt_context(user_id)
    recent_feedback = feedback.recent_feedback || []

    %{
      threshold_profile: feedback.threshold_profile,
      good_interruption_examples: Enum.filter(recent_feedback, &(&1.feedback == "helpful")),
      bad_interruption_examples: Enum.filter(recent_feedback, &(&1.feedback == "not_helpful")),
      preference_profile: feedback.preference_profile,
      user_memory_profile: feedback.user_memory_profile
    }
  end

  defp interrupt_memory_context(user_id, candidates) do
    query =
      candidates
      |> Enum.map(&candidate_title/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.take(12)
      |> Enum.join(" | ")

    case query do
      "" -> %{summary: "No pending candidates to recall memory for.", memories: [], count: 0}
      query -> MemoryGate.recall_memories(user_id, query) |> memory_summary_context(query)
    end
  end

  defp memory_summary_context(memories, query) do
    %{
      summary:
        if(memories == [],
          do: "No relevant preference/instruction/relationship memories matched.",
          else: "Interrupt-relevant memories for: #{query}"
        ),
      memories: memories,
      count: length(memories)
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
      title: candidate_title(candidate),
      body: delivery_text(candidate.body),
      urgency: candidate.urgency,
      why_now: candidate_why_now(candidate),
      structured_data: candidate_structured_data(candidate),
      inserted_at: local_display(candidate.inserted_at, candidate.user_id),
      expires_at: local_display(candidate.expires_at, candidate.user_id),
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
      {value, reason} = resolve_disposition(candidate, disposition)

      case ProactiveQueue.mark_planned(candidate, value, reason) do
        {:ok, planned} -> [planned]
        {:error, _reason} -> []
      end
    end)
  end

  # Bug fix: a cadence brief is an explicit user subscription, not an
  # opportunistic push — the planner model must not be able to fatigue/
  # relevance-hold it indefinitely. In production the model held the
  # morning brief every cycle with a "notification fatigue" rationale, and
  # the brief sat "pending" forever (compounding Briefs.list_pending/1's
  # backlog problem). Prompt-level guidance alone is not sufficient (GOALS
  # Principle 3: runtime validates model decisions) — a brief-sourced
  # candidate the model tried to `hold` is forced to `interrupt_now` here,
  # post-plan. `digest` is left as the model chose it: it still delivers
  # this cycle (just bundled), so it is not the "held forever" failure mode
  # this guards against, and downstream dispatch/push_candidate/2 exempts
  # brief-sourced sends from the hourly interruption budget (still fully
  # subject to the quiet-hours gate and true duplicate-receipt suppression
  # at PushBroker send time).
  defp resolve_disposition(%ProactiveCandidate{source: "brief"}, disposition) do
    case disposition && disposition["disposition"] do
      "hold" ->
        {"interrupt_now",
         "Cadence brief: forced to send instead of a model hold (not model-holdable for fatigue/relevance)."}

      value when value in ["interrupt_now", "digest"] ->
        {value, disposition["reason"] || "No model disposition returned."}

      _other ->
        {"interrupt_now", "Cadence brief: forced to send (no valid model disposition returned)."}
    end
  end

  defp resolve_disposition(_candidate, disposition) do
    value = (disposition && disposition["disposition"]) || "hold"
    reason = (disposition && disposition["reason"]) || "No model disposition returned."
    {value, reason}
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
      held: held_count + interrupt_counts.held + digest_counts.held,
      hold_reasons:
        merge_hold_reasons([
          interrupt_counts.hold_reasons,
          digest_counts.hold_reasons,
          model_hold_reasons(hold)
        ])
    }
  end

  defp model_hold_reasons([]), do: %{}
  defp model_hold_reasons(hold), do: %{"model_hold" => length(hold)}

  defp merge_hold_reasons(reason_maps) do
    Enum.reduce(reason_maps, %{}, fn reasons, acc ->
      Map.merge(acc, reasons, fn _reason, a, b -> a + b end)
    end)
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
    Enum.reduce(candidates, %{delivered: 0, failed: 0, held: 0, hold_reasons: %{}}, fn candidate,
                                                                                       acc ->
      # Model chose interrupt_now at planning time, but PushBroker.deliver/1
      # still re-checks the hard budget gate at send time (R2): only a
      # genuinely high-urgency candidate skips the hourly cap/quiet hours.
      case PushBroker.deliver(push_candidate(candidate, chat_id, interrupt_now: true)) do
        {:ok, %{decision: "sent_now", conversation_id: conversation_id}} ->
          {:ok, _candidate} = ProactiveQueue.mark_delivered(candidate)
          maybe_mark_brief_delivered(candidate)
          maybe_mark_insight_delivery_sent(candidate)
          maybe_send_candidate_todo_cards(conversation_id, candidate)
          record_dispatch_decision(candidate, "proactive.sent", "sent", %{"decision" => "sent_now"})
          %{acc | delivered: acc.delivered + 1}

        {:ok, %{decision: "sent_now"}} ->
          {:ok, _candidate} = ProactiveQueue.mark_delivered(candidate)
          maybe_mark_brief_delivered(candidate)
          maybe_mark_insight_delivery_sent(candidate)
          record_dispatch_decision(candidate, "proactive.sent", "sent", %{"decision" => "sent_now"})
          %{acc | delivered: acc.delivered + 1}

        {:ok, %{decision: "suppressed", reason: "duplicate"}} ->
          # Already delivered under this dedupe_key through another path.
          {:ok, _candidate} = ProactiveQueue.mark_delivered(candidate)
          maybe_mark_brief_delivered(candidate)
          maybe_mark_insight_delivery_sent(candidate)

          record_dispatch_decision(candidate, "proactive.sent", "sent", %{
            "decision" => "suppressed",
            "reason" => "duplicate"
          })

          %{acc | delivered: acc.delivered + 1}

        {:ok, %{decision: "held_rate_limit", reason: reason}} ->
          {:ok, _candidate} = ProactiveQueue.mark_held(candidate)

          record_dispatch_decision(candidate, "proactive.held", "held", %{
            "decision" => "held_rate_limit",
            "hold_reason" => reason
          })

          %{acc | held: acc.held + 1, hold_reasons: bump_reason(acc.hold_reasons, reason)}

        {:ok, _result} ->
          {:ok, _candidate} = ProactiveQueue.mark_held(candidate)

          record_dispatch_decision(candidate, "proactive.held", "held", %{
            "decision" => "unknown"
          })

          %{acc | held: acc.held + 1, hold_reasons: bump_reason(acc.hold_reasons, "unknown")}

        {:error, _reason} ->
          %{acc | failed: acc.failed + 1}

        {:fallback, _reason} ->
          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  defp bump_reason(reasons, reason) when is_map(reasons) and is_binary(reason) do
    Map.update(reasons, reason, 1, &(&1 + 1))
  end

  defp bump_reason(reasons, _reason), do: reasons

  defp dispatch_digest(_user_id, _chat_id, [], _plan), do: %{delivered: 0, failed: 0, held: 0, hold_reasons: %{}}

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
      # Informational only (telemetry/structured_data) — `digest: true` below
      # keeps PushBroker's urgency-exempt-from-quiet-hours check from ever
      # reading this value, so a bundled urgency >= 0.9 item cannot un-gate
      # the whole digest during quiet hours (see push_broker.ex).
      urgency: max_urgency(candidates),
      # The digest bundle is the batched, budget-conscious delivery path
      # itself (R2) — it is not an interrupt, and its own send is exempt
      # from the hourly cap (but still respects quiet hours).
      interrupt_now: false,
      bypass_budget_cap: true,
      digest: true,
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
            |> Map.merge(%{held: 0, hold_reasons: %{}})

          nil ->
            %{delivered: 0, failed: length(candidates), held: 0, hold_reasons: %{}}
        end

      {:ok, %{decision: "held_rate_limit", reason: reason}} ->
        hold_digest_candidates(candidates, reason)
        %{delivered: 0, failed: 0, held: length(candidates), hold_reasons: %{reason => length(candidates)}}

      {:ok, _result} ->
        hold_digest_candidates(candidates, "unknown")
        %{delivered: 0, failed: 0, held: length(candidates), hold_reasons: %{"unknown" => length(candidates)}}

      {:error, _reason} ->
        %{delivered: 0, failed: length(candidates), held: 0, hold_reasons: %{}}

      {:fallback, _reason} ->
        %{delivered: 0, failed: length(candidates), held: 0, hold_reasons: %{}}
    end
  end

  # The digest bundle itself was held (quiet hours; the hourly cap is
  # bypassed for digests). The bundled candidates go through the same "held"
  # fate as a model-chosen hold: they surface in the next morning brief
  # instead of being silently dropped.
  defp hold_digest_candidates(candidates, reason) do
    Enum.each(candidates, fn candidate ->
      {:ok, _candidate} = ProactiveQueue.mark_held(candidate)

      record_dispatch_decision(candidate, "proactive.held", "held", %{
        "decision" => "held_rate_limit",
        "hold_reason" => reason
      })
    end)
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
          maybe_mark_brief_delivered(candidate)
          maybe_mark_insight_delivery_sent(candidate)
          record_merged_receipt(candidate, turn.id)
          record_dispatch_decision(candidate, "proactive.sent", "sent", %{"decision" => "merged"})
          todo_counts = send_candidate_todo_cards(conversation, candidate)
          %{acc | delivered: acc.delivered + 1, failed: acc.failed + todo_counts.failed}

        {:error, _reason} ->
          %{acc | failed: acc.failed + 1}
      end
    end)
  end

  # The proactive-candidate queue tracks its own delivery status, but the
  # underlying Brief record (surfaced on the Briefing page and retried by
  # Briefs.dispatch_telegram_batch while "pending") must also reflect a
  # successful send — otherwise it stays "pending" forever even though the
  # content already reached the operator.
  defp maybe_mark_brief_delivered(%ProactiveCandidate{source: "brief", source_id: brief_id})
       when is_binary(brief_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(brief_id),
         %Brief{} = brief <- Repo.get(Brief, brief_id) do
      result =
        brief
        |> Ecto.Changeset.change(%{
          status: "sent",
          sent_at: brief.sent_at || DateTime.utc_now(),
          error_message: nil
        })
        |> Repo.update()

      # SPEC 08 R2 finding 1 (planner-path gap): this call site is the
      # DeliveryPlanner equivalent of PushBroker.mark_brief_sent/2 and
      # mark_brief_delivered_elsewhere/1 — it only runs once the brief is
      # confirmed delivered (sent_now, suppressed-duplicate, or merged into a
      # digest; never on held/failed). Held items folded into the brief's
      # prompt (brief.metadata["held_interruption_ids"]) must flip to
      # "delivered" here too, or they never leave "held" status when the
      # planner (not the legacy path) is the one confirming delivery.
      PushBroker.mark_held_interruptions_delivered(brief)

      result
    else
      _other -> :ok
    end
  rescue
    _error -> :ok
  end

  defp maybe_mark_brief_delivered(_candidate), do: :ok

  # SPEC 02 R6: the insight-side sibling of maybe_mark_brief_delivered/1.
  # `PushBroker.enqueue_insight_candidate/1` sets `source_id: delivery.id`
  # directly (same shape brief candidates use), so the id is already the
  # Delivery primary key — no need to read structured_data (which may be
  # nil/missing keys). Without this, the planner path never advances the
  # `Delivery` off "pending" and `InsightNotifier` re-selects it every 60s,
  # minting a fresh ProactiveCandidate (and a plan_delivery model call)
  # forever. Only "pending"/"failed" rows are flipped: feedback statuses
  # (`feedback_helpful`/`feedback_not_helpful`) already prove delivery and
  # must not be clobbered back to "sent".
  defp maybe_mark_insight_delivery_sent(%ProactiveCandidate{
         source: "insight",
         source_id: delivery_id
       })
       when is_binary(delivery_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(delivery_id),
         %Delivery{status: status} = delivery when status in ["pending", "failed"] <-
           Repo.get(Delivery, delivery_id) do
      PushBroker.mark_insight_delivery_delivered_elsewhere(delivery)
      :ok
    else
      _other -> :ok
    end
  rescue
    # A delivery-marking failure must never fail the candidate's own
    # successful send (same contract as maybe_mark_brief_delivered/1).
    _error -> :ok
  end

  defp maybe_mark_insight_delivery_sent(_candidate), do: :ok

  defp mark_held(candidates) do
    Enum.reduce(candidates, 0, fn candidate, count ->
      record_dispatch_decision(candidate, "proactive.held", "held", %{
        "decision" => "model_hold",
        "hold_reason" => "model_hold",
        "model_reason" => candidate.plan_reason
      })

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
      title: candidate_title(candidate),
      body: delivery_text(candidate.body),
      urgency: candidate.urgency,
      interrupt_now: Keyword.get(opts, :interrupt_now, false),
      # Cadence briefs are an explicit subscription (see resolve_disposition/2
      # above) — they should not be silently dropped by the shared hourly
      # interruption budget the way an opportunistic insight push can be.
      # They still fully respect quiet hours and true duplicate-receipt
      # suppression at PushBroker send time (see interruption_hold_reason/1
      # in push_broker.ex).
      bypass_budget_cap: candidate.source == "brief",
      why_now: candidate_why_now(candidate),
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
               preserve_safe_label_prefixes: true,
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
    (candidate.structured_data || %{})
    |> Map.merge(%{
      "title" => candidate_title(candidate),
      "why_now" => candidate_why_now(candidate),
      "urgency" => candidate.urgency
    })
  end

  defp candidate_title(%ProactiveCandidate{source: "brief", title: title}) do
    Briefs.public_title(title)
  end

  defp candidate_title(%ProactiveCandidate{title: title}), do: delivery_text(title)

  defp candidate_why_now(%ProactiveCandidate{source: "brief", why_now: why_now}) do
    Briefs.public_summary(why_now)
  end

  defp candidate_why_now(%ProactiveCandidate{why_now: why_now}), do: delivery_text(why_now)

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

  defp record_planning_decision(user_id, candidates, plan, counts, payload, dispatch_counts) do
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
          Map.get(payload, :interruption_budget) || payload["interruption_budget"],
        # Enforced outcome (post send-time gate), distinct from the
        # model's plan-time counts above.
        "enforced_delivered_count" => Map.get(dispatch_counts, :delivered, 0),
        "enforced_held_count" => Map.get(dispatch_counts, :held, 0),
        "enforced_failed_count" => Map.get(dispatch_counts, :failed, 0),
        "enforced_hold_reasons" => Map.get(dispatch_counts, :hold_reasons, %{})
      }
    })

    :ok
  rescue
    _error -> :ok
  end

  defp record_dispatch_decision(%ProactiveCandidate{} = candidate, event_type, status, metadata) do
    ActionLedger.record(%{
      user_id: candidate.user_id,
      surface: "telegram",
      event_type: event_type,
      status: status,
      source_evidence: %{
        "candidate_id" => candidate.id,
        "dedupe_key" => candidate.dedupe_key,
        "source" => candidate.source,
        "source_id" => candidate.source_id
      },
      model_summary: candidate_why_now(candidate),
      result_object_refs: %{
        "candidate_id" => candidate.id,
        "dedupe_key" => candidate.dedupe_key
      },
      metadata: Map.merge(metadata, %{"urgency" => candidate.urgency})
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
        inserted_at: local_display(receipt.inserted_at, user_id)
      }
    end)
  end

  # Bug fix: recent push receipts and candidate timestamps were shown to the
  # planning model as bare UTC ISO-8601 (e.g. "2026-07-03T09:21:00Z"). In
  # production the model read a 09:21 UTC receipt as 09:21 *local* (it was
  # actually 5:21 AM local) and used that misreading to justify holding the
  # morning brief as a fatigue duplicate. Render an explicit local-time
  # label instead, from the same offset source PushBroker.local_now_for_user/1
  # and the context current_time block use, so the model cannot misread the
  # timezone.
  defp local_display(%DateTime{} = datetime, user_id) do
    offset_hours =
      user_id
      |> BriefingSchedules.summarize_for_prompt()
      |> Map.get(:timezone_offset_hours, -5)
      |> case do
        value when is_integer(value) -> value
        _other -> -5
      end

    local = DateTime.add(datetime, offset_hours, :hour)
    label = if offset_hours >= 0, do: "UTC+#{offset_hours}", else: "UTC#{offset_hours}"

    "#{Calendar.strftime(local, "%Y-%m-%d %H:%M")} local (#{label})"
  end

  defp local_display(_datetime, _user_id), do: nil

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

  # PushBroker.quiet_hours?/1 compares the datetime's `.hour` against local
  # quiet-hour thresholds, so it must be given the operator's local wall
  # clock (context.ex's `local_now`), not `now_utc` — passing the UTC value
  # here previously compared a UTC hour against local thresholds. When
  # `local_now` is missing or malformed, fall back through
  # `PushBroker.local_now_for_user/1` (the same source the send-time
  # enforcement gate uses) instead of `DateTime.utc_now/0`, so this advisory
  # budget shown to the model agrees with what actually gates the send.
  defp now_from_context(context, user_id) when is_map(context) do
    context
    |> read_field("current_time")
    |> read_field("local_now")
    |> parse_datetime(user_id)
  end

  defp now_from_context(_context, user_id), do: PushBroker.local_now_for_user(user_id)

  defp parse_datetime(value, user_id) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> PushBroker.local_now_for_user(user_id)
    end
  end

  defp parse_datetime(%DateTime{} = datetime, _user_id), do: datetime
  defp parse_datetime(_value, user_id), do: PushBroker.local_now_for_user(user_id)

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
