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
  alias Maraithon.DeliveryErrorCopy
  alias Maraithon.InsightFeedback
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.InsightNotifications.MemoryGate
  alias Maraithon.PromptBudget
  alias Maraithon.Redaction
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

  require Logger

  @default_batch_size 25
  @max_batch_size 100
  @max_explicit_user_scan 1_000
  @recent_push_limit 8
  @candidate_acquisition_limit 50
  @max_candidate_todo_ids 64
  @max_context_todos_for_ranking 200
  @max_ranking_todo_bytes 6_000
  @max_ranking_metadata_bytes 3_000
  @ranking_todo_fields [
    {"id", 255},
    {"title", 500},
    {"summary", 700},
    {"next_action", 500},
    {"notes", 500},
    {"action_plan", 500},
    {"metadata", @max_ranking_metadata_bytes},
    {"due_at", 100},
    {"source_occurred_at", 100},
    {"inserted_at", 100},
    {"updated_at", 100},
    {"priority", 30},
    {"direction", 50},
    {"owner_label", 200},
    {"source_account_label", 200},
    {"relationship_strength", 30},
    {"status", 50}
  ]
  @context_todo_bucket_keys ~w(overdue today upcoming no_due_date monitor snoozed todos work)
  @max_prompt_candidates 12
  @max_required_prompt_candidates 8
  @delivery_base_prompt_bytes 40_000
  @candidate_prompt_body_bytes 2_000
  @candidate_prompt_why_now_bytes 1_000
  @candidate_prompt_related_todo_limit 5
  @candidate_prompt_snapshot_bytes 3_000
  @candidate_prompt_snapshot_fields [
    {"id", 500},
    {"source", 100},
    {"source_id", 500},
    {"dedupe_key", 500},
    {"title", 500},
    {"body", 2_000},
    {"urgency", 100},
    {"why_now", 1_000},
    {"inserted_at", 100},
    {"expires_at", 100},
    {"planning_rank", 100},
    {"attention_profile", 900},
    {"related_todos", 3_000},
    {"structured_data", 2_000}
  ]
  @delivery_prompt_context_bytes 20_000
  @delivery_prompt_context_fields [
    {"preference_memory", 2_500},
    {"operator_memory", 1_500},
    {"user_memory", 1_500},
    {"user", 1_500},
    {"current_time", 500},
    {"todos", 3_000},
    {"calendar", 2_500},
    {"relationships", 2_500},
    {"open_loops", 2_500},
    {"goals", 1_500},
    {"projects", 1_500},
    {"briefing_schedule", 750},
    {"source_freshness", 750},
    {"defaults", 500},
    {"context_fetch", 500}
  ]
  @operator_feedback_prompt_bytes 4_000
  @interrupt_memory_prompt_bytes 8_000
  @recent_pushes_prompt_bytes 4_000
  @candidate_structured_data_bytes 4_000
  @operator_feedback_fields [
    {"preference_profile", 900},
    {"user_memory_profile", 900},
    {"bad_interruption_examples", 1_000},
    {"good_interruption_examples", 1_000},
    {"threshold_profile", 200}
  ]
  @interrupt_memory_fields [
    {"memories", 6_500},
    {"summary", 1_000},
    {"count", 100}
  ]
  @prompt_structured_data_keys ~w(
    brief_cadence brief_type linked_delivery_id linked_insight_id linked_project
    message_class nudge_reason todo_count todo_ids travel_itinerary_id
  )

  def run_for_due_users(opts \\ []) when is_list(opts) do
    batch_size =
      opts
      |> Keyword.get(:batch_size, @default_batch_size)
      |> positive_integer()
      |> min(@max_batch_size)

    user_ids = due_user_ids(Keyword.get(opts, :user_ids), batch_size)

    summary =
      Enum.reduce(user_ids, empty_due_summary(), fn user_id, acc ->
        case safe_run_for_user(user_id, opts) do
          {:ok, result} ->
            _ = ProactiveQueue.rotate_pending_user(user_id)

            failure_codes =
              acc.failure_codes
              |> increment_failure_code("dispatch_failed", result.failed)
              |> increment_failure_code("delivery_unknown", result.delivery_unknown)

            %{
              acc
              | users: acc.users + 1,
                planned: acc.planned + result.planned,
                interrupt_now: acc.interrupt_now + result.interrupt_now,
                digest: acc.digest + result.digest,
                held: acc.held + result.held,
                delivered: acc.delivered + result.delivered,
                delivery_unknown: acc.delivery_unknown + result.delivery_unknown,
                failed: acc.failed + result.failed,
                failure_codes: failure_codes
            }

          {:error, :no_push_device} ->
            _ = ProactiveQueue.rotate_pending_user(user_id)
            %{acc | users: acc.users + 1, undeliverable: acc.undeliverable + 1}

          {:error, reason} ->
            _ = ProactiveQueue.rotate_pending_user(user_id)
            failure_code = planning_failure_code(reason)

            Logger.warning("Proactive delivery planning failed",
              user_id_hash: Redaction.fingerprint(user_id),
              failure_code: failure_code
            )

            %{
              acc
              | users: acc.users + 1,
                failed: acc.failed + 1,
                failure_codes: increment_failure_code(acc.failure_codes, failure_code, 1)
            }
        end
      end)

    summary
  end

  defp due_user_ids(nil, batch_size),
    do: ProactiveQueue.pending_deliverable_user_ids(limit: batch_size)

  defp due_user_ids(user_ids, batch_size) when is_list(user_ids) do
    user_ids
    |> Enum.take(@max_explicit_user_scan)
    |> Stream.filter(&(is_binary(&1) and &1 != ""))
    |> Stream.uniq()
    |> Enum.take(batch_size)
  end

  defp due_user_ids(_user_ids, _batch_size), do: []

  defp safe_run_for_user(user_id, opts) do
    run_for_user(user_id, opts)
  rescue
    error -> {:error, {:planner_exception, error.__struct__}}
  catch
    kind, _reason -> {:error, {:planner_exit, kind}}
  end

  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    Tracing.with_span(
      "telegram_assistant.delivery_planner",
      %{user_id_hash: Redaction.fingerprint(user_id)},
      fn ->
        candidate_limit =
          opts
          |> Keyword.get(:candidate_limit, @candidate_acquisition_limit)
          |> positive_integer()
          |> min(@candidate_acquisition_limit)

        candidates =
          ProactiveQueue.list_pending_for_user(
            user_id,
            Keyword.put(opts, :candidate_limit, candidate_limit)
          )

        case candidates do
          [] ->
            {:ok, empty_user_summary(user_id)}

          [_ | _] ->
            with true <- deliverable?(user_id),
                 :plan <- quiet_hours_gate(user_id, candidates),
                 {:ok, payload, planning_candidates} <-
                   build_payload(user_id, nil, candidates, opts) do
              claim_and_run_plan(user_id, payload, planning_candidates, opts)
            else
              false ->
                {:error, :no_push_device}

              :defer_quiet_hours ->
                {:ok, empty_user_summary(user_id)}

              {:error, reason} ->
                {:error, reason}
            end
        end
      end
    )
  end

  def run_for_user(_user_id, _opts), do: {:error, :invalid_user}

  defp claim_and_run_plan(user_id, payload, planning_candidates, opts) do
    with {:ok, claim} <- ProactiveQueue.claim_pending(planning_candidates) do
      claimed_candidates =
        Enum.filter(planning_candidates, &MapSet.member?(claim.ids, &1.id))

      claimed_payload = %{
        payload
        | candidates:
            Enum.filter(payload.candidates, fn candidate ->
              MapSet.member?(claim.ids, read_field(candidate, "id"))
            end)
      }

      try do
        case claimed_candidates do
          [] ->
            {:ok, empty_user_summary(user_id)}

          _rows ->
            with {:ok, finalized_payload} <-
                   finalize_claimed_payload(user_id, claimed_payload, claimed_candidates, opts) do
              run_claimed_plan(
                user_id,
                finalized_payload,
                claimed_candidates,
                claim.token,
                opts
              )
            end
        end
      after
        _ = ProactiveQueue.release_claim(claim.token)
      end
    end
  end

  defp finalize_claimed_payload(user_id, reserved_payload, planning_candidates, opts) do
    reservation = Map.get(reserved_payload, :interrupt_memory, %{})

    interrupt_memory =
      user_id
      |> interrupt_memory_context(planning_candidates)
      |> interrupt_memory_prompt()

    payload = Map.put(reserved_payload, :interrupt_memory, interrupt_memory)
    prompt_bytes = AssistantHarness.delivery_plan_prompt_bytes(payload, opts)
    prompt_byte_cap = AssistantHarness.delivery_plan_prompt_byte_cap()

    if PromptBudget.encoded_bytes(interrupt_memory) <= PromptBudget.encoded_bytes(reservation) and
         prompt_bytes <= prompt_byte_cap do
      {:ok, payload}
    else
      {:error, {:delivery_plan_prompt_exceeds_budget, prompt_bytes, prompt_byte_cap}}
    end
  end

  defp run_claimed_plan(user_id, payload, planning_candidates, claim_token, opts) do
    with {:ok, raw_plan} <- AssistantHarness.plan_delivery(payload, opts) do
      plan =
        raw_plan
        |> ProactiveQualityGate.verify_delivery_plan(payload, opts)
        |> apply_interruption_budget_to_plan(payload)

      planned = persist_plan(planning_candidates, plan, payload, claim_token)
      counts = disposition_counts(planned)
      dispatch? = Keyword.get(opts, :dispatch, true)

      {planned, dispatch_counts} =
        if dispatch? do
          {authorized, lost_count} = authorize_dispatches(planned, claim_token)
          counts = dispatch(user_id, nil, authorized, plan, claim_token)
          {authorized, %{counts | failed: counts.failed + lost_count}}
        else
          relinquished = relinquish_plans(planned, plan, payload, claim_token)

          {relinquished,
           %{delivered: 0, delivery_unknown: 0, failed: 0, held: 0, hold_reasons: %{}}}
        end

      # Recorded after dispatch so this reflects the enforced outcome
      # (post budget/quiet-hours gate), not just the model's plan.
      record_planning_decision(
        user_id,
        planning_candidates,
        plan,
        counts,
        payload,
        dispatch_counts
      )

      {:ok,
       %{
         user_id: user_id,
         planned: length(planned),
         interrupt_now: counts.interrupt_now,
         digest: counts.digest,
         held: if(dispatch?, do: dispatch_counts.held, else: counts.hold),
         delivered: dispatch_counts.delivered,
         delivery_unknown: dispatch_counts.delivery_unknown,
         failed: dispatch_counts.failed
       }}
    end
  end

  # Quiet hours: the send-time gate (PushBroker.interruption_hold_reason/1)
  # would hold everything the model plans, so planning now only burns a
  # plan_delivery model call per cycle all night while the source keeps
  # re-minting candidates. Leave candidates "pending"; the first
  # post-quiet-hours cycle plans them. A candidate that qualifies for the
  # urgency exemption still plans — the gate would let it through.
  defp quiet_hours_gate(user_id, candidates) do
    budget = PushBroker.interruption_budget(user_id)
    exempt_threshold = PushBroker.urgency_exempt_threshold()

    if Map.get(budget, "quiet_hours") == true and
         not Enum.any?(candidates, &((&1.urgency || 0.0) >= exempt_threshold)) do
      Logger.debug("Delivery planning deferred for quiet hours",
        user_id_hash: Redaction.fingerprint(user_id),
        candidate_count: length(candidates)
      )

      :defer_quiet_hours
    else
      :plan
    end
  end

  defp build_payload(user_id, chat_id, candidates, opts) do
    context =
      Keyword.get(opts, :context) ||
        Context.build(%{
          user_id: user_id,
          chat_id: chat_id || "unavailable",
          request_focus: :delivery_planner
        })

    ranking_todos = context_todos(context)

    ranked_candidates =
      candidates
      |> rank_candidates(ranking_todos)
      |> Enum.with_index(1)

    recent_pushes =
      user_id
      |> recent_pushes(recent_push_limit(opts))
      |> PromptBudget.bounded(@recent_pushes_prompt_bytes)

    operator_feedback =
      user_id
      |> operator_feedback_examples()
      |> operator_feedback_prompt()

    memory_reservation = interrupt_memory_reservation()

    base_payload = %{
      user_id: provider_reference(user_id),
      chat_id: provider_reference(chat_id),
      candidates: [],
      context: %{},
      interrupt_memory: memory_reservation,
      interruption_budget:
        PushBroker.interruption_budget(user_id, now: now_from_context(context, user_id))
    }

    base_payload =
      base_payload
      |> put_optional_base_field(:operator_feedback, operator_feedback, opts)
      |> put_context_base_fields(delivery_prompt_context(context), opts)
      |> put_optional_base_field(:recent_pushes, recent_pushes, opts)

    select_prompt_candidates(
      ranked_candidates,
      base_payload,
      ranking_todos,
      opts
    )
  end

  # Selection reserves the maximum stable-encoded memory size first. We then
  # recall only against the exact candidates that fit and replace this private
  # placeholder with a no-larger semantic projection before the model call.
  # This avoids both candidate-memory mismatch and a second unstable fit pass.
  defp interrupt_memory_reservation do
    # The payload JSON is itself embedded as a JSON message string. A leading
    # ordinary byte makes the remaining parity exact, while backslashes reserve
    # the worst outer-escaping cost of any valid inner JSON projection.
    base = %{"reserved" => "x"}
    slash_count = div(@interrupt_memory_prompt_bytes - PromptBudget.encoded_bytes(base), 2)
    %{"reserved" => "x" <> String.duplicate("\\", slash_count)}
  end

  defp put_optional_base_field(payload, _key, nil, _opts), do: payload

  defp put_optional_base_field(payload, key, value, opts) do
    candidate = Map.put(payload, key, value)

    if AssistantHarness.delivery_plan_prompt_bytes(candidate, opts) <= @delivery_base_prompt_bytes,
      do: candidate,
      else: payload
  end

  defp put_context_base_fields(payload, context, opts) when is_map(context) do
    Enum.reduce(@delivery_prompt_context_fields, payload, fn {key, _field_bytes}, acc ->
      case Map.fetch(context, key) do
        {:ok, value} ->
          candidate_context = Map.put(Map.get(acc, :context, %{}), key, value)
          put_optional_base_field(acc, :context, candidate_context, opts)

        :error ->
          acc
      end
    end)
  end

  defp put_context_base_fields(payload, _context, _opts), do: payload

  defp select_prompt_candidates(
         ranked_candidates,
         base_payload,
         ranking_todos,
         opts
       ) do
    prompt_byte_cap = AssistantHarness.delivery_plan_prompt_byte_cap()
    ranked_candidates = reserve_compact_candidate_lane(ranked_candidates, ranking_todos)

    {reserved_payload, planning_candidates} =
      Enum.reduce_while(ranked_candidates, {base_payload, []}, fn {candidate, rank},
                                                                  {payload, selected} ->
        if length(selected) >= @max_prompt_candidates do
          {:halt, {payload, selected}}
        else
          snapshot = candidate_snapshot(candidate, ranking_todos, rank)
          candidate_payload = Map.update!(payload, :candidates, &(&1 ++ [snapshot]))

          if AssistantHarness.delivery_plan_prompt_bytes(candidate_payload, opts) <=
               prompt_byte_cap do
            {:cont, {candidate_payload, selected ++ [candidate]}}
          else
            {:cont, {payload, selected}}
          end
        end
      end)

    if planning_candidates == [] do
      prompt_bytes = AssistantHarness.delivery_plan_prompt_bytes(reserved_payload, opts)

      log_prompt_selection(
        ranked_candidates,
        planning_candidates,
        base_payload,
        prompt_bytes,
        opts
      )

      {:error, {:delivery_plan_prompt_exceeds_budget, prompt_bytes, prompt_byte_cap}}
    else
      prompt_bytes = AssistantHarness.delivery_plan_prompt_bytes(reserved_payload, opts)

      log_prompt_selection(
        ranked_candidates,
        planning_candidates,
        base_payload,
        prompt_bytes,
        opts
      )

      if prompt_bytes <= prompt_byte_cap do
        {:ok, reserved_payload, planning_candidates}
      else
        {:error, {:delivery_plan_prompt_exceeds_budget, prompt_bytes, prompt_byte_cap}}
      end
    end
  end

  defp reserve_compact_candidate_lane(ranked_candidates, ranking_todos)
       when is_list(ranked_candidates) do
    {reserved, remainder} = Enum.split(ranked_candidates, 3)

    case remainder do
      [] ->
        reserved

      _entries ->
        compact =
          Enum.min_by(remainder, fn {candidate, rank} ->
            candidate
            |> candidate_snapshot(ranking_todos, rank)
            |> PromptBudget.encoded_bytes()
          end)

        reserved ++ [compact] ++ List.delete(remainder, compact)
    end
  end

  defp log_prompt_selection(
         ranked_candidates,
         planning_candidates,
         base_payload,
         prompt_bytes,
         opts
       ) do
    Logger.info("Delivery planner bounded candidate prompt",
      available_candidates: length(ranked_candidates),
      included_candidates: length(planning_candidates),
      base_prompt_bytes: AssistantHarness.delivery_plan_prompt_bytes(base_payload, opts),
      prompt_bytes: prompt_bytes,
      prompt_byte_cap: AssistantHarness.delivery_plan_prompt_byte_cap()
    )
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
      |> Enum.take(12)
      |> Enum.map(fn candidate ->
        [
          candidate_title(candidate) |> prompt_text(180),
          candidate_why_now(candidate) |> prompt_text(220)
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(": ")
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" | ")
      |> PromptBudget.truncate_utf8(2_000)

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

  defp delivery_prompt_context(context) when is_map(context) do
    context
    |> Context.preproject_prompt_collections()
    |> PromptBudget.project_fields(
      @delivery_prompt_context_fields,
      @delivery_prompt_context_bytes,
      max_depth: 5,
      list_items: 5
    )
  end

  defp delivery_prompt_context(_context), do: %{}

  defp operator_feedback_prompt(feedback) when is_map(feedback) do
    PromptBudget.project_fields(
      feedback,
      @operator_feedback_fields,
      @operator_feedback_prompt_bytes
    )
  end

  defp operator_feedback_prompt(_feedback), do: %{}

  defp interrupt_memory_prompt(memory_context) when is_map(memory_context) do
    PromptBudget.project_fields(
      memory_context,
      @interrupt_memory_fields,
      @interrupt_memory_prompt_bytes
    )
  end

  defp interrupt_memory_prompt(_memory_context), do: %{}

  defp prompt_text(value, max_bytes) when is_binary(value) do
    PromptBudget.encoded_string(value, max_bytes)
  end

  defp prompt_text(_value, _max_bytes), do: nil

  defp candidate_snapshot(%ProactiveCandidate{} = candidate, ranking_todos, rank) do
    related_todos = related_todos(candidate, ranking_todos)
    profile = candidate_attention_profile(candidate, related_todos)

    snapshot = %{
      id: candidate.id,
      source: candidate.source,
      source_id: provider_reference(candidate.source_id),
      dedupe_key: provider_reference(candidate.dedupe_key),
      title: candidate_title(candidate) |> prompt_text(500),
      body: candidate.body |> delivery_text() |> prompt_text(@candidate_prompt_body_bytes),
      urgency: candidate.urgency,
      why_now:
        candidate
        |> candidate_why_now()
        |> prompt_text(@candidate_prompt_why_now_bytes),
      structured_data:
        candidate
        |> candidate_prompt_structured_data()
        |> PromptBudget.bounded(@candidate_structured_data_bytes),
      inserted_at: local_display(candidate.inserted_at, candidate.user_id),
      expires_at: local_display(candidate.expires_at, candidate.user_id),
      planning_rank: rank,
      attention_profile: profile,
      related_todos:
        related_todos
        |> Enum.take(@candidate_prompt_related_todo_limit)
        |> Enum.map(&compact_related_todo/1)
    }

    PromptBudget.project_fields(
      snapshot,
      @candidate_prompt_snapshot_fields,
      @candidate_prompt_snapshot_bytes
    )
  end

  defp rank_candidates(candidates, ranking_todos) when is_list(candidates) do
    {required, ordinary} = Enum.split_with(candidates, &(&1.source == "brief"))

    required =
      Enum.sort_by(required, fn candidate ->
        {timestamp_sort_value(candidate.inserted_at), candidate.id}
      end)

    semantic =
      Enum.sort_by(ordinary, fn candidate ->
        related_todos = related_todos(candidate, ranking_todos)
        profile = candidate_attention_profile(candidate, related_todos)

        {
          profile["bucket_rank"],
          -profile["score"],
          -timestamp_sort_value(candidate.inserted_at),
          candidate.id
        }
      end)

    required_head = Enum.take(required, @max_required_prompt_candidates)
    required_tail = Enum.drop(required, @max_required_prompt_candidates)
    open_slots = max(@max_prompt_candidates - length(required_head), 0)
    rotation_quota = if open_slots > 0, do: max(div(open_slots, 3), 1), else: 0
    priority_quota = max(open_slots - rotation_quota, 0)

    rotation =
      ordinary
      |> Enum.sort_by(fn candidate ->
        {timestamp_sort_value(candidate.inserted_at), candidate.id}
      end)
      |> Enum.take(rotation_quota)

    rotation_ids = MapSet.new(rotation, & &1.id)

    priority =
      semantic
      |> Enum.reject(&MapSet.member?(rotation_ids, &1.id))
      |> Enum.take(priority_quota)

    reserved_ids = MapSet.new(required ++ rotation ++ priority, & &1.id)
    remainder = Enum.reject(semantic, &MapSet.member?(reserved_ids, &1.id))

    # Put one durable oldest-row lane ahead of the semantic fill. Count-only
    # quotas do not guarantee fairness under a tight byte budget, while moving
    # every rotation row forward could crowd out all urgent work.
    Enum.take(required_head, 1) ++
      Enum.take(rotation, 1) ++
      Enum.take(priority, 1) ++
      Enum.drop(required_head, 1) ++
      Enum.drop(priority, 1) ++ required_tail ++ Enum.drop(rotation, 1) ++ remainder
  end

  defp related_todos(%ProactiveCandidate{} = candidate, ranking_todos)
       when is_list(ranking_todos) do
    structured_data = candidate.structured_data || %{}

    todo_ids =
      structured_data
      |> Map.get("todo_ids", [])
      |> case do
        ids when is_list(ids) -> Enum.take(ids, @max_candidate_todo_ids)
        _other -> []
      end
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 255))
      |> MapSet.new()

    if MapSet.size(todo_ids) == 0 do
      []
    else
      ranking_todos
      |> Enum.filter(fn todo ->
        case read_field(todo, "id") do
          id when is_binary(id) -> MapSet.member?(todo_ids, id)
          _ -> false
        end
      end)
      |> Enum.sort_by(&related_todo_sort_key/1)
    end
  end

  defp related_todo_sort_key(todo) do
    profile = AttentionRanker.profile(todo)

    {
      profile["bucket_rank"] || 99,
      -1 * (profile["score"] || 0),
      read_field(todo, "id") || ""
    }
  end

  defp context_todos(context) when is_map(context) do
    direct_todos =
      context
      |> read_field("todos")
      |> bounded_list(@max_context_todos_for_ranking)

    buckets =
      context
      |> read_field("open_loops")
      |> read_field("buckets")

    bucket_todos =
      Enum.reduce(@context_todo_bucket_keys, [], fn key, acc ->
        remaining = @max_context_todos_for_ranking - length(acc)

        if remaining > 0 do
          acc ++ (buckets |> read_field(key) |> bounded_list(remaining))
        else
          acc
        end
      end)

    (direct_todos ++ bucket_todos)
    |> Enum.filter(&is_map/1)
    |> Enum.map(&ranking_todo/1)
    |> Enum.uniq_by(&read_field(&1, "id"))
    |> Enum.sort_by(&related_todo_sort_key/1)
    |> Enum.take(@max_context_todos_for_ranking)
  end

  defp context_todos(_context), do: []

  defp ranking_todo(todo) do
    metadata =
      todo
      |> read_field("metadata")
      |> PromptBudget.bounded(@max_ranking_metadata_bytes,
        string_bytes: 300,
        list_items: 10,
        map_entries: 30,
        max_depth: 4,
        key_bytes: 64
      )

    todo
    |> Map.put("metadata", metadata || %{})
    |> PromptBudget.project_fields(@ranking_todo_fields, @max_ranking_todo_bytes,
      string_bytes: 700,
      list_items: 10,
      map_entries: 30,
      max_depth: 5,
      key_bytes: 64
    )
  end

  defp bounded_list(value, limit) when is_list(value), do: Enum.take(value, limit)
  defp bounded_list(_value, _limit), do: []

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
      "id" => read_field(todo, "id") |> prompt_text(255),
      "title" => read_field(todo, "title") |> prompt_text(255),
      "summary" => read_field(todo, "summary") |> prompt_text(500),
      "next_action" => read_field(todo, "next_action") |> prompt_text(500),
      "due_at" => read_field(todo, "due_at") |> PromptBudget.compact(),
      "source_occurred_at" => read_field(todo, "source_occurred_at") |> PromptBudget.compact(),
      "inserted_at" => read_field(todo, "inserted_at") |> PromptBudget.compact(),
      "attention_profile" => AttentionRanker.profile(todo) |> PromptBudget.compact(),
      "surface_quality" => SurfaceQuality.assess(todo) |> PromptBudget.compact()
    }
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :second)
  defp timestamp_sort_value(_datetime), do: 0

  defp age_days(%DateTime{} = datetime) do
    div(max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0), 86_400)
  end

  defp age_days(_datetime), do: 0

  defp persist_plan(candidates, plan, payload, claim_token) do
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

      _ = reason

      case ProactiveQueue.finalize_claim(candidate, claim_token, value) do
        {:ok, planned} -> [planned]
        {:error, _reason} -> []
      end
    end)
  end

  defp authorize_dispatches(candidates, claim_token) do
    Enum.reduce(candidates, {[], 0}, fn candidate, {authorized, lost} ->
      case ProactiveQueue.authorize_dispatch(candidate, claim_token) do
        {:ok, dispatching} -> {[dispatching | authorized], lost}
        {:error, _reason} -> {authorized, lost + 1}
      end
    end)
    |> then(fn {authorized, lost} -> {Enum.reverse(authorized), lost} end)
  end

  defp relinquish_plans(candidates, plan, payload, claim_token) do
    dispositions =
      plan
      |> Map.get("dispositions", [])
      |> Map.new(fn disposition -> {disposition["candidate_id"], disposition} end)

    candidates_by_id = Map.new(candidates, &{&1.id, &1})

    payload
    |> candidate_order()
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.flat_map(fn {candidate_id, _index} ->
      candidate = Map.get(candidates_by_id, candidate_id)
      disposition = Map.get(dispositions, candidate_id)

      if candidate do
        {value, reason} = resolve_disposition(candidate, disposition)

        case ProactiveQueue.relinquish_claim(candidate, claim_token, value, reason) do
          {:ok, relinquished} -> [relinquished]
          {:error, _reason} -> []
        end
      else
        []
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

  defp dispatch(user_id, chat_id, planned, plan, claim_token) do
    interrupt_now = Enum.filter(planned, &(&1.disposition == "interrupt_now"))
    digest = Enum.filter(planned, &(&1.disposition == "digest"))
    hold = Enum.filter(planned, &(&1.disposition == "hold"))

    interrupt_counts = dispatch_interrupts(interrupt_now, chat_id, claim_token)
    digest_counts = dispatch_digest(user_id, chat_id, digest, plan, claim_token)
    held_count = mark_held(hold, claim_token)

    %{
      delivered: interrupt_counts.delivered + digest_counts.delivered,
      delivery_unknown: interrupt_counts.delivery_unknown + digest_counts.delivery_unknown,
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

  defp dispatch_interrupts(candidates, chat_id, claim_token) do
    Enum.reduce(
      candidates,
      %{delivered: 0, delivery_unknown: 0, failed: 0, held: 0, hold_reasons: %{}},
      fn candidate, acc ->
        # Model chose interrupt_now at planning time, but PushBroker.deliver/1
        # still re-checks the hard budget gate at send time (R2): only a
        # genuinely high-urgency candidate skips the hourly cap/quiet hours.
        case PushBroker.deliver(push_candidate(candidate, chat_id, interrupt_now: true)) do
          {:ok, %{decision: "sent_now", conversation_id: conversation_id}} ->
            {:ok, _candidate} = ProactiveQueue.complete_claim(candidate, claim_token, "delivered")
            maybe_mark_brief_delivered(candidate)
            maybe_mark_insight_delivery_sent(candidate)
            maybe_send_candidate_todo_cards(conversation_id, candidate)

            record_dispatch_decision(candidate, "proactive.sent", "sent", %{
              "decision" => "sent_now"
            })

            %{acc | delivered: acc.delivered + 1}

          {:ok, %{decision: "sent_now"}} ->
            {:ok, _candidate} = ProactiveQueue.complete_claim(candidate, claim_token, "delivered")
            maybe_mark_brief_delivered(candidate)
            maybe_mark_insight_delivery_sent(candidate)

            record_dispatch_decision(candidate, "proactive.sent", "sent", %{
              "decision" => "sent_now"
            })

            %{acc | delivered: acc.delivered + 1}

          {:ok, %{decision: "suppressed", reason: "duplicate"}} ->
            # Already delivered under this dedupe_key through another path.
            {:ok, _candidate} = ProactiveQueue.complete_claim(candidate, claim_token, "delivered")
            maybe_mark_brief_delivered(candidate)
            maybe_mark_insight_delivery_sent(candidate)

            record_dispatch_decision(candidate, "proactive.sent", "sent", %{
              "decision" => "suppressed",
              "reason" => "duplicate"
            })

            %{acc | delivered: acc.delivered + 1}

          {:ok, %{decision: "delivery_unknown"}} ->
            count_unknown_quarantine(acc, candidate, claim_token)

          {:error, :delivery_unknown} ->
            count_unknown_quarantine(acc, candidate, claim_token)

          {:ok, %{decision: "held_rate_limit", reason: reason}} ->
            {:ok, _candidate} =
              ProactiveQueue.complete_claim(candidate, claim_token, "held", "held")

            record_dispatch_decision(candidate, "proactive.held", "held", %{
              "decision" => "held_rate_limit",
              "hold_reason" => reason
            })

            %{acc | held: acc.held + 1, hold_reasons: bump_reason(acc.hold_reasons, reason)}

          {:ok, _result} ->
            {:ok, _candidate} =
              ProactiveQueue.complete_claim(candidate, claim_token, "held", "held")

            record_dispatch_decision(candidate, "proactive.held", "held", %{
              "decision" => "unknown"
            })

            %{acc | held: acc.held + 1, hold_reasons: bump_reason(acc.hold_reasons, "unknown")}

          {:error, reason} ->
            requeue_failed_dispatch(candidate, reason, claim_token)
            %{acc | failed: acc.failed + 1}

          {:fallback, reason} ->
            requeue_failed_dispatch(candidate, reason, claim_token)
            %{acc | failed: acc.failed + 1}
        end
      end
    )
  end

  defp count_unknown_quarantine(acc, candidate, claim_token) do
    case quarantine_unknown_delivery(candidate, claim_token) do
      :ok ->
        %{
          acc
          | delivery_unknown: acc.delivery_unknown + 1,
            held: acc.held + 1,
            hold_reasons: bump_reason(acc.hold_reasons, "delivery_unknown")
        }

      {:error, _reason} ->
        %{
          acc
          | delivery_unknown: acc.delivery_unknown + 1,
            failed: acc.failed + 1,
            hold_reasons: bump_reason(acc.hold_reasons, "delivery_unknown_reconciliation_failed")
        }
    end
  end

  defp quarantine_unknown_delivery(candidate, claim_token) do
    result =
      Repo.transaction(fn ->
        with {:ok, _candidate} <-
               ProactiveQueue.complete_claim(candidate, claim_token, "held", "delivery_unknown"),
             :ok <- mark_source_delivery_unknown(candidate) do
          :ok
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :ok} ->
        record_dispatch_decision(candidate, "proactive.delivery_unknown", "unknown", %{
          "decision" => "delivery_unknown"
        })

        :ok

      {:error, reason} ->
        Logger.warning("Failed to quarantine ambiguous proactive delivery",
          candidate_reference: Redaction.fingerprint(candidate.id),
          failure_code: Redaction.error_class(reason)
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("Ambiguous proactive delivery quarantine crashed",
        candidate_reference: Redaction.fingerprint(candidate.id),
        failure_code: Redaction.error_class(error)
      )

      {:error, :quarantine_failed}
  end

  defp mark_source_delivery_unknown(%ProactiveCandidate{source: "brief", source_id: source_id})
       when is_binary(source_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(source_id) do
      Brief
      |> where([brief], brief.id == ^source_id)
      |> where([brief], brief.status in ["pending", "sent", "failed"])
      |> Repo.update_all(
        set: [
          status: "failed",
          error_message: DeliveryErrorCopy.storage_message(:delivery_unknown),
          provider_message_id: nil,
          sent_at: nil,
          updated_at: DateTime.utc_now()
        ]
      )
      |> source_quarantine_result()
    else
      _invalid_id -> :ok
    end
  end

  defp mark_source_delivery_unknown(%ProactiveCandidate{source: "insight", source_id: source_id})
       when is_binary(source_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(source_id) do
      Delivery
      |> where([delivery], delivery.id == ^source_id)
      |> where([delivery], delivery.status in ["pending", "sent", "failed"])
      |> Repo.update_all(
        set: [
          status: "failed",
          error_message: DeliveryErrorCopy.storage_message(:delivery_unknown),
          provider_message_id: nil,
          sent_at: nil,
          updated_at: DateTime.utc_now()
        ]
      )
      |> source_quarantine_result()
    else
      _invalid_id -> :ok
    end
  end

  defp mark_source_delivery_unknown(_candidate), do: :ok

  defp source_quarantine_result({count, _rows}) when count in 0..1, do: :ok
  defp source_quarantine_result(_unexpected), do: {:error, :source_quarantine_failed}

  defp resolve_unknown_digest(user_id, digest_key, candidates, claim_token) do
    {ambiguous, later} = partition_unknown_digest_candidates(user_id, digest_key, candidates)

    if later != [] do
      hold_digest_candidates(later, "daily_digest_delivery_unknown", claim_token)
    end

    quarantine_results = Enum.map(ambiguous, &quarantine_unknown_delivery(&1, claim_token))
    quarantined = Enum.count(quarantine_results, &(&1 == :ok))
    reconciliation_failures = length(quarantine_results) - quarantined

    reasons =
      %{}
      |> maybe_put_count("delivery_unknown", quarantined)
      |> maybe_put_count("delivery_unknown_reconciliation_failed", reconciliation_failures)
      |> maybe_put_count("daily_digest_delivery_unknown", length(later))

    %{
      delivered: 0,
      delivery_unknown: length(ambiguous),
      failed: reconciliation_failures,
      held: quarantined + length(later),
      hold_reasons: reasons
    }
  end

  defp partition_unknown_digest_candidates(user_id, digest_key, candidates) do
    case Repo.get_by(PushReceipt,
           user_id: user_id,
           dedupe_key: digest_key,
           decision: "delivery_unknown"
         ) do
      %PushReceipt{metadata: %{"candidate_dedupe_hashes" => hashes}} ->
        case valid_digest_dedupe_hashes(hashes) do
          {:ok, original_hashes} ->
            Enum.split_with(candidates, fn candidate ->
              MapSet.member?(original_hashes, PushReceipt.dedupe_hash(candidate.dedupe_key))
            end)

          :error ->
            {candidates, []}
        end

      # Transitional receipts may have candidate UUIDs but predate durable
      # dedupe hashes. UUID matching is safe for the original rows; missing or
      # malformed membership remains conservative below.
      %PushReceipt{metadata: %{"candidate_ids" => ids}} ->
        case valid_digest_candidate_ids(ids) do
          {:ok, original_ids} ->
            Enum.split_with(candidates, &MapSet.member?(original_ids, &1.id))

          :error ->
            {candidates, []}
        end

      _legacy_or_invalid ->
        # Older receipts did not retain bundle membership. Treat every
        # current candidate as possibly sent rather than risk a resend.
        {candidates, []}
    end
  end

  defp valid_digest_dedupe_hashes(hashes) when is_list(hashes) do
    hashes
    |> Enum.take(51)
    |> Enum.reduce_while({:ok, MapSet.new(), 0}, fn hash, {:ok, acc, count} ->
      if valid_digest_dedupe_hash?(hash) do
        {:cont, {:ok, MapSet.put(acc, hash), count + 1}}
      else
        {:halt, :error}
      end
    end)
    |> case do
      {:ok, hashes, count} when count in 1..50 -> {:ok, hashes}
      _invalid -> :error
    end
  rescue
    _error -> :error
  end

  defp valid_digest_dedupe_hashes(_hashes), do: :error

  defp valid_digest_dedupe_hash?(hash)
       when is_binary(hash) and byte_size(hash) == 64 do
    String.valid?(hash) and String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_digest_dedupe_hash?(_hash), do: false

  defp valid_digest_candidate_ids(ids) when is_list(ids) do
    ids
    |> Enum.take(51)
    |> Enum.reduce_while({:ok, MapSet.new(), 0}, fn id, {:ok, acc, count} ->
      case Ecto.UUID.cast(id) do
        {:ok, normalized} -> {:cont, {:ok, MapSet.put(acc, normalized), count + 1}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids, count} when count in 1..50 -> {:ok, ids}
      _invalid -> :error
    end
  rescue
    _error -> :error
  end

  defp valid_digest_candidate_ids(_ids), do: :error

  defp maybe_put_count(counts, _reason, 0), do: counts
  defp maybe_put_count(counts, reason, count), do: Map.put(counts, reason, count)

  # A dispatch failure (a transient APNs error, the broker disabled) must
  # not leave the candidate in "planned" — no process re-reads that status,
  # so it would strand there (dedupe-blocking its source from re-enqueueing)
  # until the TTL sweep. Back to "pending": the next planner cycle retries,
  # bounded by expires_at.
  defp requeue_failed_dispatch(%ProactiveCandidate{} = candidate, reason, claim_token) do
    case ProactiveQueue.complete_claim(candidate, claim_token, "pending") do
      {:ok, _candidate} ->
        :ok

      {:error, requeue_error} ->
        Logger.warning("Failed to return candidate to pending after dispatch failure",
          candidate_reference: Redaction.fingerprint(candidate.id),
          failure_code: Redaction.error_class(requeue_error)
        )
    end

    Logger.warning("Proactive dispatch failed; candidate returned to pending for retry",
      candidate_reference: Redaction.fingerprint(candidate.id),
      failure_code: Redaction.error_class(reason)
    )

    :ok
  end

  defp bump_reason(reasons, reason) when is_map(reasons) and is_binary(reason) do
    Map.update(reasons, reason, 1, &(&1 + 1))
  end

  defp bump_reason(reasons, _reason), do: reasons

  defp dispatch_digest(_user_id, _chat_id, [], _plan, _claim_token),
    do: %{delivered: 0, delivery_unknown: 0, failed: 0, held: 0, hold_reasons: %{}}

  defp dispatch_digest(user_id, chat_id, candidates, plan, claim_token) do
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
      receipt_metadata: %{
        "candidate_ids" => Enum.map(candidates, & &1.id),
        "candidate_dedupe_hashes" => Enum.map(candidates, &PushReceipt.dedupe_hash(&1.dedupe_key))
      },
      telegram_opts: [parse_mode: "HTML"]
    }

    case PushBroker.deliver(parent_candidate) do
      {:ok, %{decision: "sent_now", conversation_id: conversation_id}} ->
        case load_conversation(conversation_id) do
          %Conversation{} = conversation ->
            send_digest_cards(conversation, candidates, claim_token)
            |> Map.merge(%{delivery_unknown: 0, held: 0, hold_reasons: %{}})

          nil ->
            # Mobile path: the digest push IS the delivery — there is no
            # Telegram conversation to fan per-candidate cards into. The
            # user has been notified, so every bundled candidate is
            # delivered (leaving them "planned" here stranded them while
            # the phone had already buzzed — the 2026-07-30 stuck-briefs
            # incident).
            mark_digest_delivered(candidates, claim_token)
        end

      {:ok, %{decision: "delivery_unknown"}} ->
        resolve_unknown_digest(user_id, digest_key, candidates, claim_token)

      {:error, :delivery_unknown} ->
        resolve_unknown_digest(user_id, digest_key, candidates, claim_token)

      {:ok, %{decision: "held_rate_limit", reason: reason}} ->
        hold_digest_candidates(candidates, reason, claim_token)

        %{
          delivered: 0,
          delivery_unknown: 0,
          failed: 0,
          held: length(candidates),
          hold_reasons: %{reason => length(candidates)}
        }

      {:ok, _result} ->
        hold_digest_candidates(candidates, "unknown", claim_token)

        %{
          delivered: 0,
          delivery_unknown: 0,
          failed: 0,
          held: length(candidates),
          hold_reasons: %{"unknown" => length(candidates)}
        }

      {:error, reason} ->
        Enum.each(candidates, &requeue_failed_dispatch(&1, reason, claim_token))

        %{
          delivered: 0,
          delivery_unknown: 0,
          failed: length(candidates),
          held: 0,
          hold_reasons: %{}
        }

      {:fallback, reason} ->
        Enum.each(candidates, &requeue_failed_dispatch(&1, reason, claim_token))

        %{
          delivered: 0,
          delivery_unknown: 0,
          failed: length(candidates),
          held: 0,
          hold_reasons: %{}
        }
    end
  end

  # The delivered contract of send_digest_cards/2 without the Telegram card
  # fan-out: candidate status, brief/insight source rows, merged receipts,
  # and the ledger trail all advance exactly as they do on the card path.
  defp mark_digest_delivered(candidates, claim_token) do
    Enum.each(candidates, fn candidate ->
      {:ok, _candidate} = ProactiveQueue.complete_claim(candidate, claim_token, "delivered")
      maybe_mark_brief_delivered(candidate)
      maybe_mark_insight_delivery_sent(candidate)
      record_merged_receipt(candidate, nil)
      record_dispatch_decision(candidate, "proactive.sent", "sent", %{"decision" => "merged"})
    end)

    %{
      delivered: length(candidates),
      delivery_unknown: 0,
      failed: 0,
      held: 0,
      hold_reasons: %{}
    }
  end

  # The digest bundle itself was held (quiet hours; the hourly cap is
  # bypassed for digests). The bundled candidates go through the same "held"
  # fate as a model-chosen hold: they surface in the next morning brief
  # instead of being silently dropped.
  defp hold_digest_candidates(candidates, reason, claim_token) do
    Enum.each(candidates, fn candidate ->
      {:ok, _candidate} = ProactiveQueue.complete_claim(candidate, claim_token, "held", reason)

      record_dispatch_decision(candidate, "proactive.held", "held", %{
        "decision" => "held_rate_limit",
        "hold_reason" => reason
      })
    end)
  end

  defp send_digest_cards(%Conversation{} = conversation, candidates, claim_token) do
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
          {:ok, _candidate} = ProactiveQueue.complete_claim(candidate, claim_token, "delivered")
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
      PushBroker.note_travel_brief_delivered(brief)

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

  defp mark_held(candidates, claim_token) do
    Enum.reduce(candidates, 0, fn candidate, count ->
      record_dispatch_decision(candidate, "proactive.held", "held", %{
        "decision" => "model_hold",
        "hold_reason" => "model_hold",
        "model_reason" => "model_hold"
      })

      case ProactiveQueue.complete_claim(candidate, claim_token, "held", "model_hold") do
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

  # No catch-all on purpose: an unknown candidate source is a programming
  # error and every addition to ProactiveCandidate.@sources MUST add a clause
  # here — a missing clause raises FunctionClauseError inside dispatch and
  # takes down the whole user's delivery batch (SPEC 01 edge cases).
  defp origin_type(%ProactiveCandidate{source: "insight"}), do: "insight"
  defp origin_type(%ProactiveCandidate{source: "brief"}), do: "brief"
  defp origin_type(%ProactiveCandidate{source: "proactive_check_in"}), do: "assistant_digest"
  defp origin_type(%ProactiveCandidate{source: "nudge"}), do: "nudge"

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

  defp candidate_prompt_structured_data(%ProactiveCandidate{} = candidate) do
    structured_data =
      case candidate.structured_data do
        value when is_map(value) -> Map.take(value, @prompt_structured_data_keys)
        _other -> %{}
      end

    Map.merge(structured_data, candidate_derived_structured_data(candidate))
  end

  defp candidate_structured_data(%ProactiveCandidate{} = candidate) do
    structured_data =
      if is_map(candidate.structured_data), do: candidate.structured_data, else: %{}

    Map.merge(structured_data, candidate_derived_structured_data(candidate))
  end

  defp candidate_derived_structured_data(%ProactiveCandidate{} = candidate) do
    %{
      "title" => candidate_title(candidate),
      "why_now" => candidate_why_now(candidate),
      "urgency" => candidate.urgency
    }
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

  defp recent_push_limit(opts) do
    case Keyword.get(opts, :recent_push_limit, @recent_push_limit) do
      limit when is_integer(limit) and limit > 0 -> min(limit, 50)
      _other -> @recent_push_limit
    end
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
        dedupe_key: provider_reference(receipt.dedupe_key),
        origin_type: receipt.origin_type,
        origin_id: provider_reference(receipt.origin_id),
        decision: receipt.decision,
        inserted_at: local_display(receipt.inserted_at, user_id)
      }
    end)
  end

  defp provider_reference(value) when is_binary(value) do
    "ref_" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  end

  defp provider_reference(value) when is_integer(value),
    do: provider_reference(Integer.to_string(value))

  defp provider_reference(_value), do: nil

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

  # Telegram is retired; planning proceeds only for users whose phone can
  # receive the result. Candidates for everyone else stay pending until a
  # device registers (or they expire on the queue's own TTL).
  defp deliverable?(user_id) do
    Maraithon.Push.Notifier.enabled_for_user?(user_id)
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

  defp planning_failure_code({:prompt_exceeds_budget, _kind, _bytes, _cap}),
    do: "prompt_exceeds_budget"

  defp planning_failure_code({:delivery_plan_prompt_exceeds_budget, _bytes, _cap}),
    do: "prompt_exceeds_budget"

  defp planning_failure_code({:invalid_response, _summary}), do: "provider_invalid_response"
  defp planning_failure_code({:http_status, status, _body}), do: api_failure_code(status)
  defp planning_failure_code({:api_error, status, _body}), do: api_failure_code(status)
  defp planning_failure_code({:network_error, _reason}), do: "network_error"
  defp planning_failure_code({:planner_exception, _error_class}), do: "planner_exception"
  defp planning_failure_code({:planner_exit, _kind}), do: "planner_exit"
  defp planning_failure_code({:insufficient_quota, _message}), do: "insufficient_quota"
  defp planning_failure_code({:rate_limited, _retry_after}), do: "rate_limited"
  defp planning_failure_code({:llm_busy, _retry_after}), do: "provider_busy"
  defp planning_failure_code({:error, reason}), do: planning_failure_code(reason)
  defp planning_failure_code(:timeout), do: "timeout"

  defp planning_failure_code(reason) when is_atom(reason) do
    if reason |> Atom.to_string() |> String.starts_with?("assistant_harness_") do
      "invalid_model_response"
    else
      "unknown"
    end
  end

  defp planning_failure_code(_reason), do: "unknown"

  defp api_failure_code(status) when is_integer(status) and status >= 400 and status <= 599,
    do: "api_#{status}"

  defp api_failure_code(_status), do: "api_error"

  defp increment_failure_code(failure_codes, _failure_code, count) when count <= 0,
    do: failure_codes

  defp increment_failure_code(failure_codes, failure_code, count) do
    Map.update(failure_codes, failure_code, count, &(&1 + count))
  end

  defp empty_due_summary do
    %{
      users: 0,
      planned: 0,
      interrupt_now: 0,
      digest: 0,
      held: 0,
      delivered: 0,
      delivery_unknown: 0,
      failed: 0,
      undeliverable: 0,
      failure_codes: %{}
    }
  end

  defp empty_user_summary(user_id) do
    %{
      user_id: user_id,
      planned: 0,
      interrupt_now: 0,
      digest: 0,
      held: 0,
      delivered: 0,
      delivery_unknown: 0,
      failed: 0
    }
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) and byte_size(value) <= 16 do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_batch_size
    end
  end

  defp positive_integer(_value), do: @default_batch_size

  defp read_field(%_{} = struct, key), do: read_field(Map.from_struct(struct), key)

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_existing_atom_key(map, key)
    end
  end

  defp read_field(_map, _key), do: nil

  defp fetch_existing_atom_key(map, key) do
    case Map.fetch(map, String.to_existing_atom(key)) do
      {:ok, value} -> value
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

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
