defmodule Maraithon.TelegramAssistant.Client.LLMJson do
  @moduledoc """
  JSON-contract model client for the Telegram assistant loop.
  """

  @behaviour Maraithon.TelegramAssistant.Client

  alias Maraithon.LLM

  @max_tool_calls_per_step 3
  @live_inbox_search_max_results 15
  @live_inbox_lookback_days 14
  @live_latest_lookback_days 7
  @fallback_response %{
    "status" => "final",
    "assistant_message" =>
      "I need a moment to recover. Ask again or tell me exactly what you want me to inspect.",
    "message_class" => "system_notice",
    "tool_calls" => [],
    "summary" => "Fallback response used because the model output was invalid."
  }

  @impl true
  def next_step(payload) when is_map(payload) do
    case maybe_handle_live_gmail_request(payload) do
      {:ok, response} ->
        {:ok, response}

      :continue ->
        prompt = build_prompt(payload)

        params = %{
          "messages" => [
            %{"role" => "system", "content" => system_prompt()},
            %{"role" => "user", "content" => prompt}
          ],
          "max_tokens" => 1800,
          "temperature" => 0.2,
          "reasoning_effort" => "medium"
        }

        with {:ok, response} <- LLM.provider().complete(params),
             {:ok, decoded} <- decode_json(response.content) do
          {:ok, normalize(decoded)}
        end
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
    - If `source_health` says Gmail is `not_connected` or `error`, say that plainly instead of pretending you can see the inbox.
    - Persist actionable work as todos. Use `upsert_todos` to create or refresh durable todos, `list_todos` to inspect them, and `resolve_todo` when the user says they handled or closed something.
    - Treat todos as the operator's durable object layer. Final replies about work should usually reflect the current todo state, not transient message summaries.
    - `preference_memory`, `operator_memory`, and `user_memory` are durable steering context. Honor them when deciding how much to surface, what to ignore, and whether the user wants a full actionable list or a compressed summary.
    - If the user asks to add, remember, capture, or keep track of something for later, store it as a durable todo with `upsert_todos`.
    - For manually added conversational todos, prefer `source: "telegram"`, `kind: "general"`, `attention_mode: "act_now"`, and metadata that keeps the original user request text.
    - If the user asks for their todo list, what is still open, or what else remains, call `list_todos` first unless the latest todo tool result is already current.
    - For a todo-list answer, prefer a fuller open list and return `message_class:"todo_digest"` so Telegram sends one individual todo card per item instead of one dense blob.
    - If the user asks broad review or prioritization questions like `what should I review?`, `what should I work on?`, `what needs my attention?`, or `show me the open work`, default to `list_todos` with a fuller open limit and return `message_class:"todo_digest"` so the user can act on each item individually.
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
    - After `upsert_todos` or `resolve_todo` returns the actionable todo objects you want surfaced separately, your next response should usually be `final` with `message_class:"todo_digest"` so Maraithon sends one message per item.
    - If the user says `add renew domain this week to my todo list`, your next response should usually be `tool_calls` for `upsert_todos` with one general todo sourced from Telegram.
    - If the user says `what's on my todo list?`, your next response should usually be `tool_calls` for `list_todos` with a fuller open limit, followed by a `final` response with `message_class:"todo_digest"`.
    - If the user says `What should I review?`, your next response should usually be `tool_calls` for `list_todos` with a fuller open limit, followed by a `final` response with `message_class:"todo_digest"` instead of a prose shortlist.
    - If context or `list_todos` shows a todo like `{id:"todo_123", title:"Billing account past due"}` and the user says `Handled the billing, what else?`, your next response should usually be `tool_calls` for `resolve_todo` with `todo_id:"todo_123"` and `include_remaining:true`.
    - If `briefing_schedule` shows morning briefs at `09:00` local and the user says `send my morning briefings at 10 instead of 9`, your next response should usually be `tool_calls` for `update_briefing_schedule` with `briefing_kind:"morning"` and `local_hour:10`.
    - If the user says `Don't surface receipt emails unless they imply follow-up work`, your next response should usually be `tool_calls` for `remember_preferences` with a `content_filter` rule.
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

    Iteration JSON:
    #{Jason.encode!(%{iteration: Map.get(payload, :iteration) || Map.get(payload, "iteration") || 1, llm_turns: Map.get(payload, :llm_turns) || Map.get(payload, "llm_turns") || 0, tool_steps: Map.get(payload, :tool_steps) || Map.get(payload, "tool_steps") || 0})}
    """
  end

  defp system_prompt do
    """
    You are Maraithon, a Telegram operator assistant. You can inspect connected systems, inspect and control agents, and prepare safe actions for confirmation. The user's durable work state lives in todos, projects, and memory.
    """
  end

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
      _ -> {:error, :invalid_json}
    end
  end

  defp normalize(%{} = parsed) do
    status =
      case Map.get(parsed, "status") || Map.get(parsed, "type") do
        "tool_calls" -> "tool_calls"
        _ -> "final"
      end

    %{
      "status" => status,
      "assistant_message" => normalize_message(Map.get(parsed, "assistant_message")),
      "message_class" => normalize_message_class(Map.get(parsed, "message_class")),
      "tool_calls" => normalize_tool_calls(Map.get(parsed, "tool_calls")),
      "summary" => normalize_message(Map.get(parsed, "summary"))
    }
  end

  defp normalize(_parsed), do: @fallback_response

  defp normalize_message_class(value)
       when value in [
              "assistant_reply",
              "approval_prompt",
              "action_result",
              "system_notice",
              "todo_digest"
            ],
       do: value

  defp normalize_message_class(_value), do: "assistant_reply"

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.take(@max_tool_calls_per_step)
    |> Enum.flat_map(fn
      %{"tool" => tool, "arguments" => arguments} when is_binary(tool) and is_map(arguments) ->
        [%{"tool" => tool, "arguments" => arguments}]

      %{"name" => tool, "arguments" => arguments} when is_binary(tool) and is_map(arguments) ->
        [%{"tool" => tool, "arguments" => arguments}]

      _ ->
        []
    end)
  end

  defp normalize_tool_calls(_tool_calls), do: []

  defp normalize_message(value) when is_binary(value), do: String.trim(value)
  defp normalize_message(_value), do: ""

  defp maybe_handle_live_gmail_request(payload) do
    with {:ok, request_type, message_text} <- live_gmail_request(payload) do
      handle_live_gmail_request(payload, request_type, message_text)
    else
      _ -> :continue
    end
  end

  defp live_gmail_request(payload) do
    case latest_user_message(payload) do
      message when is_binary(message) ->
        cond do
          live_gmail_latest_request?(message) ->
            {:ok, :latest_visible, message}

          live_gmail_triage_request?(message) ->
            {:ok, :triage, message}

          true ->
            :error
        end

      _ ->
        :error
    end
  end

  defp handle_live_gmail_request(payload, request_type, message_text) do
    tool_history = tool_history(payload)

    cond do
      is_nil(latest_tool_result(tool_history, "get_open_work_summary")) ->
        {:ok,
         tool_call_response(
           "Need source health before answering a live Gmail question.",
           "get_open_work_summary",
           %{"limit" => 5}
         )}

      true ->
        open_work = latest_tool_result(tool_history, "get_open_work_summary") || %{}
        gmail_health = nested_value(open_work, ["source_health", "gmail"]) || %{}
        gmail_status = string_value(gmail_health, "status")

        case gmail_status do
          "not_connected" ->
            {:ok,
             final_response(
               "I can't inspect Gmail live right now because Gmail is not connected.",
               "Live Gmail access unavailable."
             )}

          "error" ->
            {:ok,
             final_response(
               "I can't inspect Gmail live right now because Google access failed. I flagged that so you can reconnect it.",
               "Live Gmail access failed."
             )}

          _ ->
            continue_live_gmail_request(tool_history, request_type, message_text, gmail_health)
        end
    end
  end

  defp continue_live_gmail_request(tool_history, request_type, message_text, gmail_health) do
    case latest_tool_result(tool_history, "gmail_search_messages") do
      nil ->
        {:ok,
         tool_call_response(
           "Need a live Gmail search before answering this inbox question.",
           "gmail_search_messages",
           %{
             "query" => build_live_gmail_query(request_type, message_text),
             "max_results" => @live_inbox_search_max_results
           }
         )}

      %{} = search_result when request_type == :latest_visible ->
        {:ok, build_live_gmail_final_response(request_type, gmail_health, search_result)}

      %{} when request_type == :triage ->
        :continue
    end
  end

  defp build_live_gmail_final_response(:latest_visible, gmail_health, search_result) do
    messages = search_messages(search_result)

    case List.first(sort_live_messages(messages)) do
      nil ->
        final_response(
          latest_visible_no_results_text(gmail_health),
          "Live Gmail search returned no visible messages."
        )

      message ->
        final_response(
          latest_visible_text(gmail_health, message),
          "Returned the latest visible Gmail message."
        )
    end
  end

  defp latest_user_message(payload) do
    payload
    |> context()
    |> map_value("recent_turns", [])
    |> Enum.reverse()
    |> Enum.find_value(fn turn ->
      if string_value(turn, "role") == "user" do
        normalize_message(string_value(turn, "text"))
      end
    end)
  end

  defp live_gmail_triage_request?(message) when is_binary(message) do
    normalized = String.downcase(message)

    contains_any?(normalized, ["email", "emails", "inbox", "gmail"]) and
      contains_any?(normalized, ["today", "latest", "new", "triage", "changed", "recent"])
  end

  defp live_gmail_latest_request?(message) when is_binary(message) do
    normalized = String.downcase(message)

    contains_any?(normalized, ["latest email", "newest email", "latest gmail", "latest inbox"]) or
      (contains_any?(normalized, ["latest", "newest", "most recent"]) and
         contains_any?(normalized, ["email", "gmail", "inbox"]))
  end

  defp build_live_gmail_query(:latest_visible, _message_text),
    do: "newer_than:#{@live_latest_lookback_days}d"

  defp build_live_gmail_query(:triage, _message_text),
    do: "in:inbox newer_than:#{@live_inbox_lookback_days}d -category:promotions -category:social"

  defp tool_call_response(summary, tool_name, arguments) do
    %{
      "status" => "tool_calls",
      "assistant_message" => "",
      "message_class" => "assistant_reply",
      "tool_calls" => [%{"tool" => tool_name, "arguments" => arguments}],
      "summary" => summary
    }
  end

  defp final_response(message, summary) do
    %{
      "status" => "final",
      "assistant_message" => message,
      "message_class" => "assistant_reply",
      "tool_calls" => [],
      "summary" => summary
    }
  end

  defp search_messages(search_result) do
    search_result
    |> map_value("messages", [])
    |> Enum.filter(&is_map/1)
  end

  defp sort_live_messages(messages) do
    Enum.sort_by(messages, &live_message_unix/1, :desc)
  end

  defp latest_visible_text(gmail_health, message) do
    checked_through = checked_through_text(gmail_health, [message])

    [
      "I can see live Gmail#{checked_through}.",
      "The latest visible email is #{live_message_label(message)}."
    ]
    |> Enum.join(" ")
  end

  defp latest_visible_no_results_text(gmail_health) do
    "I checked live Gmail#{checked_through_text(gmail_health, [])}, but I didn't find a recent visible message to report."
  end

  defp checked_through_text(gmail_health, messages) do
    freshest =
      string_value(gmail_health, "freshest_visible_email_at")
      |> parse_datetime()
      |> case do
        nil ->
          messages
          |> sort_live_messages()
          |> List.first()
          |> live_message_datetime()

        datetime ->
          datetime
      end

    case freshest do
      %DateTime{} = datetime -> " through #{format_datetime(datetime)}"
      _ -> ""
    end
  end

  defp live_message_label(message) do
    sender = sender_display_name(string_value(message, "from"))
    subject = present_or(string_value(message, "subject"), "(no subject)")
    account = string_value(message, "google_account_email")

    case account do
      value when is_binary(value) and value != "" ->
        "#{sender} [#{value}] — #{subject}"

      _ ->
        "#{sender} — #{subject}"
    end
  end

  defp live_message_unix(message) do
    case live_message_datetime(message) do
      %DateTime{} = datetime -> DateTime.to_unix(datetime, :second)
      _ -> 0
    end
  end

  defp live_message_datetime(message) do
    message
    |> map_value("internal_date")
    |> parse_datetime()
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(%{"year" => year, "month" => month, "day" => day} = value)
       when is_integer(year) and is_integer(month) and is_integer(day) do
    with {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <-
           Time.new(
             Map.get(value, "hour", 0),
             Map.get(value, "minute", 0),
             Map.get(value, "second", 0)
           ),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      datetime
    else
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp format_datetime(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp sender_display_name(from) when is_binary(from) do
    case Regex.run(~r/^"?([^"<]+?)"?\s*<[^>]+>$/, from) do
      [_, name] -> String.trim(name)
      _ -> String.trim(from)
    end
  end

  defp sender_display_name(_from), do: "Unknown sender"

  defp present_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp present_or(_value, fallback), do: fallback

  defp contains_any?(value, needles) when is_binary(value) and is_list(needles) do
    Enum.any?(needles, &String.contains?(value, &1))
  end

  defp tool_history(payload) do
    Map.get(payload, :tool_history) || Map.get(payload, "tool_history") || []
  end

  defp context(payload) do
    Map.get(payload, :context) || Map.get(payload, "context") || %{}
  end

  defp latest_tool_result(tool_history, tool_name) do
    tool_history
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      if string_value(entry, "tool") == tool_name do
        map_value(entry, "result")
      end
    end)
  end

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    atom_key = existing_atom_key(key)

    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(atom_key) and Map.has_key?(map, atom_key) ->
        Map.get(map, atom_key)

      true ->
        default
    end
  end

  defp map_value(_map, _key, default), do: default

  defp nested_value(map, [key]), do: map_value(map, key)
  defp nested_value(map, [key | rest]), do: map |> map_value(key, %{}) |> nested_value(rest)
  defp nested_value(_map, _keys), do: nil

  defp string_value(map, key) do
    case map_value(map, key) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(_key), do: nil
end
