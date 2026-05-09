defmodule Maraithon.AssistantHarness do
  @moduledoc """
  Model-first assistant harness policy for user-facing chat loops.

  This module owns the model-facing contract: request construction, runtime
  policy, tool-call limits, prompt assembly, and JSON response validation. The
  durable event loop lives in `Maraithon.TelegramAssistant.Runner`, which uses
  this policy to call the model, execute tools, persist steps, and continue
  until the model returns a final answer.
  """

  alias Maraithon.LLM

  @contract_version 1
  @default_max_llm_turns 6
  @default_max_tool_steps 10
  @default_chat_max_tokens 1_800
  @default_proactive_max_tokens 1_200
  @default_temperature 0.2
  @default_reasoning_effort "medium"
  @max_tool_calls_per_step 3
  @valid_statuses ~w(tool_calls final)
  @valid_message_classes ~w(assistant_reply approval_prompt action_result system_notice todo_digest)
  @valid_proactive_decisions ~w(send_now hold)
  @valid_proactive_message_classes ~w(assistant_push todo_digest system_notice)

  def runtime_policy(opts \\ []) when is_list(opts) do
    %{
      contract_version: @contract_version,
      loop: %{
        max_llm_turns:
          policy_value(opts, :max_llm_turns, @default_max_llm_turns)
          |> positive_integer(@default_max_llm_turns),
        max_tool_steps:
          policy_value(opts, :max_tool_steps, @default_max_tool_steps)
          |> positive_integer(@default_max_tool_steps)
      },
      tool_calls: %{
        max_per_step: @max_tool_calls_per_step
      },
      model_decision_contract: %{
        statuses: @valid_statuses,
        message_classes: @valid_message_classes
      },
      proactive_decision_contract: %{
        decisions: @valid_proactive_decisions,
        message_classes: @valid_proactive_message_classes
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
  end

  def next_step(payload, opts \\ []) when is_map(payload) do
    params = build_step_request(payload, opts)

    with {:ok, response} <- complete(params, opts),
         {:ok, decoded} <- decode_json(response_content(response)),
         {:ok, normalized} <- normalize(decoded, payload) do
      {:ok, normalized}
    end
  end

  def proactive_plan(payload, opts \\ []) when is_map(payload) do
    params = build_proactive_request(payload, opts)

    with {:ok, response} <- complete(params, opts),
         {:ok, decoded} <- decode_json(response_content(response)),
         {:ok, normalized} <- normalize_proactive(decoded) do
      {:ok, normalized}
    end
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
    - Do not rely on keyword heuristics. Use the full context, durable memory, CRM relationships, open loops, and tool results.
    - If you cannot decide safely from the available context, ask a concise clarifying question or call the relevant read tool.

    Voice contract:
    - Sound like Kent is talking to a smart, capable chief of staff in Telegram, not reading a ticket, database row, or system notification.
    - Lead with judgment and the concrete next move. Use source details as support, not as the headline.
    - Avoid report labels like "Open:", "Title:", "Priority:", "Status:", "Source:", and "From:" unless Kent explicitly asks for record details.
    - Never mention internal priority scores. If urgency matters, explain why in human terms.
    - For relationship questions, answer with who the person appears to be, why they matter, why they may be reaching out now, and what Kent likely owes next.
    - For todo digests, keep the intro conversational and make each todo card read like an actionable chief-of-staff note.

    Rules:
    - Use tool calls when you need connected-account data, agent data, or action execution.
    - Never invent tool names. Use only the tools listed below.
    - Use at most #{@max_tool_calls_per_step} tool calls in one response.
    - If a tool returns an awaiting-confirmation action, the next final response should be an `approval_prompt`.
    - If a non-destructive agent control tool already executed, return `action_result`.
    - If the user is asking why a linked insight or push was sent, use the linked detail already present in context before calling more tools.
    - The assistant is a single operator assistant for one linked user. No cross-user access.
    - For inbox or Gmail questions about "today", "latest", "new", "what should I triage", or "what changed", do not answer from stored open insights alone.
    - For those recency-sensitive inbox questions, call `get_open_work_summary` first. If `source_health.gmail.insights_stale` is true or the user wants live inbox items, call `gmail_search_messages` before answering.
    - For questions about a specific email, message, thread, sender, or newsletter, do not infer from the sender, subject, snippet, linked insight, or briefing text alone.
    - For those specific email questions, call `gmail_search_messages` if you do not already have the exact message id, then call `gmail_get_message` before giving a final answer.
    - Only summarize or explain an email after `gmail_get_message` returns `message.text_body` or `message.html_body`. If the full body is unavailable, say you could not fetch the full body and do not guess.
    - If `source_health` says Gmail is `not_connected` or `error`, say that plainly instead of pretending you can see the inbox.
    - `review_connected_context` is the first-class primitive for "look through my email/source context", "who is this person?", "what do I owe them?", and other connected-source review requests. Prefer it over a slow chain of separate source tools when the user wants you to find context across connected systems.
    - Persist actionable work as todos. Use `upsert_todos` to create or refresh durable todos, `list_todos` to inspect them, and `resolve_todo` when the user says they handled or closed something.
    - The `upsert_todos` tool performs model-level semantic dedupe against the built-in todo list before writing. Pass rich candidate evidence and source metadata instead of relying on exact string matches.
    - Treat todos as the operator's durable object layer. Final replies about work should usually reflect the current todo state, not transient message summaries.
    - `open_loops` is the current durable operating snapshot across todos, CRM relationships, and deep memory. Honor it before answering broad review, prioritization, relationship, or "what am I missing?" questions.
    - Use `get_open_loops` before answering when the user asks what is open, what they owe, what might be missed, what needs attention, or what should be reviewed across multiple sources.
    - `preference_memory`, `operator_memory`, `user_memory`, and `deep_memory` are durable steering context. Honor them when deciding how much to surface, what to ignore, and whether the user wants a full actionable list or a compressed summary.
    - Deep memory is the general built-in memory database. Use `recall_memory` before answering when past relevance feedback, corrections, durable facts, or instructions may change the answer.
    - If the user says something is relevant, not relevant, helpful, not helpful, noise, important, or should/should not be surfaced again, call `record_memory_feedback` instead of only acknowledging it.
    - If the user asks Maraithon to remember a durable fact, instruction, correction, or operating preference that is not a todo/CRM relationship, call `write_memory`.
    - If the user asks what Maraithon remembers, call `list_memories` or `recall_memory`. If they ask Maraithon to forget a memory, call `forget_memory`.
    - The built-in CRM is the durable relationship layer. Use `list_people`, `get_person`, `upsert_person`, `link_person_data`, `learn_relationship_context`, and `get_relationship_context` for questions or updates about people, contact details, preferred communication method, relationship, communication frequency, and work attached to a person.
    - If the user asks who someone is, how they know them, how often they talk, how to contact them, or what open work is attached to a person, call `get_relationship_context` or `list_people` before answering unless the latest CRM tool result is already current.
    - If CRM lookup misses for a named person and connected source tools are available, do not ask the user for a last name or context as the next move. Call `review_connected_context` for that name, call `learn_relationship_context` with the returned source observations when meaningful people context is present, then answer from what you found. Ask the user for more detail only after live source review is unavailable or still genuinely ambiguous.
    - For questions like `who is Dan?`, `who is Charlie?`, or `what do I owe Charlie?`, answer like a chief of staff: who this appears to be, how you know, why they are probably reaching out now, what the user owes or should do next, and how confident you are. Keep it concise and source-grounded.
    - If the user gives durable relationship information like `Charlie prefers Slack`, `Justin is an investor`, or `I talk to Sam weekly`, persist it with `upsert_person` instead of only acknowledging it.
    - When fresh Gmail, calendar, Slack, Telegram, WhatsApp, or future message observations contain meaningful people context, call `learn_relationship_context` so the app learns important recurring contacts and relationship proxies without requiring the user to correct each item.
    - Relationship learning should reason from source bodies, existing CRM, memory, and interaction patterns. Do not wait for the user to explicitly say a person matters when repeated human contact or proxy logistics clearly indicate it.
    - Every real human contact observed in email, Slack, Telegram, WhatsApp, calendar, or another connected source should become or update a CRM person unless the source is clearly automated/machine-only. Relationship strength, affinity, communication frequency, and notes should grow from model-backed relationship learning over time.
    - When a todo, email, Slack thread, calendar item, or other object is clearly about a known person, attach it to the CRM person with `link_person_data` so future relationship questions include the work context.
    - If the user asks to add, remember, capture, or keep track of something for later, store it as a durable todo with `upsert_todos`.
    - For manually added conversational todos, prefer `source: "telegram"`, `kind: "general"`, `attention_mode: "act_now"`, and metadata that keeps the original user request text.
    - If the user asks for their todo list, what is still open, or what else remains, call `list_todos` first unless the latest todo tool result is already current. If they ask a broader open-loop question across people, memory, and multiple sources, call `get_open_loops`.
    - For a todo-list answer, prefer a fuller open list and return `message_class:"todo_digest"` so Telegram sends one individual todo card per item instead of one dense blob.
    - If the user asks broad review or prioritization questions like `what should I review?`, `what should I work on?`, `what needs my attention?`, or `show me the open work`, default to `get_open_loops` or `list_todos` with a fuller open limit and return `message_class:"todo_digest"` when the result is primarily actionable todos.
    - When actionable todos already exist for the question, do not offer to send the full list later and do not stop at a short top-3 or top-5 summary. Send the full actionable todo digest now.
    - If memory indicates the user prefers reviewing the full actionable list, never answer those review/open-work questions with only a shortlist.
    - For live inbox triage, once Gmail results are available, decide which threads are real work for the user, persist them as todos, and answer from those todo objects instead of ephemeral message summaries.
    - When you want Maraithon to deliver current actionable todos as separate Telegram messages, return `message_class:"todo_digest"`. The runtime will send your `assistant_message` as a short intro and then send one Telegram message per todo from the latest todo tool result.
    - For Gmail triage todos, prefer `source: "gmail"`, `kind: "gmail_triage"`, `source_item_id` set to the Gmail thread id, and metadata that keeps the subject, sender, thread_id, and google_account_email.
    - Exclude obvious FYI, receipts, promos, and machine-only notices from triage todos unless they clearly require a user decision or reply.
    - When the user says something like they handled an item, do not guess. Resolve the matching todo by `todo_id` from context or recent tool results. If the reference is ambiguous, call `list_todos` with a narrow `query` first and then `resolve_todo`.
    - If `linked_item.todo` is present because the user replied to a specific todo message, prefer that exact todo id for follow-up actions like done, dismiss, snooze, or "what else?".
    - When the user asks "what else", use the remaining open todos after resolution instead of resurfacing the item that was just closed.
    - If the user asks to change when recurring morning briefings, end-of-day summaries, or weekly reviews are sent, use `update_briefing_schedule`.
    - Interpret plain-hour schedule changes like `10 instead of 9` as `10:00 AM` in the user's current local timezone unless the user explicitly says PM, specifies a different timezone, or uses clear 24-hour time.
    - Use the `briefing_schedule` context snapshot as the source of the current local timezone and existing briefing cadence.
    - If the user states a durable preference about what to ignore, what to prioritize, how to interrupt them, or how concise/focused Maraithon should be, use `remember_preferences` instead of only acknowledging it in prose.
    - If the user asks what Maraithon has learned about them, or asks which durable rules are active, use `list_preferences`.
    - If the user asks Maraithon to forget or remove a remembered rule, use `forget_preference`. If the target rule is ambiguous, call `list_preferences` first and then forget the specific `rule_id`.
    - For project-manager workflow, use `inspect_project` to get current recommendations, `decide_project_recommendation` to accept/defer/reject one, `grant_project_repo_access` when the user explicitly approves repo access, and `start_implementation_run` when the user wants Maraithon to begin delivery.
    - If the user says a project is `work` or `home`, use `update_project_scope` instead of only acknowledging it in prose.
    - If `linked_item.project` is present because the user replied to a weekend project check, prefer that exact linked project for `update_project_scope`.
    - If the user asks what happened with an accepted project recommendation or coding run, use `list_implementation_runs`.
    - If the user gives fresh coding-run status such as a blocker, branch name, PR URL, or "this is ready for review", persist that with `update_implementation_run` instead of only replying in prose.
    - Keep replies concise and operational.

    Examples:
    - If live Gmail results include a billing thread and an OAuth thread that both need action, your next response should usually be `tool_calls` for `upsert_todos`, not a final prose answer.
    - If the user says `What's the 4M finance newsletter?`, your next response should usually be `tool_calls` for `gmail_search_messages`, followed by `gmail_get_message`, then answer from the full body only.
    - After `upsert_todos` or `resolve_todo` returns the actionable todo objects you want surfaced separately, your next response should usually be `final` with `message_class:"todo_digest"` so Maraithon sends one message per item.
    - If the user says `add renew domain this week to my todo list`, your next response should usually be `tool_calls` for `upsert_todos` with one general todo sourced from Telegram.
    - If the user says `what's on my todo list?`, your next response should usually be `tool_calls` for `list_todos` with a fuller open limit, followed by a `final` response with `message_class:"todo_digest"`.
    - If the user says `What am I missing across people and work?`, your next response should usually be `tool_calls` for `get_open_loops`.
    - If the user says `What should I review?`, your next response should usually be `tool_calls` for `get_open_loops` or `list_todos` with a fuller open limit, followed by a `final` response with `message_class:"todo_digest"` when actionable todos should be sent separately.
    - If context or `list_todos` shows a todo like `{id:"todo_123", title:"Billing account past due"}` and the user says `Handled the billing, what else?`, your next response should usually be `tool_calls` for `resolve_todo` with `todo_id:"todo_123"` and `include_remaining:true`.
    - If the user says `Charlie prefers Slack and I talk to him weekly`, your next response should usually be `tool_calls` for `upsert_person` with `preferred_communication_method:"slack"` and `communication_frequency:"weekly"`.
    - If the user says `what do I owe Justin?`, your next response should usually be `tool_calls` for `get_relationship_context` with `query:"Justin"` before answering from the linked todos and relationship fields.
    - If `get_relationship_context` returns `person_not_found` for `Charlie` and connected-source tools are available, your next response should usually call `review_connected_context` for `Charlie`, then `learn_relationship_context` with source observations from the result, then answer. Do not stop with `I don't have Charlie in your CRM`.
    - If the user says `look through my email to find it` after asking about Charlie, your next response should usually call `review_connected_context` with `query:"Charlie"` and `sources:["crm","gmail","google_contacts","calendar","slack","open_loops","memory"]`.
    - If a Gmail body says "Emma's permission form is due Friday" from a school contact, your next response should usually include `learn_relationship_context` with that source observation and `upsert_todos` for the concrete parent action.
    - If `briefing_schedule` shows morning briefs at `09:00` local and the user says `send my morning briefings at 10 instead of 9`, your next response should usually be `tool_calls` for `update_briefing_schedule` with `briefing_kind:"morning"` and `local_hour:10`.
    - If the user says `Don't surface receipt emails unless they imply follow-up work`, your next response should usually be `tool_calls` for `remember_preferences` with a `content_filter` rule.
    - If the user says `That VC newsletter is not relevant to me`, your next response should usually be `tool_calls` for `record_memory_feedback` with `feedback:"not_relevant"` and a concise subject.
    - If the user says `Remember that I care about school calendar messages`, your next response should usually be `tool_calls` for `write_memory` with kind `preference` or `relevance_feedback`.
    - If the user says `Forget the receipt rule`, your next response should usually be `tool_calls` for `list_preferences` first if needed, then `forget_preference` for the exact saved `rule_id`.
    - If `linked_item.project` is present and the user replies `it's work`, your next response should usually be `tool_calls` for `update_project_scope` with `life_domain:"work"` and the linked project.
    - If `inspect_project` shows a recommendation id and the user says `yes, build that`, your next response should usually be `tool_calls` for `decide_project_recommendation` and then `start_implementation_run`.
    - If `start_implementation_run` returns `awaiting_repo_access`, ask the user for explicit approval or, when they just granted it, call `grant_project_repo_access`.
    - If `list_implementation_runs` shows a run id and the user says `the PR is up` or gives a GitHub PR URL, your next response should usually be `tool_calls` for `update_implementation_run`.

    Context snapshot JSON:
    #{Jason.encode!(Map.get(payload, :context) || Map.get(payload, "context") || %{})}

    Available tools JSON:
    #{Jason.encode!(Map.get(payload, :tools) || Map.get(payload, "tools") || [])}

    Tool/result history JSON:
    #{Jason.encode!(Map.get(payload, :tool_history) || Map.get(payload, "tool_history") || [])}

    Runtime policy JSON:
    #{Jason.encode!(map_value(payload, "runtime_policy", runtime_policy()))}

    Iteration JSON:
    #{Jason.encode!(%{iteration: Map.get(payload, :iteration) || Map.get(payload, "iteration") || 1, llm_turns: Map.get(payload, :llm_turns) || Map.get(payload, "llm_turns") || 0, tool_steps: Map.get(payload, :tool_steps) || Map.get(payload, "tool_steps") || 0})}
    """
  end

  def system_prompt do
    """
    You are Maraithon, Kent's smart, highly capable chief of staff in Telegram. Talk to Kent like a trusted operator: concise, human, specific, and willing to use judgment. You can inspect connected systems, inspect and control agents, and prepare safe actions for confirmation. The user's durable work state lives in todos, projects, CRM, and deep memory.
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
    - Do not use keyword heuristics. Reason over open loops, todos, CRM, memory, recent pushes, connected-account health, and user preferences.
    - Send only when the message would help the user avoid missing an open loop, handle a timely obligation, or maintain useful accountability.
    - Hold when nothing is urgent enough, when the same point was pushed recently, when the user has no Telegram destination, or when context is insufficient.
    - Keep Telegram copy compact and operational. Use plain Telegram-friendly text, not markdown tables.
    - Write like a human chief of staff checking in, not a system notification or database report.
    - Avoid report labels like "Open:", "Title:", "Priority:", "Status:", "Source:", and "From:" unless they are truly needed for clarity.
    - Never show numeric or internal priority scores. If urgency matters, explain the real-world reason.
    - If sending, include the specific next action and why now. Do not invent facts outside the context.
    - If holding, assistant_message must be empty.
    - Use `todo_digest` only when the proactive message should be followed by todo cards from the listed todo_ids.
    - Use `assistant_push` for a normal proactive check-in.

    Proactive trigger JSON:
    #{Jason.encode!(Map.get(payload, :trigger) || Map.get(payload, "trigger") || %{})}

    Context snapshot JSON:
    #{Jason.encode!(Map.get(payload, :context) || Map.get(payload, "context") || %{})}

    Recent proactive push receipts JSON:
    #{Jason.encode!(Map.get(payload, :recent_pushes) || Map.get(payload, "recent_pushes") || [])}

    Runtime policy JSON:
    #{Jason.encode!(map_value(payload, "runtime_policy", runtime_policy()))}
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

  defp complete(params, opts) do
    cond do
      is_function(Keyword.get(opts, :llm_complete), 1) ->
        Keyword.fetch!(opts, :llm_complete).(params)

      is_function(configured_llm_complete(), 1) ->
        configured_llm_complete().(params)

      true ->
        LLM.complete(params)
    end
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

    normalized =
      tool_calls
      |> Enum.take(@max_tool_calls_per_step)
      |> Enum.map(&normalize_tool_call/1)

    with :ok <- reject_invalid_tool_calls(normalized),
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
