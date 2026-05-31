defmodule Maraithon.AssistantHarness do
  @moduledoc """
  Model-first assistant harness policy for user-facing chat loops.

  This module owns the model-facing contract: request construction, runtime
  policy, tool-call limits, prompt assembly, and JSON response validation. The
  durable event loop lives in `Maraithon.TelegramAssistant.Runner`, which uses
  this policy to call the model, execute tools, persist steps, and continue
  until the model returns a final answer.
  """

  alias Maraithon.AssistantHarness.{PromptStability, ToolLoopClassifier}
  alias Maraithon.LLM

  @contract_version 2
  @default_max_llm_turns 6
  @default_max_tool_steps 10
  @default_max_wall_clock_ms 25_000
  @default_chat_max_tokens 1_800
  @default_proactive_max_tokens 1_200
  @default_temperature 0.2
  @default_reasoning_effort "low"
  @max_tool_calls_per_step 3
  @default_tool_repeat_guard_window 3
  @default_tool_history_limit 12
  @default_tool_result_string_chars 4_000
  @default_tool_result_list_items 20
  @default_tool_result_map_entries 40
  @default_model_failover_max_attempts 3
  @default_model_busy_max_retries 25
  @default_model_retry_base_delay_ms 250
  @default_model_retry_max_delay_ms 5_000
  @retryable_model_errors ~w(timeout llm_busy rate_limited network_error api_408 api_425 api_429 api_500 api_502 api_503 api_504 invalid_json missing_content)
  @valid_statuses ~w(tool_calls final)
  @valid_message_classes ~w(assistant_reply approval_prompt action_result system_notice todo_digest)
  @valid_proactive_decisions ~w(send_now hold)
  @valid_proactive_message_classes ~w(assistant_push todo_digest system_notice)
  @valid_delivery_dispositions ~w(interrupt_now digest hold)

  def runtime_policy(opts \\ []) when is_list(opts) do
    model_fallbacks = model_fallbacks(opts)

    %{
      contract_version: @contract_version,
      loop: %{
        max_llm_turns:
          policy_value(opts, :max_llm_turns, @default_max_llm_turns)
          |> positive_integer(@default_max_llm_turns),
        max_tool_steps:
          policy_value(opts, :max_tool_steps, @default_max_tool_steps)
          |> positive_integer(@default_max_tool_steps),
        max_wall_clock_ms:
          policy_value(opts, :max_wall_clock_ms, @default_max_wall_clock_ms)
          |> positive_integer(@default_max_wall_clock_ms)
      },
      tool_calls: %{
        max_per_step: @max_tool_calls_per_step,
        repeat_guard: %{
          enabled: true,
          window_size:
            policy_value(opts, :tool_repeat_guard_window, @default_tool_repeat_guard_window)
            |> positive_integer(@default_tool_repeat_guard_window)
        }
      },
      tool_evidence: %{
        history_limit:
          policy_value(opts, :tool_history_limit, @default_tool_history_limit)
          |> positive_integer(@default_tool_history_limit),
        max_string_chars:
          policy_value(opts, :tool_result_string_chars, @default_tool_result_string_chars)
          |> positive_integer(@default_tool_result_string_chars),
        max_list_items:
          policy_value(opts, :tool_result_list_items, @default_tool_result_list_items)
          |> positive_integer(@default_tool_result_list_items),
        max_map_entries:
          policy_value(opts, :tool_result_map_entries, @default_tool_result_map_entries)
          |> positive_integer(@default_tool_result_map_entries)
      },
      model_failover: %{
        enabled: model_fallbacks != [],
        max_attempts: model_failover_max_attempts(opts, model_fallbacks),
        fallback_count: length(model_fallbacks),
        retryable_errors: @retryable_model_errors
      },
      model_decision_contract: %{
        statuses: @valid_statuses,
        message_classes: @valid_message_classes
      },
      proactive_decision_contract: %{
        decisions: @valid_proactive_decisions,
        message_classes: @valid_proactive_message_classes
      },
      delivery_planning_contract: %{
        dispositions: @valid_delivery_dispositions
      },
      chat_request: %{
        max_tokens:
          policy_value(opts, :max_tokens, @default_chat_max_tokens)
          |> positive_integer(@default_chat_max_tokens),
        temperature:
          policy_value(opts, :temperature, @default_temperature)
          |> bounded_float(@default_temperature),
        reasoning_effort:
          policy_value(opts, :reasoning_effort, @default_reasoning_effort)
          |> non_empty_string(@default_reasoning_effort)
      },
      proactive_request: %{
        max_tokens:
          policy_value(
            opts,
            :proactive_max_tokens,
            policy_value(opts, :max_tokens, @default_proactive_max_tokens)
          )
          |> positive_integer(@default_proactive_max_tokens),
        temperature:
          policy_value(opts, :temperature, @default_temperature)
          |> bounded_float(@default_temperature),
        reasoning_effort:
          policy_value(opts, :reasoning_effort, @default_reasoning_effort)
          |> non_empty_string(@default_reasoning_effort)
      }
    }
  end

  def max_llm_turns(opts \\ []) when is_list(opts), do: runtime_policy(opts).loop.max_llm_turns
  def max_tool_steps(opts \\ []) when is_list(opts), do: runtime_policy(opts).loop.max_tool_steps

  def initial_loop_state do
    %{iteration: 1, llm_turns: 0, tool_steps: 0, tool_history: [], sequence: 1}
  end

  def build_loop_request_payload(runtime_context, state, opts \\ [])
      when is_map(runtime_context) and is_map(state) and is_list(opts) do
    policy = runtime_policy(opts)
    context = map_value(runtime_context, "context", %{})

    %{
      current_user_request: current_user_request(context),
      request_focus: normalize_focus(Keyword.get(opts, :request_focus)),
      context: focus_context(context, Keyword.get(opts, :context_scope)),
      tools: focus_tools(map_value(runtime_context, "tools", []), Keyword.get(opts, :tool_scope)),
      tool_history: compact_tool_history(map_value(state, "tool_history", []), policy),
      runtime_policy: policy,
      iteration: map_value(state, "iteration", 1),
      llm_turns: map_value(state, "llm_turns", 0),
      tool_steps: map_value(state, "tool_steps", 0)
    }
  end

  def guard_loop(state, started_monotonic_ms, opts \\ [])
      when is_map(state) and is_integer(started_monotonic_ms) and is_list(opts) do
    policy = runtime_policy(opts)
    now_monotonic_ms = Keyword.get(opts, :now_monotonic_ms, System.monotonic_time(:millisecond))

    cond do
      now_monotonic_ms - started_monotonic_ms >= policy.loop.max_wall_clock_ms ->
        {:error, :timeout}

      map_value(state, "llm_turns", 0) >= policy.loop.max_llm_turns ->
        {:error, :llm_turn_limit}

      map_value(state, "tool_steps", 0) >= policy.loop.max_tool_steps ->
        {:error, :tool_step_limit}

      true ->
        :ok
    end
  end

  def guard_tool_history(tool_history, opts \\ []) when is_list(tool_history) and is_list(opts) do
    policy = runtime_policy(opts)
    repeat_guard = policy.tool_calls.repeat_guard

    if repeat_guard.enabled do
      case ToolLoopClassifier.classify(tool_history, window_size: repeat_guard.window_size) do
        :ok ->
          :ok

        {:loop, loop} ->
          emit_tool_loop_telemetry(loop)

          {:error,
           {:assistant_harness_tool_loop_detected, loop.tool, loop.count, loop.class, loop}}
      end
    else
      :ok
    end
  end

  def execution_evidence(tool_history, opts \\ []) when is_list(tool_history) and is_list(opts) do
    compact_tool_history(tool_history, runtime_policy(opts))
  end

  def failure_message(:timeout) do
    "Maraithon saved what it found and stopped before making a weak call from incomplete evidence."
  end

  def failure_message(:llm_turn_limit) do
    "Maraithon saved what it found and stopped before repeating the same checks."
  end

  def failure_message(:tool_step_limit) do
    "Maraithon saved what it found and stopped before a complete answer would require more checking."
  end

  def failure_message({:llm_busy, _retry_after}) do
    "Maraithon saved the request and stopped before sending an answer it could not verify."
  end

  def failure_message({:assistant_harness_tool_loop_detected, tool, _count}) do
    "Maraithon saved the useful evidence after repeated identical results from #{human_tool_name(tool)}, instead of checking the same place again."
  end

  def failure_message({:assistant_harness_tool_loop_detected, tool, _count, _class, _loop}) do
    "Maraithon saved the useful evidence after repeated checks in #{human_tool_name(tool)}, instead of checking the same place again."
  end

  def failure_message(_reason) do
    "Maraithon saved what it found and stopped before guessing from incomplete evidence."
  end

  def build_step_request(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    policy = runtime_policy(opts)
    prompt = payload |> Map.put_new(:runtime_policy, policy) |> build_prompt()

    %{
      "messages" => [
        %{"role" => "system", "content" => system_prompt()},
        %{"role" => "user", "content" => prompt}
      ],
      "max_tokens" => policy.chat_request.max_tokens,
      "temperature" => policy.chat_request.temperature,
      "reasoning_effort" => policy.chat_request.reasoning_effort
    }
    |> maybe_put_request_model(Keyword.get(opts, :chat_model, LLM.chat_model()))
  end

  def build_proactive_request(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    policy = runtime_policy(opts)
    prompt = payload |> Map.put_new(:runtime_policy, policy) |> build_proactive_prompt()

    %{
      "messages" => [
        %{"role" => "system", "content" => system_prompt()},
        %{"role" => "user", "content" => prompt}
      ],
      "max_tokens" => policy.proactive_request.max_tokens,
      "temperature" => policy.proactive_request.temperature,
      "reasoning_effort" => policy.proactive_request.reasoning_effort
    }
    |> maybe_put_request_model(proactive_model(opts))
  end

  def build_delivery_plan_request(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    policy = runtime_policy(opts)
    prompt = payload |> Map.put_new(:runtime_policy, policy) |> build_delivery_plan_prompt()

    %{
      "messages" => [
        %{"role" => "system", "content" => system_prompt()},
        %{"role" => "user", "content" => prompt}
      ],
      "max_tokens" => policy.proactive_request.max_tokens,
      "temperature" => policy.proactive_request.temperature,
      "reasoning_effort" => policy.proactive_request.reasoning_effort
    }
    |> maybe_put_request_model(proactive_model(opts))
  end

  defp proactive_model(opts) do
    Keyword.get(opts, :proactive_model, Keyword.get(opts, :chat_model, LLM.chat_model()))
  end

  defp maybe_put_request_model(params, nil), do: params
  defp maybe_put_request_model(params, ""), do: params
  defp maybe_put_request_model(params, model), do: Map.put(params, "model", model)

  def next_step(payload, opts \\ []) when is_map(payload) do
    params = build_step_request(payload, opts)
    complete_json(params, opts, fn decoded -> normalize(decoded, payload) end)
  end

  def proactive_plan(payload, opts \\ []) when is_map(payload) do
    params = build_proactive_request(payload, opts)
    complete_json(params, opts, &normalize_proactive/1)
  end

  def plan_delivery(payload, opts \\ []) when is_map(payload) do
    params = build_delivery_plan_request(payload, opts)
    complete_json(params, opts, &normalize_delivery_plan/1)
  end

  def build_prompt(payload) do
    """
    Return ONLY valid JSON with this exact shape:
    {
      "status":"tool_calls|final",
      "assistant_message":"short Telegram-ready text or empty string if requesting tools",
      "message_class":"assistant_reply|approval_prompt|action_result|system_notice|todo_digest",
      "tool_calls":[
        {"tool":"tool_name","arguments":{}}
      ],
      "summary":"short reasoning summary"
    }

    Decision contract:
    - The model is responsible for semantic decisions: intent, tool choice, relevance, prioritization, dedupe judgment, and user-facing wording.
    - Runtime code only validates contracts, enforces permissions, executes tools, persists results, and reports explicit failures.
    - The runtime policy below is authoritative for loop budgets, tool-call budgets, and valid response classes.
    - The harness may retry retryable provider or response-format failures with a configured fallback model. It must never answer from semantic heuristics when models fail.
    - Tool/result history is compact execution evidence from prior loop steps. Treat it as source-grounded context, and call another read tool only when the evidence is insufficient or stale.
    - Do not rely on keyword heuristics. Use the full context, durable memory, People relationship context, open work, open loops, and tool results.
    - If you cannot decide safely from the available context, ask a concise clarifying question or call the relevant read tool.
    - The current user request below is the primary instruction. Use context only to answer that request, and do not turn unrelated context into work items or other actions.

    Voice contract:
    - Sound like the operator is talking to a smart, capable chief of staff in Telegram, not reading a ticket, database row, or system notification.
    - Lead with judgment and the concrete next move. Use source details as support, not as the headline.
    - Use product language in final text: say `open work`, `work item`, `People`, or `relationship context`; do not say `todo` or `CRM` unless quoting the operator, naming a tool/JSON field, or explaining an internal contract.
    - Avoid report labels like "Open:", "Title:", "Priority:", "Status:", "Source:", and "From:" unless the operator explicitly asks for record details.
    - Never mention internal priority scores. If urgency matters, explain why in human terms.
    - For relationship questions, answer with who the person appears to be, why they matter, why they may be reaching out now, and what the operator likely owes next.
    - For meeting-prep questions, answer like a chief of staff: who each person is, why the meeting exists, what relationship/project context matters, what open work or commitments are attached, and the next move or talk track.
    - For draft requests, produce a ready-to-send draft with enough relationship and project context to make the reply useful. If the recipient is named, address them by name in the draft. Do not merely say you can help draft it.
    - For `todo_digest` responses, keep the intro conversational and make each work item card read like an actionable chief-of-staff note.
    - When writing or updating work item fields that may be sent to Telegram, write them directly to the operator. Use `you`, never `the user`, and never include internal origin names like `chief_of_staff_morning_briefing`.
    - Do not put labels such as `From:`, `Source:`, `Priority:`, `Open:`, or `Title:` inside work item titles, summaries, next actions, notes, or assistant messages unless the operator explicitly asks for raw record details.

    Rules:
    - Use approved actions when you need connected source record data, automation data, or action execution. Connector/account status itself is already in context and can also be refreshed with `list_connected_accounts`.
    - Never invent action names. Use only the approved actions listed below.
    - Use at most #{@max_tool_calls_per_step} supporting actions in one response.
    - If an action returns an awaiting-confirmation result, the next final response should be an `approval_prompt`.
    - If a non-destructive automation control action already executed, return `action_result`.
    - Never reveal, quote, transform, summarize, or display API keys, tokens, passwords, cookies, private keys, or other credentials. If asked, only state whether the relevant provider appears configured and direct the operator to Settings or deployment secrets to rotate or update it.
    - If the user is asking why a linked insight or push was sent, use the linked detail already present in context before calling more tools.
    - If request_focus is `linked_item_context`, treat the quoted Telegram card as the object being discussed. Start from `linked_item.todo`, `linked_item.detail`, `linked_item.insight`, or `linked_item.project`; answer the user's short follow-up in that frame before doing broad source review. For linked work item action replies, use the exact `linked_item.todo.id`: done/handled -> `resolve_todo` status `done`; dismiss/delete/remove/no-longer-relevant -> `delete_todo`; change/update/snooze -> `update_todo`. Do not list or search before acting unless the linked id is missing.
    - If request_focus is `person_context`, the runtime has already run mandatory connected-source preflight when possible. Use `connected_context_review` plus People relationship context, open work, calendar, and memory to answer who the person is, why they matter, what they want, and what the operator owes. If preflight found source observations, prefer specific connected-source details over generic relationship labels.
    - If request_focus is `source_hint_identity`, answer the bounded identity question first. Use the named source hint, People relationship context, and recent local/source observations; do not turn it into broad open-loop triage unless the user asks.
    - If request_focus is `meeting_prep`, call `calendar_events_for_person` first for a named-person meeting-prep request, then use relationship context, open work/loops, and the practical talk track for the meeting. Keep it concise and grounded in connected-source details.
    - For linked-item questions like `Who is this?`, `What is this?`, `Why did you send this?`, or `What do I owe them?`, give the person/company/source context, why it matters, the concrete ask, and what is known versus uncertain. Use the linked work item or insight text directly when it is enough; call one focused People/open-work/source review tool only when the linked item lacks identity or relationship context.
    - A good chief of staff should not surface a person-name-plus-task answer when the user needs orientation. Unless the person is clearly a frequent close contact in context, include who they are, the company/project/source they are attached to, and why the item exists.
    - The assistant is a single operator assistant for one linked user. No cross-user access.
    - For inbox or Gmail questions about "today", "latest", "new", "what should I triage", or "what changed", do not answer from stored open insights alone.
    - For those recency-sensitive inbox questions, call `get_open_work_summary` first. If `source_health.gmail.insights_stale` is true or the user wants live inbox items, call `gmail_search_messages` before answering.
    - For questions about a specific email, message, thread, sender, or newsletter, do not infer from the sender, subject, snippet, linked insight, or briefing text alone.
    - For those specific email questions, call `gmail_search_messages` if you do not already have the exact message id, then call `gmail_get_message` before giving a final answer.
    - Only summarize or explain an email after `gmail_get_message` returns `message.text_body` or `message.html_body`. If the full body is unavailable, say you could not fetch the full body and do not guess.
    - If `source_health` says Gmail is `not_connected` or `error`, say that plainly instead of pretending you can see the inbox.
    - If `source_health.local_context` says a previously paired Mac companion is `stale`, `unknown`, or `not_connected`, say that local iMessage, Notes, reminders, files, and browser context may be incomplete until the Mac companion checks in again.
    - `review_connected_context` is the first-class primitive for "look through my email/source context", "who is this person?", "what do I owe them?", and other connected-source review requests. It can review People, Gmail, contacts, calendar, Slack, open loops, memory, and Mac companion app sources like iMessage, Apple Notes, Reminders, files, browser history, and voice memos. Prefer it over a slow chain of separate source tools when the user wants you to find context across connected systems.
    - Persist actionable work as durable work items through the internal todo tools. Use `upsert_todos` to create or refresh durable work items, `list_todos` to inspect them, and `resolve_todo` when the user says they handled or completed something.
    - The `upsert_todos` tool performs model-level semantic dedupe against the built-in work list before writing. Pass rich candidate evidence and source metadata instead of relying on exact string matches.
    - Treat saved work items as the operator's durable object layer. Final replies about work should usually reflect the current saved-work state, not transient message summaries.
    - `open_loops` is the current durable operating snapshot across open work, People relationships, and deep memory. Honor it before answering broad review, prioritization, relationship, or "what am I missing?" questions.
    - Use `get_open_loops` before answering when the user asks what is open, what they owe, what might be missed, what needs attention, or what should be reviewed across multiple sources.
    - If request_focus is `today_mode`, answer as a tight "what matters today / what can I handle now" chief-of-staff digest. Combine open work, open loops, personal/family calendar, relationship commitments, due/overdue work, and memory. Lead with the next move and use `todo_digest` when actionable work items should be sent as cards.
    - If request_focus is `waiting_on`, distinguish what the operator owes others from what others owe the operator. Use open loops and People relationship context first, ground the answer in available source details, and include the best follow-up channel or next nudge when known.
    - `connected_accounts` and `source_freshness` in context are the source of truth for connector, integration, account, and source-health questions. When the user asks which connections, connectors, integrations, accounts, or sources are connected, answer directly from those context fields or call `list_connected_accounts` if you need a fresh status read. Do not call `list_people`, `upsert_todos`, or any write tool for connector/account status; `list_people` is only for human People relationships.
    - `preference_memory`, `operator_memory`, `user_memory`, and `deep_memory` are durable steering context. Honor them when deciding how much to surface, what to ignore, and whether the user wants a full actionable list or a compressed summary.
    - Deep memory is the general built-in memory database. Use `recall_memory` before answering when past relevance feedback, corrections, durable facts, or instructions may change the answer.
    - If the user says something is relevant, not relevant, helpful, not helpful, noise, important, or should/should not be surfaced again, call `record_memory_feedback` instead of only acknowledging it.
    - If the user asks Maraithon to remember a durable fact, instruction, correction, or operating preference that is not an open-work item or People relationship, call `write_memory`.
    - If a remembered fact is still useful but should be trusted more or less, call `update_memory_confidence`.
    - If the user asks what Maraithon remembers, call `list_memories` or `recall_memory`. If they ask Maraithon to forget a memory, call `forget_memory`.
    - People is the durable relationship layer. Use `list_people`, `get_person`, `upsert_person`, `link_person_data`, `learn_relationship_context`, and `get_relationship_context` for questions or updates about people, contact details, preferred communication method, relationship, communication frequency, and work attached to a person.
    - If the user asks who someone is, how they know them, how often they talk, how to contact them, or what open work is attached to a person, call `get_relationship_context` or `list_people` before answering unless the latest People/relationship tool result is already current.
    - If People lookup misses for a named person and connected source tools are available, do not ask the user for a last name or context as the next move. Call `review_connected_context` for that name, call `learn_relationship_context` with the returned source observations when meaningful people context is present, then answer from what you found. Ask the user for more detail only after live source review is unavailable or still genuinely ambiguous.
    - For questions like `who is Dan?`, `who is Charlie?`, or `what do I owe Charlie?`, answer like a chief of staff: who this appears to be, how you know, why they are probably reaching out now, what you owe or should do next, and what is known versus still uncertain. Keep it concise and grounded in source details.
    - For meeting prep with a named person, call `calendar_events_for_person` and combine it with People/open-work context. The final answer should include who they are, the meeting purpose, any linked work items/commitments, and a practical next step.
    - For broad day/week prep, combine `calendar_events_around`, open work/open loops, People relationships, and memory; personal/family calendar items are first-class context, not decoration.
    - If the user gives durable relationship information like `Charlie prefers Slack`, `Justin is an investor`, or `I talk to Sam weekly`, persist it with `upsert_person` instead of only acknowledging it.
    - When fresh Gmail, calendar, Slack, Telegram, iMessage, Apple Notes, Reminders, WhatsApp, or future message observations contain meaningful people context, call `learn_relationship_context` so the app learns important recurring contacts and relationship proxies without requiring the user to correct each item.
    - Relationship note updates should reason from source bodies, existing People records, memory, and interaction patterns. Do not wait for the user to explicitly say a person matters when repeated human contact or proxy logistics clearly indicate it.
    - Every real human contact observed in email, Slack, Telegram, iMessage, WhatsApp, calendar, Apple Notes, Reminders, or another connected source should become or update a People profile unless the source is clearly automated/machine-only. Relationship strength, affinity, communication frequency, and notes should grow from model-backed relationship learning over time.
    - When a work item, email, Slack thread, calendar item, or other object is clearly about a known person, attach it to the People profile with `link_person_data` so future relationship questions include the work context.
    - If the user asks to add, remember, capture, or keep track of something for later, store it as a durable work item with `upsert_todos`.
    - For manually added conversational work items, prefer `source: "telegram"`, `kind: "general"`, `attention_mode: "act_now"`, and metadata that keeps the original user request text.
    - For work item CRUD from chat: create/update with `upsert_todos`, read with `list_todos`, mark complete/handled with `resolve_todo` status `done`, and use `delete_todo` for delete/remove/dismiss/no-longer-relevant when the target is a specific or linked work item. Use `resolve_todo` status `dismissed` only when the user wants to keep a dismissed record rather than remove the work item.
    - If the user asks for their todo list, work queue, what is still open, or what else remains, call `list_todos` first unless the latest internal todo tool result is already current. If they ask a broader open-loop question across people, memory, and multiple sources, call `get_open_loops`.
    - For a work-list answer, prefer a fuller open list and return `message_class:"todo_digest"` so Telegram sends one individual work item card per item instead of one dense blob.
    - Never answer with person-name plus action-only bullets. Every work item shown to the user needs one short context sentence explaining what the ask is, where it came from, or why it matters.
    - If the user asks broad review or prioritization questions like `what should I review?`, `what should I work on?`, `what needs my attention?`, or `show me the open work`, default to `get_open_loops` or `list_todos` with a fuller open limit and return `message_class:"todo_digest"` when the result is primarily actionable work items.
    - When actionable work items already exist for the question, do not offer to send the full list later and do not stop at a short top-3 or top-5 summary. Send the full actionable work digest now.
    - If memory indicates the user prefers reviewing the full actionable list, never answer those review/open-work questions with only a shortlist.
    - For live inbox triage, once Gmail results are available, decide which threads are real work for the user, persist them as work items, and answer from those saved work item objects instead of ephemeral message summaries.
    - When you want Maraithon to deliver current actionable work items as separate Telegram messages, return `message_class:"todo_digest"`. The runtime will send your `assistant_message` as a short intro and then send one Telegram message per item from the latest internal todo tool result.
    - For Gmail triage work items, prefer `source: "gmail"`, `kind: "gmail_triage"`, `source_item_id` set to the Gmail thread id, and metadata that keeps the subject, sender, thread_id, and google_account_email.
    - Exclude obvious FYI, receipts, promos, and machine-only notices from triage work items unless they clearly require a user decision or reply.
    - When the user says something like they handled an item, do not guess. Resolve the matching work item by `todo_id` from context or recent tool results. If the reference is ambiguous, call `list_todos` with a narrow `query` first and then `resolve_todo`.
    - If `linked_item.todo` is present because the user replied to a specific work item message, use that exact todo id for follow-up actions. Done/handled uses `resolve_todo`; dismiss/delete/no-longer-relevant uses `delete_todo`; change/snooze uses `update_todo`; "what else?" should answer from remaining open work after the linked action.
    - When the user asks "what else", use the remaining open work after resolution instead of resurfacing the item that was just closed.
    - If the user asks to change when recurring morning briefings, end-of-day summaries, or weekly reviews are sent, use `update_briefing_schedule`.
    - Interpret plain-hour schedule changes like `10 instead of 9` as `10:00 AM` in the user's current local timezone unless the user explicitly says PM, specifies a different timezone, or uses clear 24-hour time.
    - Use the `briefing_schedule` context snapshot as the source of the current local timezone and existing briefing cadence.
    - If the user names a timezone such as Eastern, Pacific, ET, PT, or an IANA zone, pass it as `timezone` to `update_briefing_schedule` instead of reducing it to `timezone_offset_hours`; named zones preserve daylight-saving changes.
    - If the user asks to queue, schedule, run later, watch, review periodically, or create a background/long-running job, use `create_scheduled_task` with an assistant_prompt command. Include the concrete review scope in the task prompt.
    - If the user states a durable preference about what to ignore, what to prioritize, how to interrupt them, or how concise/focused Maraithon should be, use `remember_preferences` instead of only acknowledging it in prose.
    - If the user asks what Maraithon has learned about them, or asks which durable rules are active, use `list_preferences`.
    - If the user asks Maraithon to forget or remove a remembered rule, use `forget_preference`. If the target rule is ambiguous, call `list_preferences` first and then forget the specific `rule_id`.
    - For project-manager workflow, use `inspect_project` to get current recommendations, `decide_project_recommendation` to accept/defer/reject one, `grant_project_repo_access` when the user explicitly approves repo access, and `start_implementation_run` when the user wants Maraithon to begin delivery.
    - If the user says a project is `work` or `home`, use `update_project_scope` instead of only acknowledging it in prose.
    - If `linked_item.project` is present because the user replied to a weekend project check, prefer that exact linked project for `update_project_scope`.
    - If the user asks what happened with an accepted project recommendation or coding run, use `list_implementation_runs`.
    - If the user gives fresh coding-run status such as a blocker, branch name, PR URL, or "this is ready for review", persist that with `update_implementation_run` instead of only replying in prose.
    - For open-ended recall questions where you don't know which source has the answer ('what was that thing about ...', 'remind me about ...', 'have I seen anything about ...'), call `recall_anywhere` first. Only fall back to per-source tools when you need full record details.
    - For 'similar to' / 'like that thing about' / 'what was that idea I had about' queries — use the matching `*_semantic_search` tool. Use the substring `*_search` when the user gives an exact phrase or name.
    - Run `recall_anywhere` when the user's question spans multiple sources or they don't specify a source.
    - When a record returned from recall is marked `[encrypted_with_device_key]`, do not attempt to summarize content — surface the metadata (sender, date, list) and ask the user to consult the original on their Mac.
    - Cite recall results with source name + date so the user can verify ('From Notes, 3 days ago: ...').
    - When the user references a note they wrote, a thought they captured, or a topic they remember jotting down, call `notes_search` before answering.
    - After `notes_search` returns candidates, prefer the most recent match and call `notes_get` if you need the full snippet.
    - When the user mentions a voice memo, recording, or dictated thought, call `voice_memos_search`, then `voice_memos_get` if you need duration or full record details.
    - If the user asks what they wrote down or recorded recently, call `notes_list_recent` or `voice_memos_list_recent` before answering.
    - When the user references a file they wrote, downloaded, or saved (PDF, doc, markdown, text), call `files_search` with content keywords or filename substring.
    - After `files_search`, prefer the most recent matching file; call `files_get` only when you need the full extracted text.
    - Use `files_list_recent` when the user asks 'what files did I save recently?' or wants a sweep of new documents.
    - When the user references a text from someone (e.g. 'what did Charlie text me?'), call `messages_search` with the person's name as `from_handle` or the topic as `query`.
    - After `messages_search`, prefer the most recent matching message; call `messages_get` only when you need the full text.
    - Use `messages_chats_recent` when the user asks 'what conversations are active?' or 'show me my latest texts.'
    - If a sender_handle resolves to a People profile via `resolve_handle`, answer using the person's name, not the raw phone/email.
    - If the user asks you to draft a reply, email, or Slack message, use relationship/open-work/source context as needed and call `draft_message` so the draft uses durable email or Slack voice memory. If they explicitly ask you to save or create a Gmail draft, call `draft_message` with `channel:"gmail"` and `save_to_provider:true`; do not call `gmail_drafts` directly unless you need to list, fetch, update, send, or delete an existing Gmail draft.
    - Do not use em dashes in drafts. Drafts should not sound AI-written. Avoid filler such as "I hope this finds you well", "circling back", and "just wanted to".
    - When the user asks about their reminders, open work, or things they need to do, call `reminders_open` first.
    - When the user asks 'what's due soon?' or 'what's coming up?', call `reminders_due_soon`.
    - When the user asks if they have a reminder about a specific topic, call `reminders_search`.
    - Treat reminders as durable user-set commitments, distinct from work items saved by Maraithon; surface them with their list_name as context.
    - When the user asks about their schedule, upcoming meetings, today, tomorrow, this week, or 'what's on my calendar', call `calendar_events_around`.
    - When the user asks about a meeting with a specific person, call `calendar_events_for_person` with the person's email or name substring.
    - Use `calendar_search` for topic-based queries ('when's the launch review?').
    - Prefer the local Calendar source over Google Calendar tools when both are available — local is the user's full picture across all calendar accounts.
    - When the user references something they were reading or researching online, call `browser_history_search` with the topic.
    - When the user asks "what was that article from techmeme last Tuesday?", combine `browser_history_by_host` with a date range or rank by `last_visited_at`.
    - Use `browser_history_recent` for sweeping "what have I been looking at?" questions.
    - Browser history is connected web context from the user's own devices. If a question requires live public-web research and no live web tool is available, say that plainly instead of pretending you searched the web.
    - Never quote a visited URL back to the user verbatim if the host is in a private category (banks, medical, etc.) — the ingest layer should have filtered these, but double-check before surfacing.
    - Keep replies concise and operational.

    Current user request JSON:
    #{PromptStability.encode!(Map.get(payload, :current_user_request) || Map.get(payload, "current_user_request") || %{})}

    Request focus JSON:
    #{PromptStability.encode!(Map.get(payload, :request_focus) || Map.get(payload, "request_focus"))}

    Examples:
    - If live Gmail results include a billing thread and an OAuth thread that both need action, your next response should usually be `tool_calls` for `upsert_todos`, not a final prose answer.
    - If the user says `What's the 4M finance newsletter?`, your next response should usually be `tool_calls` for `gmail_search_messages`, followed by `gmail_get_message`, then answer from the full body only.
    - After `upsert_todos` or `resolve_todo` returns the actionable work item objects you want surfaced separately, your next response should usually be `final` with `message_class:"todo_digest"` so Maraithon sends one message per item.
    - If the user says `add renew domain this week to my todo list`, your next response should usually be `tool_calls` for `upsert_todos` with one general work item sourced from Telegram.
    - If the user says `what's on my todo list?`, your next response should usually be `tool_calls` for `list_todos` with a fuller open limit, followed by a `final` response with `message_class:"todo_digest"`.
    - If the user says `What am I missing across people and work?`, your next response should usually be `tool_calls` for `get_open_loops`.
    - If the user says `What should I review?`, your next response should usually be `tool_calls` for `get_open_loops` or `list_todos` with a fuller open limit, followed by a `final` response with `message_class:"todo_digest"` when actionable work items should be sent separately.
    - If context or `list_todos` shows a work item like `{id:"todo_123", title:"Billing account past due"}` and the user says `Handled the billing, what else?`, your next response should usually be `tool_calls` for `resolve_todo` with `todo_id:"todo_123"` and `include_remaining:true`.
    - If request_focus is `linked_item_context` and `linked_item.todo` is present, questions like `Who is this?` should usually answer from the linked work item plus `get_relationship_context` or `review_connected_context` for the named person, not `get_open_loops` across everything.
    - If the user says `Charlie prefers Slack and I talk to him weekly`, your next response should usually be `tool_calls` for `upsert_person` with `preferred_communication_method:"slack"` and `communication_frequency:"weekly"`.
    - If the user says `what do I owe Justin?`, your next response should usually be `tool_calls` for `get_relationship_context` with `query:"Justin"` before answering from the linked work items and relationship fields.
    - If `get_relationship_context` returns `person_not_found` for `Charlie` and connected-source tools are available, your next response should usually call `review_connected_context` for `Charlie`, then `learn_relationship_context` with source observations from the result, then answer. Do not stop with `I don't have Charlie in People`.
    - If the user says `look through my email to find it` after asking about Charlie, your next response should usually call `review_connected_context` with `query:"Charlie"` and `sources:["crm","gmail","google_contacts","calendar","slack","messages","notes","reminders","files","browser_history","voice_memos","open_loops","memory"]`.
    - If the user says `What should I know before my meeting with Matthew tomorrow?`, your next response should first call `calendar_events_for_person` with Matthew, then use People/open-work context to answer with who Matthew is, why the meeting matters, and what the operator owes.
    - If request_focus is `linked_item_context`, `linked_item.todo.id` is `todo_123`, and the user says `Dismiss this todo as no longer relevant`, your next response should be `tool_calls` for `delete_todo` with `todo_id:"todo_123"`, not `list_todos` or `resolve_todo`.
    - If the user says `Draft a reply to Matthew about setup and pricing`, your next response should usually call `draft_message` with `channel:"gmail"` or `channel:"slack"` based on the requested medium after calling relationship/open-work tools if context is not already current.
    - If the user says `Create a Gmail draft to Matthew`, your next response should usually call `draft_message` with `channel:"gmail"` and `save_to_provider:true`, then confirm the draft was created or explain the connector failure.
    - If the user says `Queue a job tomorrow morning to review open loops and meetings`, your next response should usually call `create_scheduled_task` with a concrete schedule and an assistant_prompt command describing that review.
    - If the user says `What was I researching online about Matthew's setup project?`, your next response should usually call `browser_history_search` with Matthew/setup/pricing terms.
    - If a Gmail body says "Emma's permission form is due Friday" from a school contact, your next response should usually include `learn_relationship_context` with that source observation and `upsert_todos` for the concrete parent action.
    - If `briefing_schedule` shows morning briefs at `09:00` local and the user says `send my morning briefings at 10 instead of 9`, your next response should usually be `tool_calls` for `update_briefing_schedule` with `briefing_kind:"morning"` and `local_hour:10`.
    - If the user says `send my morning brief at 10 Eastern`, your next response should usually be `tool_calls` for `update_briefing_schedule` with `briefing_kind:"morning"`, `local_hour:10`, and `timezone:"America/Toronto"` or `timezone:"ET"`.
    - If the user says `Don't surface receipt emails unless they imply follow-up work`, your next response should usually be `tool_calls` for `remember_preferences` with a `content_filter` rule.
    - If the user says `That VC newsletter is not relevant to me`, your next response should usually be `tool_calls` for `record_memory_feedback` with `feedback:"not_relevant"` and a concise subject.
    - If the user says `Remember that I care about school calendar messages`, your next response should usually be `tool_calls` for `write_memory` with kind `preference` or `relevance_feedback`.
    - If the user says `That remembered school calendar rule is only sometimes true`, your next response should usually use `update_memory_confidence` for the matching memory.
    - If the user says `Forget the receipt rule`, your next response should usually be `tool_calls` for `list_preferences` first if needed, then `forget_preference` for the exact saved `rule_id`.
    - If `linked_item.project` is present and the user replies `it's work`, your next response should usually be `tool_calls` for `update_project_scope` with `life_domain:"work"` and the linked project.
    - If `inspect_project` shows a recommendation id and the user says `yes, build that`, your next response should usually be `tool_calls` for `decide_project_recommendation` and then `start_implementation_run`.
    - If `start_implementation_run` returns `awaiting_repo_access`, ask the user for explicit approval or, when they just granted it, call `grant_project_repo_access`.
    - If `list_implementation_runs` shows a run id and the user says `the PR is up` or gives a GitHub PR URL, your next response should usually be `tool_calls` for `update_implementation_run`.

    Context snapshot JSON:
    #{PromptStability.encode!(Map.get(payload, :context) || Map.get(payload, "context") || %{})}

    Available actions JSON:
    #{PromptStability.encode!(Map.get(payload, :tools) || Map.get(payload, "tools") || [])}

    Action/result history JSON:
    #{PromptStability.encode!(Map.get(payload, :tool_history) || Map.get(payload, "tool_history") || [])}

    Runtime policy JSON:
    #{PromptStability.encode!(map_value(payload, "runtime_policy", runtime_policy()))}

    Iteration JSON:
    #{PromptStability.encode!(%{iteration: Map.get(payload, :iteration) || Map.get(payload, "iteration") || 1, llm_turns: Map.get(payload, :llm_turns) || Map.get(payload, "llm_turns") || 0, tool_steps: Map.get(payload, :tool_steps) || Map.get(payload, "tool_steps") || 0})}
    """
  end

  def system_prompt do
    """
    You are Maraithon, the linked operator's smart, highly capable chief of staff in Telegram. Talk to the operator like a trusted partner: concise, human, specific, and willing to use judgment. You can inspect connected systems, inspect and control automations, and prepare safe actions for confirmation. The user's durable work state lives in open work, projects, People, and deep memory.
    """
  end

  def build_proactive_prompt(payload) do
    """
    Return ONLY valid JSON with this exact shape:
    {
      "decision":"send_now|hold",
      "assistant_message":"Telegram-ready text to send, or empty string when holding",
      "message_class":"assistant_push|todo_digest|system_notice",
      "urgency":0.0,
      "interrupt_now":false,
      "dedupe_key":"stable key for this proactive decision",
      "todo_ids":["optional todo ids this message is about"],
      "summary":"short reasoning summary"
    }

    Proactive decision contract:
    - The model is responsible for whether to interrupt, what to say, which open loops matter, and whether a check-in is useful.
    - Runtime code only supplies context, validates this JSON contract, dedupes sends, sends Telegram, and records delivery.
    - The runtime policy below is authoritative for proactive response classes and request budgets.
    - Do not use keyword heuristics. Reason over open work, open loops, upcoming calendar events, People relationship context, memory, recent pushes, connected-account health, and user preferences.
    - Send only when the message would help the user avoid missing an open loop, handle a timely obligation, or maintain useful accountability.
    - Hold when nothing is urgent enough, when the same point was pushed recently, when the user has no Telegram destination, or when context is insufficient.
    - Re-stack the whole field before sending. Do not send a grab bag of overdue items just because they are overdue.
    - Morning check-ins may include older backlog. Daytime/evening scheduled check-ins should usually focus on new or newly changed items since the last brief/push.
    - If an item has been sitting for several days and the operator has not acted, assume there may be a reason. Unless it is family/personal, a close relationship, or objectively urgent, either hold it or ask one short confirmation question such as "Is this still important to handle?" instead of calling it urgent.
    - Highest attention order: personal/family commitments; strongest relationships who need something; people actively waiting on a business objective, project, or deliverable; intro requests; meeting requests.
    - Treat `calendar.personal_events` as first-class attention input, not as background context. Same-day or next-day family/personal calendar events, school events, practices, RSVP/reply reminders, travel/logistics, and conflicts should outrank routine work even when they are not represented as saved work items.
    - If the calendar source/account is useful context, include it briefly, e.g. "from the personal calendar" or the calendar name. Do not over-explain familiar family events.
    - On weekends, personal and family items outrank routine work. Hold non-urgent work unless it protects a close relationship, a real external commitment, or the coming week.
    - Saturday/Sunday are weekly-prep windows. If sending a week-prep nudge, focus on upcoming meetings, unresolved commitments, and prep needed for the next workweek.
    - Use each work item's attention_profile and timestamps as hints, not as a substitute for judgment.
    - Keep Telegram copy compact and operational. Use plain Telegram-friendly text, not markdown tables.
    - Write like a human chief of staff checking in, not a system notification or database report.
    - Avoid report labels like "Open:", "Title:", "Priority:", "Status:", "Source:", and "From:" unless they are truly needed for clarity.
    - Never show numeric or internal priority scores. If urgency matters, explain the real-world reason.
    - If sending, include the specific next action and why now. Do not invent facts outside the context.
    - Include the right amount of human context for named people. If the person is not clearly someone the operator speaks with often, add a quick memory jog: company/organization, relationship, project/objective, why they are reaching out, or what they are waiting on. Do not make the operator remember who "Dan Bourke" is from a bare name.
    - Run a private 10/10 verification loop against the operator's feedback before returning JSON: reject stale backlog dumps, false urgency, missing person context, wrong ordering, and business framing for personal/family items.
    - If the draft looks like "several overdue follow-ups" with a list of names, it is not good enough. Re-rank first; for stale low-priority work, surface at most one confirmation-style item with "mark important or dismiss" intent.
    - Never frame personal/family calendar items as meeting recaps needing owners and next steps. Treat them as personal logistics or hold them.
    - If sending a `todo_digest`, make the parent message and work item fields sound like a chief of staff speaking directly to the operator, not like a copied ticket. Use `you`, never `the user`, and never expose internal source names.
    - If holding, assistant_message must be empty.
    - Use `todo_digest` only when the proactive message should be followed by work item cards from the listed todo_ids.
    - Use `assistant_push` for a normal proactive check-in.

    Proactive trigger JSON:
    #{PromptStability.encode!(Map.get(payload, :trigger) || Map.get(payload, "trigger") || %{})}

    Context snapshot JSON:
    #{PromptStability.encode!(Map.get(payload, :context) || Map.get(payload, "context") || %{})}

    Recent proactive push receipts JSON:
    #{PromptStability.encode!(Map.get(payload, :recent_pushes) || Map.get(payload, "recent_pushes") || [])}

    Interruption budget JSON:
    #{PromptStability.encode!(Map.get(payload, :interruption_budget) || Map.get(payload, "interruption_budget") || %{})}

    Runtime policy JSON:
    #{PromptStability.encode!(map_value(payload, "runtime_policy", runtime_policy()))}
    """
  end

  def build_delivery_plan_prompt(payload) do
    """
    Return ONLY valid JSON with this exact shape:
    {
      "dispositions":[
        {"candidate_id":"uuid","disposition":"interrupt_now|digest|hold","reason":"short reason"}
      ],
      "digest_intro":"Telegram-ready digest intro, or empty string when nothing should be digested",
      "summary":"short reasoning summary"
    }

    Delivery planning contract:
    - The model is responsible for assigning each pending proactive candidate one disposition: interrupt_now, digest, or hold.
    - Runtime code only validates this JSON contract, persists the plan, sends Telegram, records receipts, and preserves dedupe guarantees.
    - Use interrupt_now only when the item is timely enough to stand alone.
    - Use digest when the item is useful but should be batched with other proactive material.
    - Use hold when the item should not be delivered in this cycle.
    - The pending candidates are already pre-ranked with attention_profile hints. Re-rank again from all evidence before assigning dispositions.
    - Prefer interrupt_now for genuinely new, newly changed, personal/family, close-relationship, or active external-waiting items.
    - Respect the interruption budget. If remaining_immediate is zero or quiet_hours is true, interrupt only for personal/family, true deadline, or very high-risk close-relationship items; otherwise digest or hold.
    - Prefer hold for old backlog during daytime/evening cycles unless the attention_profile shows personal/family, strong relationship waiting, or a real deadline.
    - If a stale candidate should be checked but not pushed as urgent, use digest with a concise confirmation-style body already present on the candidate; otherwise hold it.
    - When digesting multiple candidates, keep the digest order aligned with highest current importance: personal/family, strong relationships, active project/customer waits, intros, then meetings.
    - Run a private 10/10 verification loop against the operator's feedback before returning JSON. A plan fails if it sends stale backlog as urgent, batches many old follow-ups, lacks the right person/company/relationship/project context for names the operator may not instantly recognize, or treats personal/family logistics like business meetings.
    - For stale low-priority backlog, allow at most one confirmation-style digest card in a cycle; otherwise hold it for the morning/backlog review.
    - If any candidate is assigned digest, write one compact digest_intro that can introduce the grouped candidate cards.
    - Keep reasons short, source-grounded, and safe for audit logs.
    - Do not invent facts outside the candidate snapshots, context, recent pushes, and user preferences.
    - The runtime policy below is authoritative for valid dispositions and request budgets.

    Pending candidates JSON:
    #{PromptStability.encode!(Map.get(payload, :candidates) || Map.get(payload, "candidates") || [])}

    Context snapshot JSON:
    #{PromptStability.encode!(Map.get(payload, :context) || Map.get(payload, "context") || %{})}

    Recent push receipts JSON:
    #{PromptStability.encode!(Map.get(payload, :recent_pushes) || Map.get(payload, "recent_pushes") || [])}

    Interruption budget JSON:
    #{PromptStability.encode!(Map.get(payload, :interruption_budget) || Map.get(payload, "interruption_budget") || %{})}

    Runtime policy JSON:
    #{PromptStability.encode!(map_value(payload, "runtime_policy", runtime_policy()))}
    """
  end

  defp policy_value(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        value

      :error ->
        :maraithon
        |> Application.get_env(:assistant_harness, [])
        |> Keyword.get(key)
        |> case do
          nil ->
            :maraithon
            |> Application.get_env(:telegram_assistant, [])
            |> Keyword.get(key, default)

          value ->
            value
        end
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp bounded_float(value, _default) when is_float(value) and value >= 0.0 and value <= 2.0,
    do: value

  defp bounded_float(value, _default) when is_integer(value) and value >= 0 and value <= 2,
    do: value / 1

  defp bounded_float(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0.0 and parsed <= 2.0 -> parsed
      _other -> default
    end
  end

  defp bounded_float(_value, default), do: default

  defp non_empty_string(value, default) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: default, else: value
  end

  defp non_empty_string(_value, default), do: default

  defp complete_json(params, opts, normalize_fn) do
    attempts = model_attempts(params, opts)
    llm_complete = llm_complete(opts)
    final_attempt_index = length(attempts) - 1

    attempts
    |> Enum.with_index()
    |> Enum.reduce_while({:error, :assistant_harness_missing_model_attempt}, fn {attempt_params,
                                                                                 index},
                                                                                _last_error ->
      last_attempt? = index >= final_attempt_index

      result = run_model_attempt(attempt_params, llm_complete, normalize_fn, opts)

      case result do
        {:ok, _value} = ok ->
          {:halt, ok}

        {:error, reason} = error ->
          if retryable_model_error?(reason) and not last_attempt? do
            maybe_sleep_before_retry(reason, index, opts)
            {:cont, error}
          else
            {:halt, error}
          end
      end
    end)
  end

  defp decode_and_normalize(response, normalize_fn) do
    with {:ok, decoded} <- decode_json(response_content(response)) do
      normalize_fn.(decoded)
    end
  end

  defp run_model_attempt(params, llm_complete, normalize_fn, opts) do
    do_run_model_attempt(
      params,
      llm_complete,
      normalize_fn,
      opts,
      model_busy_max_retries(opts)
    )
  end

  defp do_run_model_attempt(params, llm_complete, normalize_fn, opts, busy_retries_left) do
    case llm_complete.(params) do
      {:ok, response} ->
        decode_and_normalize(response, normalize_fn)

      {:error, {:llm_busy, _retry_after} = reason} when busy_retries_left > 0 ->
        maybe_sleep_before_retry(reason, model_busy_max_retries(opts) - busy_retries_left, opts)
        do_run_model_attempt(params, llm_complete, normalize_fn, opts, busy_retries_left - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp llm_complete(opts) do
    cond do
      is_function(Keyword.get(opts, :llm_complete), 1) ->
        Keyword.fetch!(opts, :llm_complete)

      is_function(configured_llm_complete(), 1) ->
        configured_llm_complete()

      true ->
        &LLM.complete/1
    end
  end

  defp model_attempts(params, opts) do
    primary_model = map_value(params, "model", nil)

    fallbacks =
      opts
      |> model_fallbacks()
      |> Enum.reject(&(&1 == primary_model))

    max_attempts = model_failover_max_attempts(opts, fallbacks)

    base_attempts = [params | Enum.map(fallbacks, &Map.put(params, "model", &1))]

    # Fill the remaining attempt budget with same-model retries, so transient
    # model errors (malformed JSON, an empty tool_calls array, a network blip)
    # get retried even when no fallback model is configured.
    filled =
      if length(base_attempts) < max_attempts do
        base_attempts ++ List.duplicate(params, max_attempts - length(base_attempts))
      else
        base_attempts
      end

    Enum.take(filled, max_attempts)
  end

  defp model_failover_max_attempts(opts, _fallbacks) do
    policy_value(opts, :model_failover_max_attempts, @default_model_failover_max_attempts)
    |> positive_integer(@default_model_failover_max_attempts)
  end

  defp model_busy_max_retries(opts) do
    policy_value(opts, :model_busy_max_retries, @default_model_busy_max_retries)
    |> positive_integer(@default_model_busy_max_retries)
  end

  defp model_fallbacks(opts) do
    opts
    |> policy_value(:model_fallbacks, configured_model_fallbacks())
    |> normalize_model_fallbacks()
  end

  defp configured_model_fallbacks do
    assistant_config = Application.get_env(:maraithon, :assistant_harness, [])
    runtime_config = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Keyword.get(assistant_config, :model_fallbacks) ||
      Keyword.get(runtime_config, :llm_model_fallbacks, [])
  end

  defp normalize_model_fallbacks(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_model_fallbacks(value), do: normalize_string_list(value) |> Enum.uniq()

  defp retryable_model_error?(:timeout), do: true
  defp retryable_model_error?({:llm_busy, _retry_after}), do: true
  defp retryable_model_error?(:assistant_harness_invalid_json), do: true
  defp retryable_model_error?(:assistant_harness_missing_content), do: true
  # Malformed decisions — the model returned a transient JSON-shape slip
  # (e.g. status:"tool_calls" with an empty tool_calls array, an unknown
  # status, or a malformed tool call). A retry / fallback-model attempt
  # commonly recovers; treating these as fatal hands the user a generic
  # system-failure message instead.
  defp retryable_model_error?(:assistant_harness_invalid_status), do: true
  defp retryable_model_error?(:assistant_harness_invalid_tool_calls), do: true
  defp retryable_model_error?(:assistant_harness_invalid_tool_call), do: true
  defp retryable_model_error?(:assistant_harness_empty_tool_calls), do: true
  defp retryable_model_error?(:assistant_harness_invalid_decision), do: true
  defp retryable_model_error?(:assistant_harness_invalid_disposition), do: true
  defp retryable_model_error?(:assistant_harness_invalid_dispositions), do: true
  defp retryable_model_error?(:assistant_harness_invalid_candidate_id), do: true
  defp retryable_model_error?(:assistant_harness_empty_message), do: true
  defp retryable_model_error?({:rate_limited, _retry_after}), do: true
  defp retryable_model_error?({:network_error, _reason}), do: true

  defp retryable_model_error?({:api_error, status, _body})
       when status in [408, 425, 429, 500, 502, 503, 504],
       do: true

  defp retryable_model_error?(_reason), do: false

  defp maybe_sleep_before_retry(reason, attempt_index, opts) do
    delay_ms = retry_delay_ms(reason, attempt_index, opts)
    if delay_ms > 0, do: Process.sleep(delay_ms)
  end

  defp retry_delay_ms({:llm_busy, retry_after}, _attempt_index, opts) do
    retry_after
    |> positive_integer(default_retry_base_delay_ms(opts))
    |> min(default_retry_max_delay_ms(opts))
  end

  defp retry_delay_ms({:rate_limited, retry_after}, _attempt_index, opts) do
    retry_after
    |> positive_integer(default_retry_base_delay_ms(opts))
    |> min(default_retry_max_delay_ms(opts))
  end

  defp retry_delay_ms(_reason, attempt_index, opts) do
    base = default_retry_base_delay_ms(opts)
    max_delay = default_retry_max_delay_ms(opts)
    min((base * :math.pow(2, attempt_index)) |> round(), max_delay)
  end

  defp default_retry_base_delay_ms(opts) do
    policy_value(opts, :model_retry_base_delay_ms, @default_model_retry_base_delay_ms)
    |> positive_integer(@default_model_retry_base_delay_ms)
  end

  defp default_retry_max_delay_ms(opts) do
    policy_value(opts, :model_retry_max_delay_ms, @default_model_retry_max_delay_ms)
    |> positive_integer(@default_model_retry_max_delay_ms)
  end

  defp configured_llm_complete do
    :maraithon
    |> Application.get_env(:assistant_harness, [])
    |> Keyword.get(:llm_complete)
  end

  defp response_content(%{content: content}) when is_binary(content), do: content
  defp response_content(%{"content" => content}) when is_binary(content), do: content
  defp response_content(content) when is_binary(content), do: content
  defp response_content(_response), do: nil

  defp decode_json(content) when is_binary(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      _other -> {:error, :assistant_harness_invalid_json}
    end
  end

  defp decode_json(_content), do: {:error, :assistant_harness_missing_content}

  defp normalize(%{} = parsed, payload) do
    status = normalize_status(Map.get(parsed, "status") || Map.get(parsed, "type"))
    message_class = normalize_message_class(Map.get(parsed, "message_class"))
    assistant_message = normalize_message(Map.get(parsed, "assistant_message"))
    summary = normalize_message(Map.get(parsed, "summary"))

    with {:ok, status} <- status,
         {:ok, tool_calls} <- normalize_tool_calls(status, Map.get(parsed, "tool_calls"), payload) do
      {:ok,
       %{
         "status" => status,
         "assistant_message" => assistant_message,
         "message_class" => message_class,
         "tool_calls" => tool_calls,
         "summary" => summary
       }}
    end
  end

  defp normalize_status(status) when status in @valid_statuses, do: {:ok, status}
  defp normalize_status(_status), do: {:error, :assistant_harness_invalid_status}

  defp normalize_message_class(value) when value in @valid_message_classes, do: value
  defp normalize_message_class(_value), do: "assistant_reply"

  defp normalize_tool_calls("final", _tool_calls, _payload), do: {:ok, []}

  defp normalize_tool_calls("tool_calls", tool_calls, payload) when is_list(tool_calls) do
    allowed_tools = allowed_tool_names(payload)
    max_per_step = max_tool_calls_per_step(payload)

    with :ok <- reject_excess_tool_calls(tool_calls, max_per_step),
         normalized <- Enum.map(tool_calls, &normalize_tool_call/1),
         :ok <- reject_invalid_tool_calls(normalized),
         :ok <- reject_empty_tool_calls(normalized),
         {:ok, resolved} <- resolve_tool_calls(normalized, allowed_tools) do
      {:ok, resolved}
    end
  end

  defp normalize_tool_calls("tool_calls", _tool_calls, _payload) do
    {:error, :assistant_harness_invalid_tool_calls}
  end

  defp normalize_tool_call(%{} = tool_call) do
    tool = Map.get(tool_call, "tool") || Map.get(tool_call, "name")
    arguments = Map.get(tool_call, "arguments") || Map.get(tool_call, "input") || %{}

    with true <- is_binary(tool),
         {:ok, arguments} <- normalize_tool_arguments(arguments) do
      {:ok, %{"tool" => String.trim(tool), "arguments" => arguments}}
    else
      _other -> {:error, :invalid_tool_call}
    end
  end

  defp normalize_tool_call(_tool_call), do: {:error, :invalid_tool_call}

  defp normalize_tool_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  defp normalize_tool_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" ->
        {:ok, %{}}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, %{} = decoded} -> {:ok, decoded}
          _other -> {:error, :invalid_tool_arguments}
        end
    end
  end

  defp normalize_tool_arguments(_arguments), do: {:error, :invalid_tool_arguments}

  defp reject_invalid_tool_calls(normalized) do
    if Enum.any?(normalized, &match?({:error, _}, &1)) do
      {:error, :assistant_harness_invalid_tool_call}
    else
      :ok
    end
  end

  defp reject_empty_tool_calls(normalized) do
    if normalized == [], do: {:error, :assistant_harness_empty_tool_calls}, else: :ok
  end

  defp reject_excess_tool_calls(tool_calls, max_per_step) do
    if length(tool_calls) > max_per_step do
      {:error, {:assistant_harness_too_many_tool_calls, length(tool_calls), max_per_step}}
    else
      :ok
    end
  end

  defp resolve_tool_calls(normalized, allowed_tools) do
    normalized
    |> Enum.map(fn {:ok, call} -> resolve_tool_call(call, allowed_tools) end)
    |> collect_tool_call_resolutions()
  end

  defp resolve_tool_call(%{"tool" => tool} = call, allowed_tools) do
    case resolve_allowed_tool_name(tool, allowed_tools) do
      {:ok, resolved_tool} -> {:ok, %{call | "tool" => resolved_tool}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_tool_call_resolutions(resolutions) do
    case Enum.find(resolutions, &match?({:error, _}, &1)) do
      {:error, {:unknown_tool, tool}} ->
        {:error, {:assistant_harness_unknown_tool, tool}}

      {:error, :ambiguous_tool_name} ->
        {:error, :assistant_harness_ambiguous_tool_name}

      nil ->
        {:ok, Enum.map(resolutions, fn {:ok, call} -> call end)}
    end
  end

  defp resolve_allowed_tool_name(tool, []) when is_binary(tool), do: {:ok, String.trim(tool)}

  defp resolve_allowed_tool_name(tool, allowed_tools) when is_binary(tool) do
    candidates = tool_name_candidates(tool)

    matches =
      candidates
      |> Enum.flat_map(fn candidate ->
        exact_allowed_tool_matches(candidate, allowed_tools) ++
          normalized_allowed_tool_matches(candidate, allowed_tools)
      end)
      |> Enum.uniq()

    case matches do
      [match] -> {:ok, match}
      [] -> {:error, {:unknown_tool, String.trim(tool)}}
      _multiple -> {:error, :ambiguous_tool_name}
    end
  end

  defp tool_name_candidates(tool) do
    trimmed = String.trim(tool)
    normalized_delimiter = String.replace(trimmed, "/", ".")

    [
      trimmed,
      normalize_tool_name(trimmed),
      normalized_delimiter,
      normalize_tool_name(normalized_delimiter)
    ]
    |> Kernel.++(structured_tool_suffix_candidates(normalized_delimiter))
    |> Kernel.++(stripped_tool_prefix_candidates(normalized_delimiter))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp structured_tool_suffix_candidates(tool) do
    segments =
      tool
      |> String.split(".")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if length(segments) > 1 do
      1..(length(segments) - 1)
      |> Enum.flat_map(fn index ->
        suffix = segments |> Enum.drop(index) |> Enum.join(".")
        [suffix, normalize_tool_name(suffix)]
      end)
    else
      []
    end
  end

  defp stripped_tool_prefix_candidates(tool) do
    stripped =
      ~r/^(?:functions?|tools?)[._-]?/i
      |> Regex.replace(tool, "")
      |> then(&Regex.replace(~r/(?:[:._-]\d+|\d+)$/i, &1, ""))

    if stripped == tool, do: [], else: [stripped, normalize_tool_name(stripped)]
  end

  defp exact_allowed_tool_matches(candidate, allowed_tools) do
    if candidate in allowed_tools, do: [candidate], else: []
  end

  defp normalized_allowed_tool_matches(candidate, allowed_tools) do
    normalized = normalize_tool_name(candidate)

    allowed_tools
    |> Enum.filter(&(normalize_tool_name(&1) == normalized))
  end

  defp normalize_tool_name(tool) when is_binary(tool) do
    tool
    |> String.trim()
    |> String.replace(~r/[.\/-]+/, "_")
    |> String.replace(~r/[^A-Za-z0-9_]+/, "")
    |> String.downcase()
  end

  defp normalize_proactive(%{} = parsed) do
    decision = normalize_proactive_decision(Map.get(parsed, "decision"))
    message_class = normalize_proactive_message_class(Map.get(parsed, "message_class"))
    assistant_message = normalize_message(Map.get(parsed, "assistant_message"))
    urgency = normalize_score(Map.get(parsed, "urgency"))
    interrupt_now = Map.get(parsed, "interrupt_now") in [true, "true", "TRUE", "1", 1]
    dedupe_key = normalize_message(Map.get(parsed, "dedupe_key"))
    todo_ids = normalize_string_list(Map.get(parsed, "todo_ids"))
    summary = normalize_message(Map.get(parsed, "summary"))

    with {:ok, decision} <- decision,
         :ok <- validate_proactive_message(decision, assistant_message) do
      {:ok,
       %{
         "decision" => decision,
         "assistant_message" => assistant_message,
         "message_class" => message_class,
         "urgency" => urgency,
         "interrupt_now" => interrupt_now,
         "dedupe_key" => dedupe_key,
         "todo_ids" => todo_ids,
         "summary" => summary
       }}
    end
  end

  defp normalize_proactive_decision(value) when value in @valid_proactive_decisions,
    do: {:ok, value}

  defp normalize_proactive_decision(_value), do: {:error, :assistant_harness_invalid_decision}

  defp normalize_proactive_message_class(value) when value in @valid_proactive_message_classes,
    do: value

  defp normalize_proactive_message_class(_value), do: "assistant_push"

  defp validate_proactive_message("send_now", ""), do: {:error, :assistant_harness_empty_message}
  defp validate_proactive_message(_decision, _assistant_message), do: :ok

  defp normalize_delivery_plan(%{} = parsed) do
    digest_intro = normalize_message(Map.get(parsed, "digest_intro"))
    summary = normalize_message(Map.get(parsed, "summary"))

    with {:ok, dispositions} <- normalize_delivery_dispositions(Map.get(parsed, "dispositions")) do
      {:ok,
       %{
         "dispositions" => dispositions,
         "digest_intro" => digest_intro,
         "summary" => summary
       }}
    end
  end

  defp normalize_delivery_dispositions(dispositions) when is_list(dispositions) do
    dispositions
    |> Enum.reduce_while({:ok, []}, fn disposition, {:ok, acc} ->
      case normalize_delivery_disposition(disposition) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_delivery_dispositions(_dispositions),
    do: {:error, :assistant_harness_invalid_dispositions}

  defp normalize_delivery_disposition(%{} = disposition) do
    candidate_id =
      normalize_message(Map.get(disposition, "candidate_id") || Map.get(disposition, "id"))

    disposition_value = normalize_message(Map.get(disposition, "disposition"))
    reason = normalize_message(Map.get(disposition, "reason"))

    cond do
      candidate_id == "" ->
        {:error, :assistant_harness_invalid_candidate_id}

      disposition_value not in @valid_delivery_dispositions ->
        {:error, :assistant_harness_invalid_disposition}

      true ->
        {:ok,
         %{
           "candidate_id" => candidate_id,
           "disposition" => disposition_value,
           "reason" => reason
         }}
    end
  end

  defp normalize_delivery_disposition(_disposition),
    do: {:error, :assistant_harness_invalid_dispositions}

  defp compact_tool_history(tool_history, policy) when is_list(tool_history) do
    tool_history
    |> Enum.reverse()
    |> Enum.take(policy.tool_evidence.history_limit)
    |> Enum.reverse()
    |> Enum.map(&compact_tool_history_entry(&1, policy))
  end

  defp compact_tool_history(_tool_history, _policy), do: []

  defp compact_tool_history_entry(entry, policy) when is_map(entry) do
    entry
    |> Map.take(["tool", "arguments", "result", "error"])
    |> Map.new(fn {key, value} -> {key, compact_tool_value(value, policy)} end)
  end

  defp compact_tool_history_entry(entry, policy) do
    compact_tool_value(entry, policy)
  end

  defp compact_tool_value(value, policy) when is_binary(value) do
    max_chars = policy.tool_evidence.max_string_chars

    if String.length(value) > max_chars do
      String.slice(value, 0, max_chars) <> "...[truncated]"
    else
      value
    end
  end

  defp compact_tool_value(value, policy) when is_list(value) do
    max_items = policy.tool_evidence.max_list_items
    total = length(value)

    compacted =
      value
      |> Enum.take(max_items)
      |> Enum.map(&compact_tool_value(&1, policy))

    if total > max_items do
      compacted ++ [%{"_truncated_items" => total - max_items}]
    else
      compacted
    end
  end

  defp compact_tool_value(value, policy) when is_map(value) do
    max_entries = policy.tool_evidence.max_map_entries
    entries = value |> Enum.sort_by(fn {key, _value} -> to_string(key) end)

    compacted =
      entries
      |> Enum.take(max_entries)
      |> Map.new(fn {key, nested_value} ->
        {to_string(key), compact_tool_value(nested_value, policy)}
      end)

    if length(entries) > max_entries do
      Map.put(compacted, "_truncated_keys", length(entries) - max_entries)
    else
      compacted
    end
  end

  defp compact_tool_value(%DateTime{} = value, _policy), do: DateTime.to_iso8601(value)
  defp compact_tool_value(%NaiveDateTime{} = value, _policy), do: NaiveDateTime.to_iso8601(value)
  defp compact_tool_value(%Date{} = value, _policy), do: Date.to_iso8601(value)
  defp compact_tool_value(%Time{} = value, _policy), do: Time.to_iso8601(value)

  defp compact_tool_value(value, policy) when is_struct(value) do
    value |> Map.from_struct() |> compact_tool_value(policy)
  end

  defp compact_tool_value(value, _policy) when is_tuple(value), do: inspect(value)
  defp compact_tool_value(value, _policy) when is_pid(value), do: inspect(value)
  defp compact_tool_value(value, _policy) when is_reference(value), do: inspect(value)
  defp compact_tool_value(value, _policy) when is_function(value), do: inspect(value)
  defp compact_tool_value(value, _policy), do: value

  defp current_user_request(context) when is_map(context) do
    context
    |> map_value("recent_turns", [])
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{} = turn ->
        role = Map.get(turn, :role) || Map.get(turn, "role")
        text = Map.get(turn, :text) || Map.get(turn, "text")

        if role == "user" and is_binary(text) and String.trim(text) != "" do
          %{
            role: role,
            text: String.trim(text),
            turn_kind: Map.get(turn, :turn_kind) || Map.get(turn, "turn_kind"),
            origin_type: Map.get(turn, :origin_type) || Map.get(turn, "origin_type"),
            inserted_at: Map.get(turn, :inserted_at) || Map.get(turn, "inserted_at")
          }
        end

      _other ->
        nil
    end) || %{}
  end

  defp current_user_request(_context), do: %{}

  defp focus_context(context, :connector_status) when is_map(context) do
    take_existing(context, [
      :user,
      :chat,
      :recent_turns,
      :connected_accounts,
      :source_freshness,
      :defaults,
      :context_diagnostics
    ])
    |> sanitize_prompt_context()
  end

  defp focus_context(context, :linked_item_context) when is_map(context) do
    take_existing(context, [
      :user,
      :chat,
      :conversation,
      :recent_turns,
      :linked_item,
      :preference_memory,
      :operator_memory,
      :user_memory,
      :deep_memory,
      :open_loops,
      :relationships,
      :open_insights,
      :todos,
      :briefing_schedule,
      :calendar,
      :connected_accounts,
      :source_freshness,
      :projects,
      :active_agents,
      :defaults,
      :connected_context_review,
      :context_diagnostics
    ])
    |> sanitize_prompt_context()
  end

  defp focus_context(context, :person_context) when is_map(context) do
    take_existing(context, [
      :user,
      :chat,
      :conversation,
      :recent_turns,
      :preference_memory,
      :operator_memory,
      :user_memory,
      :deep_memory,
      :open_loops,
      :relationships,
      :todos,
      :calendar,
      :briefing_schedule,
      :current_time,
      :connected_accounts,
      :source_freshness,
      :defaults,
      :connected_context_review,
      :context_diagnostics
    ])
    |> sanitize_prompt_context()
  end

  defp focus_context(context, :source_hint_identity) when is_map(context) do
    focus_context(context, :person_context)
  end

  defp focus_context(context, :meeting_prep) when is_map(context) do
    take_existing(context, [
      :user,
      :chat,
      :conversation,
      :recent_turns,
      :preference_memory,
      :operator_memory,
      :user_memory,
      :deep_memory,
      :open_loops,
      :relationships,
      :todos,
      :calendar,
      :briefing_schedule,
      :current_time,
      :connected_accounts,
      :source_freshness,
      :defaults,
      :connected_context_review,
      :context_diagnostics
    ])
    |> sanitize_prompt_context()
  end

  defp focus_context(context, :quick_chat) when is_map(context) do
    take_existing(context, [
      :user,
      :chat,
      :recent_turns,
      :preference_memory,
      :operator_memory,
      :user_memory,
      :briefing_schedule,
      :current_time,
      :context_diagnostics
    ])
    |> sanitize_prompt_context()
  end

  defp focus_context(context, :today_mode) when is_map(context) do
    take_existing(context, [
      :user,
      :chat,
      :conversation,
      :recent_turns,
      :preference_memory,
      :operator_memory,
      :user_memory,
      :deep_memory,
      :open_loops,
      :relationships,
      :open_insights,
      :todos,
      :calendar,
      :briefing_schedule,
      :current_time,
      :connected_accounts,
      :source_freshness,
      :defaults,
      :today_digest,
      :context_diagnostics
    ])
    |> sanitize_prompt_context()
  end

  defp focus_context(context, :waiting_on) when is_map(context) do
    take_existing(context, [
      :user,
      :chat,
      :conversation,
      :recent_turns,
      :preference_memory,
      :operator_memory,
      :user_memory,
      :deep_memory,
      :open_loops,
      :relationships,
      :todos,
      :briefing_schedule,
      :current_time,
      :connected_accounts,
      :source_freshness,
      :defaults,
      :today_digest,
      :context_diagnostics
    ])
    |> sanitize_prompt_context()
  end

  defp focus_context(context, _scope) when is_map(context), do: sanitize_prompt_context(context)
  defp focus_context(context, _scope), do: context

  defp focus_tools(tools, :connector_status) when is_list(tools) do
    Enum.filter(tools, &(tool_definition_name(&1) == "list_connected_accounts"))
  end

  defp focus_tools(_tools, :quick_chat), do: []

  @local_context_tools ~w(
    messages_search
    messages_get
    messages_list_recent
    messages_chats_recent
    notes_search
    notes_get
    notes_list_recent
    reminders_open
    reminders_due_soon
    reminders_search
    reminders_get
    files_search
    files_get
    files_list_recent
    browser_history_search
    browser_history_recent
    browser_history_by_host
    browser_history_get
    voice_memos_search
    voice_memos_get
    voice_memos_list_recent
  )

  defp focus_tools(tools, :linked_item_context) when is_list(tools) do
    allowed =
      MapSet.new(~w(
        inspect_open_insight
        list_todos
        resolve_todo
        update_todo
        delete_todo
        upsert_todos
        get_open_loops
        list_people
        get_person
        get_relationship_context
        review_connected_context
        learn_relationship_context
        link_person_data
        upsert_person
        merge_people
        delete_person
        recall_memory
        recall_anywhere
        list_memories
        write_memory
        record_memory_feedback
        update_memory_confidence
        forget_memory
        list_connected_accounts
        calendar_events_around
        calendar_events_for_person
        calendar_search
        calendar_event_get
        update_project_scope
        inspect_project
        list_projects
        list_implementation_runs
      ) ++ @local_context_tools)

    Enum.filter(tools, fn tool ->
      tool_definition_name(tool) in allowed
    end)
  end

  defp focus_tools(tools, :person_context) when is_list(tools) do
    allowed =
      MapSet.new(~w(
        list_todos
        resolve_todo
        update_todo
        delete_todo
        upsert_todos
        get_open_loops
        list_people
        get_person
        get_relationship_context
        review_connected_context
        learn_relationship_context
        link_person_data
        upsert_person
        merge_people
        delete_person
        recall_memory
        recall_anywhere
        list_memories
        write_memory
        calendar_events_around
        calendar_events_for_person
        calendar_search
        calendar_event_get
        list_connected_accounts
      ) ++ @local_context_tools)

    Enum.filter(tools, fn tool ->
      tool_definition_name(tool) in allowed
    end)
  end

  defp focus_tools(tools, :source_hint_identity) when is_list(tools) do
    focus_tools(tools, :person_context)
  end

  defp focus_tools(tools, :meeting_prep) when is_list(tools) do
    allowed =
      MapSet.new(~w(
        list_todos
        resolve_todo
        update_todo
        get_open_loops
        list_people
        get_person
        get_relationship_context
        review_connected_context
        recall_memory
        recall_anywhere
        list_memories
        write_memory
        calendar_events_around
        calendar_events_for_person
        calendar_search
        calendar_event_get
        list_connected_accounts
      ) ++ @local_context_tools)

    tools
    |> Enum.filter(fn tool -> tool_definition_name(tool) in allowed end)
    |> prioritize_tools(~w(
      calendar_events_for_person
      get_relationship_context
      review_connected_context
      list_todos
      get_open_loops
      calendar_events_around
      calendar_search
      calendar_event_get
    ))
  end

  defp focus_tools(tools, :today_mode) when is_list(tools) do
    allowed =
      MapSet.new(~w(
        get_open_loops
        list_todos
        resolve_todo
        update_todo
        delete_todo
        upsert_todos
        get_relationship_context
        review_connected_context
        recall_memory
        list_memories
        record_memory_feedback
        write_memory
        calendar_events_around
        reminders_open
        reminders_due_soon
        list_connected_accounts
      ) ++ @local_context_tools)

    Enum.filter(tools, fn tool ->
      tool_definition_name(tool) in allowed
    end)
  end

  defp focus_tools(tools, :waiting_on) when is_list(tools) do
    allowed =
      MapSet.new(~w(
        get_open_loops
        list_todos
        resolve_todo
        update_todo
        delete_todo
        upsert_todos
        list_people
        get_person
        get_relationship_context
        review_connected_context
        learn_relationship_context
        link_person_data
        merge_people
        delete_person
        recall_memory
        list_memories
        record_memory_feedback
        write_memory
        list_connected_accounts
      ) ++ @local_context_tools)

    Enum.filter(tools, fn tool ->
      tool_definition_name(tool) in allowed
    end)
  end

  defp focus_tools(tools, _scope), do: tools

  defp prioritize_tools(tools, preferred_names)
       when is_list(tools) and is_list(preferred_names) do
    order =
      preferred_names
      |> Enum.with_index()
      |> Map.new()

    tools
    |> Enum.with_index()
    |> Enum.sort_by(fn {tool, index} ->
      {Map.get(order, tool_definition_name(tool), length(preferred_names)), index}
    end)
    |> Enum.map(fn {tool, _index} -> tool end)
  end

  defp normalize_focus(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp normalize_focus(value) when is_binary(value), do: value
  defp normalize_focus(_value), do: nil

  defp tool_definition_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_definition_name(%{name: name}) when is_binary(name), do: name
  defp tool_definition_name(%{"tool" => name}) when is_binary(name), do: name
  defp tool_definition_name(name) when is_binary(name), do: name
  defp tool_definition_name(_tool), do: nil

  defp take_existing(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      string_key = Atom.to_string(key)

      cond do
        Map.has_key?(map, key) ->
          Map.put(acc, key, Map.get(map, key))

        Map.has_key?(map, string_key) ->
          Map.put(acc, key, Map.get(map, string_key))

        true ->
          acc
      end
    end)
  end

  defp sanitize_prompt_context(context) when is_map(context) do
    context
    |> sanitize_prompt_context_key(:defaults)
    |> sanitize_prompt_context_key("defaults")
  end

  defp sanitize_prompt_context(context), do: context

  defp sanitize_prompt_context_key(context, key) do
    case Map.fetch(context, key) do
      {:ok, defaults} -> Map.put(context, key, prompt_safe_defaults(defaults))
      :error -> context
    end
  end

  defp prompt_safe_defaults(defaults) when is_map(defaults) do
    providers = prompt_safe_providers(defaults)

    %{}
    |> put_present(:default_project_id, map_value(defaults, "default_project_id", nil))
    |> put_present(:default_project_slug, map_value(defaults, "default_project_slug", nil))
    |> put_present(:providers, providers)
    |> Map.put(:linear_connected, prompt_safe_linear_connected?(defaults, providers))
  end

  defp prompt_safe_defaults(_defaults), do: %{}

  defp prompt_safe_providers(defaults) when is_map(defaults) do
    [
      map_value(defaults, "providers", []),
      map_value(defaults, "provider_ids", [])
    ]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.map(&public_provider/1)
    |> normalize_string_list()
    |> Enum.sort()
  end

  defp prompt_safe_linear_connected?(defaults, providers) do
    case map_value(defaults, "linear_connected", nil) do
      value when value in [true, false] -> value
      _other -> "linear" in providers
    end
  end

  defp public_provider("google:" <> _), do: "google"
  defp public_provider("slack:" <> _), do: "slack"
  defp public_provider(provider) when is_binary(provider), do: provider
  defp public_provider(nil), do: nil
  defp public_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp public_provider(_provider), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp emit_tool_loop_telemetry(loop) do
    :telemetry.execute(
      [:maraithon, :assistant_harness, :tool_loop],
      %{count: loop.count},
      %{tool: loop.tool, classification: loop.class}
    )
  end

  defp normalize_score(value) when is_float(value), do: min(max(value, 0.0), 1.0)
  defp normalize_score(value) when is_integer(value), do: normalize_score(value / 1)

  defp normalize_score(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> normalize_score(parsed)
      _other -> 0.0
    end
  end

  defp normalize_score(_value), do: 0.0

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_message/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(_values), do: []

  defp max_tool_calls_per_step(payload) do
    payload
    |> map_value("runtime_policy", %{})
    |> map_value("tool_calls", %{})
    |> map_value("max_per_step", @max_tool_calls_per_step)
    |> positive_integer(@max_tool_calls_per_step)
  end

  defp allowed_tool_names(payload) do
    payload
    |> map_value("tools", [])
    |> Enum.flat_map(fn
      %{"name" => name} when is_binary(name) -> [name]
      %{name: name} when is_binary(name) -> [name]
      %{"tool" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _other -> []
    end)
  end

  defp normalize_message(value) when is_binary(value), do: String.trim(value)
  defp normalize_message(_value), do: ""

  defp human_tool_name(tool)
       when tool in [
              "get_open_work_summary",
              "get_open_loops",
              "list_todos",
              "upsert_todos",
              "update_todo",
              "resolve_todo",
              "delete_todo"
            ],
       do: "open work"

  defp human_tool_name("list_connected_accounts"), do: "connected accounts"

  defp human_tool_name(tool)
       when tool in [
              "gmail_search_messages",
              "gmail_get_message",
              "gmail_send_message",
              "gmail_drafts",
              "draft_message",
              "messages_search",
              "messages_get",
              "messages_list_recent",
              "messages_chats_recent"
            ],
       do: "messages"

  defp human_tool_name(tool)
       when tool in [
              "calendar_list_events",
              "calendar_events_around",
              "calendar_events_for_person",
              "calendar_search",
              "calendar_event_get"
            ],
       do: "calendar"

  defp human_tool_name(tool)
       when tool in ["slack_search_messages", "slack_get_thread_context", "slack_post_message"],
       do: "Slack"

  defp human_tool_name(tool)
       when tool in [
              "linear_list_or_lookup",
              "linear_create_issue",
              "linear_create_comment",
              "linear_update_issue_state"
            ],
       do: "Linear"

  defp human_tool_name(tool)
       when tool in ["notaui_list_tasks", "notaui_complete_task", "notaui_update_task"],
       do: "Notaui"

  defp human_tool_name(tool)
       when tool in [
              "list_people",
              "get_relationship_context",
              "learn_relationship_context",
              "link_person_data",
              "upsert_person",
              "merge_people",
              "delete_person"
            ],
       do: "people"

  defp human_tool_name(tool)
       when tool in [
              "list_preferences",
              "remember_preferences",
              "forget_preference",
              "record_memory_feedback"
            ],
       do: "preferences"

  defp human_tool_name(tool)
       when tool in [
              "list_memories",
              "recall_memory",
              "write_memory",
              "update_memory_confidence",
              "forget_memory"
            ],
       do: "memory"

  defp human_tool_name(tool)
       when tool in ["list_projects", "inspect_project", "update_project_scope"],
       do: "projects"

  defp human_tool_name(tool)
       when tool in [
              "list_scheduled_tasks",
              "create_scheduled_task",
              "pause_scheduled_task",
              "cancel_scheduled_task"
            ],
       do: "scheduled work"

  defp human_tool_name(tool)
       when tool in [
              "list_implementation_runs",
              "start_implementation_run",
              "update_implementation_run"
            ],
       do: "implementation work"

  defp human_tool_name(tool)
       when tool in ["list_agents", "inspect_agent", "prepare_agent_action", "query_agent"],
       do: "automations"

  defp human_tool_name(tool)
       when tool in ["notes_search", "notes_get", "notes_list_recent"],
       do: "Notes"

  defp human_tool_name(tool)
       when tool in ["reminders_open", "reminders_due_soon", "reminders_search", "reminders_get"],
       do: "Reminders"

  defp human_tool_name(tool)
       when tool in ["files_search", "files_get", "files_list_recent"],
       do: "files"

  defp human_tool_name(tool)
       when tool in [
              "browser_history_recent",
              "browser_history_by_host",
              "browser_history_search",
              "browser_history_get"
            ],
       do: "browser history"

  defp human_tool_name("review_connected_context"), do: "connected context"
  defp human_tool_name("recall_anywhere"), do: "connected context"

  defp human_tool_name(tool) when is_binary(tool) do
    tool
    |> String.replace(~r/(?:^|[_.\s-])tool(?:$|[_.\s-])/i, " ")
    |> String.replace(~r/[_.-]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "that source"
      name -> name
    end
  end

  defp human_tool_name(_tool), do: "that source"

  defp map_value(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, existing_atom_key(key)) || default
  end

  defp map_value(_map, _key, default), do: default

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
