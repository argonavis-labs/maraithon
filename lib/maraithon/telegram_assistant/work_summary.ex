defmodule Maraithon.TelegramAssistant.WorkSummary do
  @moduledoc """
  User-facing summaries of assistant runs and supporting actions.

  The persisted step payloads are audit data. This module turns them into a
  compact, non-raw shape that clients can show in chat without exposing noisy
  request bodies or full action results.
  """

  import Ecto.Query

  alias Maraithon.Redaction
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.{Run, Step}
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.Todos.UserFacingCopy

  @max_detail_chars 140
  @max_headline_chars 96
  @max_steps 24
  @max_tool_calls 12
  @max_context_chars 60

  @context_account_keys ~w(google_account_email account_email account mailbox source_account_label)
  @context_subject_keys ~w(query q search email_or_substring person name title subject channel_name channel)
  @internal_result_fragments [
    "argumenterror",
    "badmaperror",
    "dbconnection",
    "debug",
    "ecto.",
    "functionclauseerror",
    "genserver",
    "http_status",
    "httpoison",
    "internal_stacktrace",
    "llm",
    "model_reasoning_effort",
    "model_tier",
    "nsurlerrordomain",
    "oauth_tokens",
    "phoenix.",
    "postgrex",
    "prompt",
    "reasoning_effort",
    "req.",
    "route_reason",
    "stacktrace",
    "task_class",
    "tesla",
    "tool_call",
    "traceback",
    "transporterror"
  ]
  @internal_result_markers ["{", "}", "=>", "#PID<", "#Reference<", "** ("]

  def for_run(%Run{} = run) do
    steps = run_steps(run)
    tool_calls = tool_calls_from_steps(steps)

    %{
      "headline" => run_headline(run, steps, tool_calls),
      "status" => run.status,
      "tool_calls" => tool_calls,
      "steps" => Enum.map(Enum.take(steps, @max_steps), &step_summary/1)
    }
    |> drop_blank_values()
  end

  def for_run(_run), do: nil

  def for_message(%Turn{} = turn) do
    structured_data = turn.structured_data || %{}
    tool_history = map_value(structured_data, "tool_history", [])
    tool_calls = tool_calls_from_history(tool_history)

    if tool_calls == [] do
      nil
    else
      %{
        "headline" => completed_tool_headline(tool_calls),
        "status" => "completed",
        "summary" => safe_result_text(map_value(structured_data, "summary")),
        "tool_calls" => tool_calls
      }
      |> drop_blank_values()
    end
  end

  def for_message(_turn), do: nil

  defp run_steps(%Run{id: run_id, steps: steps}) when is_list(steps) do
    steps
    |> Enum.sort_by(& &1.sequence)
    |> Enum.take(-@max_steps)
    |> maybe_query_steps(run_id)
  end

  defp run_steps(%Run{id: run_id}) do
    query_steps(run_id)
  end

  defp maybe_query_steps([], run_id), do: query_steps(run_id)
  defp maybe_query_steps(steps, _run_id), do: steps

  defp query_steps(run_id) when is_binary(run_id) do
    # Keep the most recent steps so live progress reflects the tail of long runs.
    Step
    |> where([step], step.run_id == ^run_id)
    |> order_by([step], desc: step.sequence)
    |> limit(@max_steps)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp query_steps(_run_id), do: []

  defp tool_calls_from_steps(steps) when is_list(steps) do
    steps
    |> Enum.filter(&(&1.step_type == "tool_call"))
    |> Enum.take(@max_tool_calls)
    |> Enum.with_index(1)
    |> Enum.map(fn {step, index} ->
      tool = map_value(step.request_payload || %{}, "tool", "tool")

      %{
        "id" => step.id || "tool-#{index}",
        "tool" => public_tool_key(tool),
        "label" => tool_label(tool),
        "status" => step.status || "completed",
        "summary" => tool_step_summary(step),
        "detail" => tool_args_context(step.request_payload),
        "started_at" => json_time(step.started_at),
        "finished_at" => json_time(step.finished_at)
      }
      |> drop_blank_values()
    end)
  end

  defp tool_calls_from_steps(_steps), do: []

  defp tool_calls_from_history(tool_history) when is_list(tool_history) do
    tool_history
    |> Enum.take(@max_tool_calls)
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} ->
      tool = map_value(entry, "tool", "tool")
      error = map_value(entry, "error")
      status = if present?(error), do: "failed", else: "completed"

      %{
        "id" => "tool-#{index}",
        "tool" => public_tool_key(tool),
        "label" => tool_label(tool),
        "status" => status,
        "summary" => tool_history_summary(entry),
        "detail" => tool_args_context(entry)
      }
      |> drop_blank_values()
    end)
  end

  defp tool_calls_from_history(_tool_history), do: []

  defp step_summary(%Step{} = step) do
    %{
      "id" => step.id,
      "sequence" => step.sequence,
      "type" => public_step_type(step),
      "status" => step.status,
      "title" => step_title(step),
      "detail" => step_detail(step),
      "started_at" => json_time(step.started_at),
      "finished_at" => json_time(step.finished_at)
    }
    |> drop_blank_values()
  end

  defp step_title(%Step{step_type: "context_fetch"}), do: "Loaded context"
  defp step_title(%Step{step_type: "llm_request"}), do: "Choosing next action"

  defp step_title(%Step{step_type: "llm_response", response_payload: response}) do
    case map_value(response || %{}, "status") do
      "tool_calls" -> "Planned supporting checks"
      _ -> "Drafted reply"
    end
  end

  defp step_title(%Step{step_type: "tool_call", request_payload: request}) do
    request
    |> map_value("tool", "tool")
    |> tool_title()
  end

  defp step_title(%Step{step_type: step_type}) when is_binary(step_type), do: "Updated progress"

  defp step_title(_step), do: nil

  defp public_step_type(%Step{step_type: "context_fetch"}), do: "context"
  defp public_step_type(%Step{step_type: "llm_request"}), do: "answer_preparation"

  defp public_step_type(%Step{step_type: "llm_response", response_payload: response}) do
    case map_value(response || %{}, "status") do
      "tool_calls" -> "supporting_plan"
      _ -> "reply"
    end
  end

  defp public_step_type(%Step{step_type: "tool_call"}), do: "supporting_check"
  defp public_step_type(_step), do: "supporting_work"

  defp step_detail(%Step{step_type: "tool_call"} = step) do
    context = tool_args_context(step.request_payload)
    summary = tool_step_summary(step)

    case {context, summary} do
      {nil, summary} -> summary
      {context, nil} -> context
      {context, "Checking now."} -> context
      {context, summary} -> truncate("#{context} — #{summary}")
    end
  end

  defp step_detail(%Step{error: error}) when not is_nil(error) and error != "",
    do: "This step could not finish."

  defp step_detail(_step), do: nil

  defp tool_step_summary(%Step{status: "running"}), do: "Checking now."

  defp tool_step_summary(%Step{status: "failed"} = step) do
    step.request_payload
    |> map_value("tool", "tool")
    |> failed_tool_summary()
  end

  defp tool_step_summary(%Step{} = step) do
    case step.response_payload || %{} do
      %{} = response when map_size(response) > 0 -> result_summary(response)
      _ -> nil
    end
  end

  # Connected-account and request context for a tool call, extracted only from
  # whitelisted, user-meaningful argument keys (e.g. "kent@runner.now · “team summit”").
  defp tool_args_context(request) when is_map(request) do
    args =
      case map_value(request, "arguments", %{}) do
        %{} = arguments when map_size(arguments) > 0 -> arguments
        _ -> request
      end

    account = args |> first_arg_value(@context_account_keys) |> context_account()
    subject = args |> first_arg_value(@context_subject_keys) |> context_subject()

    case Enum.reject([account, subject], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp tool_args_context(_request), do: nil

  defp first_arg_value(args, keys) when is_map(args) do
    Enum.find_value(keys, fn key ->
      case map_value(args, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp first_arg_value(_args, _keys), do: nil

  defp context_account(value) when is_binary(value) do
    case Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i, value) do
      [email] -> String.downcase(email)
      _ -> value |> clean_item_text() |> limit_context()
    end
  end

  defp context_account(_value), do: nil

  defp context_subject(value) when is_binary(value) do
    case value |> clean_item_text() |> limit_context() do
      nil -> nil
      subject -> "“#{subject}”"
    end
  end

  defp context_subject(_value), do: nil

  defp limit_context(nil), do: nil

  defp limit_context(value) when is_binary(value) do
    if String.length(value) > @max_context_chars do
      String.slice(value, 0, @max_context_chars) <> "..."
    else
      value
    end
  end

  defp tool_history_summary(entry) when is_map(entry) do
    case map_value(entry, "error") do
      error when not is_nil(error) and error != "" ->
        entry
        |> map_value("tool", "tool")
        |> failed_tool_summary()

      _ ->
        entry
        |> map_value("result", %{})
        |> result_summary()
    end
  end

  defp tool_history_summary(_entry), do: nil

  defp result_summary(result) when is_map(result) do
    text_summary =
      first_present([
        safe_result_text(map_value(result, "message")),
        safe_result_text(map_value(result, "summary"))
      ])

    if present?(text_summary) do
      text_summary
    else
      cond do
        is_list(map_value(result, "todos")) ->
          list_summary(map_value(result, "todos"), "work item", &todo_item_summary/1)

        is_list(map_value(result, "people")) ->
          list_summary(map_value(result, "people"), "person", &person_item_summary/1, "people")

        is_list(map_value(result, "connected_accounts")) ->
          list_summary(
            map_value(result, "connected_accounts"),
            "connected account",
            &connected_account_item_summary/1
          )

        is_list(map_value(result, "providers")) ->
          list_summary(
            map_value(result, "providers"),
            "connected source",
            &provider_item_summary/1
          )

        is_list(map_value(result, "messages")) ->
          list_summary(map_value(result, "messages"), "message", &message_item_summary/1)

        is_list(map_value(result, "events")) ->
          list_summary(map_value(result, "events"), "event", &event_item_summary/1)

        is_list(map_value(result, "projects")) ->
          list_summary(map_value(result, "projects"), "project", &project_item_summary/1)

        is_list(map_value(result, "implementation_runs")) ->
          list_summary(
            map_value(result, "implementation_runs"),
            "project run",
            &implementation_run_item_summary/1
          )

        is_list(map_value(result, "agents")) ->
          list_summary(map_value(result, "agents"), "automation", &agent_item_summary/1)

        is_list(map_value(result, "tasks")) ->
          list_summary(
            map_value(result, "tasks"),
            "scheduled follow-up",
            &scheduled_task_item_summary/1
          )

        is_list(map_value(result, "memories")) ->
          list_summary(
            map_value(result, "memories"),
            "memory",
            &memory_item_summary/1,
            "memories"
          )

        is_list(map_value(result, "active_rules")) ->
          preference_rules_summary(result)

        is_list(map_value(result, "teams")) ->
          list_summary(map_value(result, "teams"), "Linear team", &linear_team_item_summary/1)

        is_integer(map_value(result, "count")) ->
          count = map_value(result, "count")
          result_count_summary(count)

        true ->
          completed_check_summary()
      end
    end
  end

  defp result_summary(_result), do: completed_check_summary()

  defp safe_result_text(value) when is_binary(value) do
    text =
      value
      |> scrub_sensitive_result_text()
      |> clean_result_text()

    cond do
      not present?(text) -> nil
      technical_result_text?(text) -> nil
      true -> truncate(text)
    end
  end

  defp safe_result_text(_value), do: nil

  defp scrub_sensitive_result_text(value) do
    value
    |> replace_result_regex(~r/\bAuthorization\s*:\s*(?:Bearer|Basic)?\s*[^\s,;)}\]]*/i, "")
    |> replace_result_regex(~r/\b(?:Bearer|Basic)\s+[^\s,;)}\]]+/i, "")
    |> replace_result_regex(
      ~r/\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|password)\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;)}\]]+)/i,
      ""
    )
    |> Redaction.redact_string()
    |> replace_result_regex(~r/<redacted[^>]*>/i, "")
    |> replace_result_regex(
      ~r/\b(?:authorization|bearer|api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|token|secret|password)\s*[:=]?\s*(?=$|[.;,])/i,
      ""
    )
  end

  defp clean_result_text(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> replace_result_regex(~r/\s+([,.;:])/, "\\1")
    |> replace_result_regex(~r/([,;:])\s*$/, "")
    |> String.trim()
    |> polish_legacy_product_terms()
  end

  defp replace_result_regex(value, pattern, replacement) when is_binary(value) do
    Regex.replace(pattern, value, replacement)
  end

  defp polish_legacy_product_terms(value) when is_binary(value) do
    value
    |> replace_result_regex(
      ~r/^No open (?:work|todos?) (?:found|matched this request)\.?$/i,
      "No saved open work matched this request."
    )
    |> replace_result_regex(~r/\bStart with\s+/, "Start here: ")
    |> replace_result_regex(~r/\bstart with\s+/, "start here: ")
    |> replace_result_regex(
      ~r/^No connected accounts found\.?$/i,
      "No connected accounts were available for this request."
    )
    |> replace_result_regex(
      ~r/^No connected sources found\.?$/i,
      "No connected sources were available for this request."
    )
    |> replace_result_regex(~r/\bCRM context\b/i, "relationship context")
    |> replace_result_regex(~r/\bCRM\b/i, "relationship data")
    |> replace_result_regex(~r/\b1 insight\b/i, "1 priority item")
    |> replace_result_regex(~r/\b([0-9]+) insights\b/i, "\\1 priority items")
    |> replace_result_regex(~r/\binsights\b/i, "priorities")
    |> replace_result_regex(~r/\binsight\b/i, "priority")
    |> replace_result_regex(~r/\btodos\b/i, "work items")
    |> replace_result_regex(~r/\btodo\b/i, "work item")
  end

  defp technical_result_text?(value) when is_binary(value) do
    lower = String.downcase(value)

    String.contains?(lower, @internal_result_fragments) or
      String.contains?(value, @internal_result_markers) or
      Regex.match?(~r/\bmodel(?:_name|_tier|_reasoning_effort)?\s*[:=]/i, value)
  end

  defp technical_result_text?(_value), do: false

  defp failed_tool_summary(tool) do
    case tool_label(tool) do
      "Supporting work" -> "Supporting check could not finish."
      "Work update" -> "Work update could not finish."
      "Scheduled task" -> "Scheduled task could not finish."
      "Draft" -> "Draft could not finish."
      "Memory update" -> "Memory update could not finish."
      "Memory" -> "Memory update could not finish."
      "Preference update" -> "Preference update could not finish."
      "Preferences" -> "Preference check could not finish."
      "Preference" -> "Preference update could not finish."
      "Feedback" -> "Feedback update could not finish."
      label -> "#{label} check could not finish."
    end
  end

  defp count_summary(items, singular, plural) when is_list(items) do
    count = length(items)

    case {singular, count} do
      {"work item", 0} ->
        "No saved open work matched this request."

      {"work item", count} ->
        "Found #{format_count(count)} open work #{pluralize("item", count)}."

      {"connected account", 0} ->
        "No connected accounts were available for this request."

      {"connected source", 0} ->
        "No connected sources were available for this request."

      {_singular, 0} ->
        empty_list_summary(singular, plural)

      {_singular, count} ->
        "Found #{format_count(count)} #{pluralize(singular, count, plural)}."
    end
  end

  defp result_count_summary(0), do: "This check did not return any results."

  defp result_count_summary(count),
    do: "Found #{format_count(count)} #{pluralize("result", count)}."

  defp completed_check_summary, do: "Completed the check."

  defp empty_list_summary("event", _plural),
    do: "This check did not return any calendar events."

  defp empty_list_summary(singular, plural),
    do: "This check did not return any #{pluralize(singular, 2, plural)}."

  defp list_summary(items, singular, item_summary, plural \\ nil) when is_list(items) do
    count = length(items)

    labels =
      items
      |> Enum.map(item_summary)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.take(2)

    case labels do
      [] ->
        count_summary(items, singular, plural)

      labels ->
        noun = pluralize(singular, count, plural)
        suffix = if count > length(labels), do: "; and #{count - length(labels)} more", else: ""
        truncate("#{count} #{noun}: #{Enum.join(labels, "; ")}#{suffix}")
    end
  end

  defp todo_item_summary(todo) when is_map(todo) do
    title = clean_item_text(map_value(todo, "title"))
    next_action = clean_item_text(map_value(todo, "next_action"))
    summary = clean_item_text(map_value(todo, "summary"))

    cond do
      present?(title) and present?(next_action) and not same_text?(title, next_action) ->
        "#{title} - #{next_action}"

      present?(next_action) ->
        next_action

      present?(title) ->
        title

      true ->
        summary
    end
  end

  defp todo_item_summary(_todo), do: nil

  defp person_item_summary(person) when is_map(person) do
    first_present([
      clean_item_text(map_value(person, "display_name")),
      clean_item_text(map_value(person, "name")),
      clean_item_text(map_value(person, "email"))
    ])
  end

  defp person_item_summary(_person), do: nil

  defp connected_account_item_summary(account) when is_map(account) do
    label =
      first_present([
        clean_item_text(map_value(account, "account_label")),
        clean_item_text(map_value(account, "label")),
        clean_item_text(map_value(account, "email")),
        clean_item_text(map_value(account, "provider"))
      ])

    status = clean_item_text(map_value(account, "status"))
    append_status(label, status)
  end

  defp connected_account_item_summary(_account), do: nil

  defp provider_item_summary(provider) when is_map(provider) do
    label =
      first_present([
        clean_item_text(map_value(provider, "label")),
        clean_item_text(map_value(provider, "display_name")),
        clean_item_text(map_value(provider, "provider"))
      ])

    status = clean_item_text(map_value(provider, "status"))
    append_status(label, status)
  end

  defp provider_item_summary(_provider), do: nil

  defp message_item_summary(message) when is_map(message) do
    subject =
      first_present([
        clean_item_text(map_value(message, "subject")),
        clean_item_text(map_value(message, "title")),
        clean_item_text(map_value(message, "summary")),
        clean_item_text(map_value(message, "snippet"))
      ])

    sender =
      first_present([
        clean_item_text(map_value(message, "from")),
        clean_item_text(map_value(message, "sender")),
        clean_item_text(map_value(message, "sender_name"))
      ])

    cond do
      present?(sender) and present?(subject) -> "#{sender}: #{subject}"
      present?(subject) -> subject
      true -> sender
    end
  end

  defp message_item_summary(_message), do: nil

  defp event_item_summary(event) when is_map(event) do
    title =
      first_present([
        clean_item_text(map_value(event, "title")),
        clean_item_text(map_value(event, "summary")),
        clean_item_text(map_value(event, "name"))
      ])

    time =
      first_present([
        clean_item_text(map_value(event, "display_time")),
        clean_item_text(map_value(event, "starts_at")),
        clean_item_text(map_value(event, "start"))
      ])

    cond do
      present?(title) and present?(time) -> "#{title} at #{time}"
      present?(title) -> title
      true -> time
    end
  end

  defp event_item_summary(_event), do: nil

  defp project_item_summary(project) when is_map(project) do
    name =
      first_present([
        clean_item_text(map_value(project, "name")),
        clean_item_text(map_value(project, "title")),
        clean_item_text(map_value(project, "summary"))
      ])

    status = clean_item_text(map_value(project, "status"))
    append_status(name, status)
  end

  defp project_item_summary(_project), do: nil

  defp implementation_run_item_summary(run) when is_map(run) do
    label =
      first_present([
        clean_item_text(map_value(run, "result_summary")),
        clean_item_text(map_value(run, "repo_full_name")),
        clean_item_text(map_value(run, "branch_name")),
        clean_item_text(map_value(run, "id"))
      ])

    status = clean_item_text(map_value(run, "status"))
    append_status(label, status)
  end

  defp implementation_run_item_summary(_run), do: nil

  defp agent_item_summary(agent) when is_map(agent) do
    label =
      first_present([
        clean_item_text(map_value(agent, "name")),
        clean_item_text(map_value(agent, "behavior")),
        clean_item_text(map_value(agent, "id"))
      ])

    project = clean_item_text(map_value(agent, "project_name"))
    status = clean_item_text(map_value(agent, "status"))

    label
    |> append_status(status)
    |> append_context(project)
  end

  defp agent_item_summary(_agent), do: nil

  defp scheduled_task_item_summary(task) when is_map(task) do
    title =
      first_present([
        clean_item_text(map_value(task, "title")),
        clean_item_text(map_value(task, "description")),
        clean_item_text(map_value(task, "name"))
      ])

    status = clean_item_text(map_value(task, "status"))
    append_status(title, status)
  end

  defp scheduled_task_item_summary(_task), do: nil

  defp memory_item_summary(memory) when is_map(memory) do
    first_present([
      clean_item_text(map_value(memory, "title")),
      clean_item_text(map_value(memory, "summary")),
      clean_item_text(map_value(memory, "content"))
    ])
  end

  defp memory_item_summary(_memory), do: nil

  defp preference_rule_item_summary(rule) when is_map(rule) do
    first_present([
      clean_item_text(map_value(rule, "label")),
      clean_item_text(map_value(rule, "rule")),
      clean_item_text(map_value(rule, "text")),
      clean_item_text(map_value(rule, "summary"))
    ])
  end

  defp preference_rule_item_summary(_rule), do: nil

  defp preference_rules_summary(result) when is_map(result) do
    active = list_value(map_value(result, "active_rules", []))
    pending = list_value(map_value(result, "pending_rules", []))
    rules = active ++ pending

    cond do
      rules != [] ->
        list_summary(rules, "preference", &preference_rule_item_summary/1)

      map_value(result, "active_count", 0) == 0 and map_value(result, "pending_count", 0) == 0 ->
        "Using confirmed context until you save a standing preference."

      true ->
        completed_check_summary()
    end
  end

  defp linear_team_item_summary(team) when is_map(team) do
    first_present([
      clean_item_text(map_value(team, "name")),
      clean_item_text(map_value(team, "key")),
      clean_item_text(map_value(team, "id"))
    ])
  end

  defp linear_team_item_summary(_team), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp clean_item_text(value) when is_binary(value) do
    value
    |> UserFacingCopy.polish_text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      text -> if technical_result_text?(text), do: nil, else: text
    end
  end

  defp clean_item_text(_value), do: nil

  defp append_status(nil, _status), do: nil
  defp append_status(label, status) when status in [nil, "", "connected", "completed"], do: label
  defp append_status(label, status), do: "#{label} (#{status_label(status)})"

  defp status_label("needs_refresh"), do: "reconnect needed"
  defp status_label("missing_scope"), do: "needs permission"
  defp status_label("not_configured"), do: "not ready"
  defp status_label("setup_required"), do: "not ready"
  defp status_label("partially_configured"), do: "partially ready"
  defp status_label("in_progress"), do: "in progress"
  defp status_label("awaiting_confirmation"), do: "awaiting approval"
  defp status_label(status) when is_binary(status), do: humanize_status(status)
  defp status_label(status), do: status |> to_string() |> humanize_status()

  defp humanize_status(status) when is_binary(status) do
    status
    |> String.replace(~r/[_-]+/, " ")
    |> String.trim()
  end

  defp append_context(nil, _context), do: nil
  defp append_context(label, context) when context in [nil, ""], do: label
  defp append_context(label, context), do: "#{label} - #{context}"

  defp first_present(values) do
    Enum.find(values, &present?/1)
  end

  defp same_text?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(left) == String.downcase(right)
  end

  defp same_text?(_left, _right), do: false

  defp run_headline(%Run{status: "queued"}, _steps, _tool_calls), do: "Waiting to start"

  defp run_headline(%Run{result_summary: %{} = result_summary}, _steps, _tool_calls)
       when is_map_key(result_summary, "escalated_to_reasoning") or
              is_map_key(result_summary, :escalated_to_reasoning) do
    "Switched to deeper analysis"
  end

  defp run_headline(%Run{status: "running"}, steps, _tool_calls) do
    case List.last(steps) do
      %Step{step_type: "context_fetch"} ->
        "Reading context"

      %Step{step_type: "llm_request"} ->
        "Choosing the next action"

      %Step{step_type: "llm_response"} ->
        "Checking the plan"

      %Step{step_type: "tool_call", request_payload: request} ->
        headline = tool_running_headline(map_value(request || %{}, "tool", "tool"))

        case tool_args_context(request) do
          nil -> headline
          context -> truncate_headline("#{headline} · #{context}")
        end

      _ ->
        "Maraithon is working"
    end
  end

  defp run_headline(_run, _steps, []), do: "Answered directly"
  defp run_headline(_run, _steps, tool_calls), do: completed_tool_headline(tool_calls)

  defp completed_tool_headline(tool_calls) when is_list(tool_calls) do
    completed = Enum.reject(tool_calls, &(map_value(&1, "status") == "failed"))
    failed_count = length(tool_calls) - length(completed)
    featured_headline = featured_headline(completed, failed_count)

    phrases =
      completed
      |> Enum.map(&tool_outcome_phrase/1)
      |> Enum.uniq()

    phrase = phrase_list(phrases)

    cond do
      present?(featured_headline) ->
        featured_headline

      phrases != [] && failed_count == 0 ->
        phrases
        |> completed_reply_phrase()
        |> capitalize_sentence()

      phrase ->
        "#{capitalize_sentence(phrase)}; #{failed_count} #{pluralize("check", failed_count)} had an issue"

      failed_count > 0 ->
        "Could not complete the requested check"

      true ->
        "Finished the request"
    end
  end

  defp featured_headline([tool_call], 0) do
    label = tool_call |> map_value("label") |> clean_item_text()
    summary = tool_call |> map_value("summary") |> clean_item_text()
    subject = featured_summary_subject(summary)

    if present?(label) and present?(subject) do
      truncate_headline("#{label}: #{subject}")
    end
  end

  defp featured_headline(_completed, _failed_count), do: nil

  defp featured_summary_subject(summary) when is_binary(summary) do
    [
      open_work_start_subject(summary),
      listed_summary_subject(summary),
      specific_result_subject(summary)
    ]
    |> first_present()
    |> clean_featured_subject()
  end

  defp featured_summary_subject(_summary), do: nil

  defp open_work_start_subject(summary) do
    case Regex.run(~r/^Open work:\s+.+?\.\s+Start\s+(?:with\s+|here:\s*)(.+?)(?:\.|$)/iu, summary) do
      [_match, subject] -> subject
      _other -> nil
    end
  end

  defp listed_summary_subject(summary) do
    case Regex.run(~r/^\d+\s+[^:]+:\s+(.+)$/u, summary) do
      [_match, items] ->
        items
        |> String.split(";")
        |> List.first()
        |> clean_item_text()

      _other ->
        nil
    end
  end

  defp specific_result_subject(summary) do
    if generic_result_summary?(summary), do: nil, else: summary
  end

  defp generic_result_summary?(summary) when is_binary(summary) do
    Regex.match?(
      ~r/^(?:No |Found \d+\b|Completed the check\.?$|Checking now\.?$|This check (?:did not return|returned|surfaced)\b|This check could not finish\.?$|.* could not finish\.?$)/i,
      summary
    )
  end

  defp generic_result_summary?(_summary), do: true

  defp clean_featured_subject(subject) when is_binary(subject) do
    subject
    |> String.split(" - ")
    |> List.first()
    |> clean_item_text()
    |> remove_trailing_sentence()
  end

  defp clean_featured_subject(_subject), do: nil

  defp remove_trailing_sentence(nil), do: nil

  defp remove_trailing_sentence(subject) when is_binary(subject) do
    subject
    |> String.trim()
    |> String.trim_trailing(".")
  end

  @public_tool_labels %{
    "connected_accounts" => "Connected accounts",
    "open_work" => "Open work",
    "open_work_review" => "Open work",
    "open_loops" => "Follow-through",
    "linked_item" => "Selected item",
    "action_history" => "Action history",
    "briefing_schedule" => "Briefing schedule",
    "scheduled_followups" => "Scheduled follow-ups",
    "scheduled_task" => "Scheduled task",
    "preferences" => "Preferences",
    "preference_update" => "Preference update",
    "preference" => "Preference",
    "work_update" => "Work update",
    "people" => "People",
    "people_update" => "People update",
    "relationship_context" => "Relationship context",
    "connected_sources" => "Connected sources",
    "relationship_learning" => "Relationship notes",
    "calendar" => "Calendar",
    "gmail" => "Gmail",
    "slack" => "Slack",
    "draft" => "Draft",
    "memory_check" => "Memory",
    "memory_update" => "Memory update",
    "memory" => "Memory",
    "feedback" => "Feedback",
    "linear" => "Linear",
    "notaui" => "Notaui tasks",
    "projects" => "Projects",
    "project_update" => "Project update",
    "project_run" => "Project run",
    "automations" => "Automations",
    "automation_update" => "Automation update",
    "prepared_action" => "Prepared action",
    "automation_query" => "Automation answer",
    "notes" => "Notes",
    "voice_memos" => "Voice Memos",
    "files" => "Files",
    "messages" => "Messages",
    "reminders" => "Reminders",
    "browser_history" => "Browser history",
    "local_context" => "Local sources",
    "supporting_work" => "Supporting work"
  }
  @public_tool_keys Map.keys(@public_tool_labels)

  defp tool_label(tool) when is_binary(tool) do
    case tool_display_label(tool) do
      nil -> public_tool_display_label(public_tool_key(tool)) || "Supporting work"
      label -> label
    end
  end

  defp tool_label(_tool), do: "Supporting work"

  defp public_tool_display_label(tool), do: Map.get(@public_tool_labels, tool)

  defp public_tool_key(tool) when tool in @public_tool_keys, do: tool

  defp public_tool_key(tool) do
    case tool do
      "list_connected_accounts" -> "connected_accounts"
      "list_todos" -> "open_work"
      "get_open_work_summary" -> "open_work_review"
      "get_open_loops" -> "open_loops"
      "inspect_open_insight" -> "linked_item"
      "explain_action_ledger" -> "action_history"
      "update_briefing_schedule" -> "briefing_schedule"
      "list_scheduled_tasks" -> "scheduled_followups"
      "pause_scheduled_task" -> "scheduled_task"
      "cancel_scheduled_task" -> "scheduled_task"
      "list_preferences" -> "preferences"
      "upsert_todos" -> "work_update"
      "update_todo" -> "work_update"
      "resolve_todo" -> "work_update"
      "delete_todo" -> "work_update"
      "todo_update" -> "work_update"
      "work_update" -> "work_update"
      "list_people" -> "people"
      "get_person" -> "people"
      "upsert_person" -> "people_update"
      "link_person_data" -> "people_update"
      "merge_people" -> "people_update"
      "delete_person" -> "people_update"
      "get_relationship_context" -> "relationship_context"
      "crm_context" -> "relationship_context"
      "relationship_context" -> "relationship_context"
      "review_connected_context" -> "connected_sources"
      "learn_relationship_context" -> "relationship_learning"
      "calendar_list_events" -> "calendar"
      "calendar_events_for_person" -> "calendar"
      "calendar_events_around" -> "calendar"
      "calendar_search" -> "calendar"
      "calendar_event_get" -> "calendar"
      "gmail_search_messages" -> "gmail"
      "gmail_get_message" -> "gmail"
      "gmail_drafts" -> "gmail"
      "slack_search_messages" -> "slack"
      "slack_get_thread" -> "slack"
      "slack_get_thread_context" -> "slack"
      "draft_message" -> "draft"
      "create_scheduled_task" -> "scheduled_task"
      "list_memories" -> "memory_check"
      "recall_memory" -> "memory_check"
      "write_memory" -> "memory_update"
      "remember_preferences" -> "preference_update"
      "record_memory_feedback" -> "feedback"
      "update_memory_confidence" -> "memory_update"
      "forget_memory" -> "memory_update"
      "forget_preference" -> "preference_update"
      "linear_list_or_lookup" -> "linear"
      "notaui_list_tasks" -> "notaui"
      "list_projects" -> "projects"
      "inspect_project" -> "projects"
      "update_project_scope" -> "project_update"
      "decide_project_recommendation" -> "project_update"
      "grant_project_repo_access" -> "project_update"
      "prepare_project_action" -> "project_update"
      "start_implementation_run" -> "project_run"
      "list_implementation_runs" -> "project_run"
      "update_implementation_run" -> "project_run"
      "list_agents" -> "automations"
      "inspect_agent" -> "automations"
      "prepare_agent_action" -> "automation_update"
      "prepare_external_action" -> "prepared_action"
      "query_agent" -> "automation_query"
      "notes_search" -> "notes"
      "notes_get" -> "notes"
      "notes_list_recent" -> "notes"
      "voice_memos_search" -> "voice_memos"
      "voice_memos_get" -> "voice_memos"
      "voice_memos_list_recent" -> "voice_memos"
      "files_search" -> "files"
      "files_get" -> "files"
      "files_list_recent" -> "files"
      "messages_search" -> "messages"
      "messages_get" -> "messages"
      "messages_list_recent" -> "messages"
      "messages_chats_recent" -> "messages"
      "reminders_open" -> "reminders"
      "reminders_due_soon" -> "reminders"
      "reminders_search" -> "reminders"
      "reminders_get" -> "reminders"
      "browser_history_recent" -> "browser_history"
      "browser_history_by_host" -> "browser_history"
      "browser_history_search" -> "browser_history"
      "browser_history_get" -> "browser_history"
      "recall_anywhere" -> "local_context"
      _other -> "supporting_work"
    end
  end

  defp tool_display_label(tool) do
    case tool do
      "list_connected_accounts" -> "Connected accounts"
      "list_todos" -> "Open work"
      "get_open_work_summary" -> "Open work"
      "get_open_loops" -> "Follow-through"
      "inspect_open_insight" -> "Selected item"
      "explain_action_ledger" -> "Action history"
      "update_briefing_schedule" -> "Briefing schedule"
      "list_scheduled_tasks" -> "Scheduled follow-ups"
      "pause_scheduled_task" -> "Scheduled task"
      "cancel_scheduled_task" -> "Scheduled task"
      "list_preferences" -> "Preferences"
      "upsert_todos" -> "Work update"
      "update_todo" -> "Work update"
      "resolve_todo" -> "Work update"
      "delete_todo" -> "Work update"
      "todo_update" -> "Work update"
      "work_update" -> "Work update"
      "list_people" -> "People"
      "get_person" -> "People"
      "upsert_person" -> "People update"
      "link_person_data" -> "People update"
      "merge_people" -> "People update"
      "delete_person" -> "People update"
      "get_relationship_context" -> "Relationship context"
      "crm_context" -> "Relationship context"
      "relationship_context" -> "Relationship context"
      "review_connected_context" -> "Connected sources"
      "learn_relationship_context" -> "Relationship notes"
      "calendar_list_events" -> "Calendar"
      "calendar_events_for_person" -> "Calendar"
      "calendar_events_around" -> "Calendar"
      "calendar_search" -> "Calendar"
      "calendar_event_get" -> "Calendar"
      "gmail_search_messages" -> "Gmail"
      "gmail_get_message" -> "Gmail"
      "gmail_drafts" -> "Gmail"
      "slack_search_messages" -> "Slack"
      "slack_get_thread" -> "Slack"
      "slack_get_thread_context" -> "Slack"
      "draft_message" -> "Draft"
      "create_scheduled_task" -> "Scheduled task"
      "list_memories" -> "Memory"
      "recall_memory" -> "Memory"
      "write_memory" -> "Memory update"
      "remember_preferences" -> "Preference update"
      "record_memory_feedback" -> "Feedback"
      "update_memory_confidence" -> "Memory update"
      "forget_memory" -> "Memory update"
      "forget_preference" -> "Preference update"
      "linear_list_or_lookup" -> "Linear"
      "notaui_list_tasks" -> "Notaui tasks"
      "list_projects" -> "Projects"
      "inspect_project" -> "Projects"
      "update_project_scope" -> "Project update"
      "decide_project_recommendation" -> "Project update"
      "grant_project_repo_access" -> "Project update"
      "prepare_project_action" -> "Project update"
      "start_implementation_run" -> "Project run"
      "list_implementation_runs" -> "Project runs"
      "update_implementation_run" -> "Project run"
      "list_agents" -> "Automations"
      "inspect_agent" -> "Automations"
      "prepare_agent_action" -> "Automation update"
      "prepare_external_action" -> "Prepared action"
      "query_agent" -> "Automation answer"
      "notes_search" -> "Notes"
      "notes_get" -> "Notes"
      "notes_list_recent" -> "Notes"
      "voice_memos_search" -> "Voice Memos"
      "voice_memos_get" -> "Voice Memos"
      "voice_memos_list_recent" -> "Voice Memos"
      "files_search" -> "Files"
      "files_get" -> "Files"
      "files_list_recent" -> "Files"
      "messages_search" -> "Messages"
      "messages_get" -> "Messages"
      "messages_list_recent" -> "Messages"
      "messages_chats_recent" -> "Messages"
      "reminders_open" -> "Reminders"
      "reminders_due_soon" -> "Reminders"
      "reminders_search" -> "Reminders"
      "reminders_get" -> "Reminders"
      "browser_history_recent" -> "Browser history"
      "browser_history_by_host" -> "Browser history"
      "browser_history_search" -> "Browser history"
      "browser_history_get" -> "Browser history"
      "recall_anywhere" -> "Local sources"
      _other -> nil
    end
  end

  defp tool_outcome_phrase(tool_call) do
    case map_value(tool_call, "tool") do
      "list_connected_accounts" -> "reviewed connected accounts"
      "connected_accounts" -> "reviewed connected accounts"
      "list_todos" -> "reviewed open work"
      "open_work" -> "reviewed open work"
      "get_open_work_summary" -> "reviewed open work"
      "open_work_review" -> "reviewed open work"
      "get_open_loops" -> "reviewed follow-through"
      "open_loops" -> "reviewed follow-through"
      "inspect_open_insight" -> "reviewed the selected item"
      "linked_item" -> "reviewed the selected item"
      "explain_action_ledger" -> "reviewed action history"
      "action_history" -> "reviewed action history"
      "update_briefing_schedule" -> "updated the briefing schedule"
      "briefing_schedule" -> "updated the briefing schedule"
      "list_scheduled_tasks" -> "reviewed scheduled follow-ups"
      "scheduled_followups" -> "reviewed scheduled follow-ups"
      "pause_scheduled_task" -> "updated scheduled follow-ups"
      "cancel_scheduled_task" -> "updated scheduled follow-ups"
      "upsert_todos" -> "updated open work"
      "update_todo" -> "updated open work"
      "resolve_todo" -> "updated open work"
      "delete_todo" -> "updated open work"
      "todo_update" -> "updated open work"
      "work_update" -> "updated open work"
      "list_people" -> "reviewed people"
      "get_person" -> "reviewed people"
      "people" -> "reviewed people"
      "upsert_person" -> "updated people"
      "link_person_data" -> "updated people"
      "merge_people" -> "updated people"
      "delete_person" -> "updated people"
      "people_update" -> "updated people"
      "get_relationship_context" -> "reviewed relationship context"
      "crm_context" -> "reviewed relationship context"
      "relationship_context" -> "reviewed relationship context"
      "review_connected_context" -> "reviewed connected sources"
      "connected_sources" -> "reviewed connected sources"
      "learn_relationship_context" -> "updated relationship notes"
      "relationship_learning" -> "updated relationship notes"
      "calendar_list_events" -> "reviewed calendar"
      "calendar_events_for_person" -> "reviewed calendar"
      "calendar_events_around" -> "reviewed calendar"
      "calendar_search" -> "reviewed calendar"
      "calendar_event_get" -> "reviewed calendar"
      "calendar" -> "reviewed calendar"
      "gmail_search_messages" -> "reviewed Gmail"
      "gmail_get_message" -> "reviewed Gmail"
      "gmail_drafts" -> "reviewed Gmail"
      "gmail" -> "reviewed Gmail"
      "slack_search_messages" -> "reviewed Slack"
      "slack_get_thread" -> "reviewed Slack"
      "slack_get_thread_context" -> "reviewed Slack"
      "slack" -> "reviewed Slack"
      "draft_message" -> "prepared a draft"
      "draft" -> "prepared a draft"
      "create_scheduled_task" -> "scheduled follow-up work"
      "scheduled_task" -> "scheduled follow-up work"
      "list_memories" -> "reviewed memory"
      "recall_memory" -> "reviewed memory"
      "write_memory" -> "updated memory"
      "memory_check" -> "reviewed memory"
      "memory_update" -> "updated memory"
      "memory" -> "updated memory"
      "list_preferences" -> "reviewed preferences"
      "preferences" -> "reviewed preferences"
      "remember_preferences" -> "updated preferences"
      "preference_update" -> "updated preferences"
      "preference" -> "updated a preference"
      "record_memory_feedback" -> "recorded feedback"
      "feedback" -> "recorded feedback"
      "update_memory_confidence" -> "updated memory"
      "forget_memory" -> "updated memory"
      "forget_preference" -> "updated preferences"
      "linear_list_or_lookup" -> "reviewed Linear"
      "linear" -> "reviewed Linear"
      "notaui_list_tasks" -> "reviewed Notaui tasks"
      "notaui" -> "reviewed Notaui tasks"
      "list_projects" -> "reviewed projects"
      "inspect_project" -> "reviewed projects"
      "projects" -> "reviewed projects"
      "update_project_scope" -> "updated a project"
      "decide_project_recommendation" -> "updated a project"
      "grant_project_repo_access" -> "updated a project"
      "prepare_project_action" -> "prepared a project update"
      "project_update" -> "updated a project"
      "start_implementation_run" -> "started a project run"
      "list_implementation_runs" -> "reviewed project runs"
      "update_implementation_run" -> "updated a project run"
      "project_run" -> project_run_outcome_phrase(tool_call)
      "list_agents" -> "reviewed automations"
      "inspect_agent" -> "reviewed automations"
      "automations" -> "reviewed automations"
      "prepare_agent_action" -> "prepared an automation update"
      "automation_update" -> "prepared an automation update"
      "prepare_external_action" -> "prepared an external action"
      "prepared_action" -> "prepared an external action"
      "query_agent" -> "reviewed an automation"
      "automation_query" -> "reviewed an automation"
      "notes_search" -> "reviewed notes"
      "notes_get" -> "reviewed notes"
      "notes_list_recent" -> "reviewed notes"
      "notes" -> "reviewed notes"
      "voice_memos_search" -> "reviewed Voice Memos"
      "voice_memos_get" -> "reviewed Voice Memos"
      "voice_memos_list_recent" -> "reviewed Voice Memos"
      "voice_memos" -> "reviewed Voice Memos"
      "files_search" -> "reviewed files"
      "files_get" -> "reviewed files"
      "files_list_recent" -> "reviewed files"
      "files" -> "reviewed files"
      "messages_search" -> "reviewed Messages"
      "messages_get" -> "reviewed Messages"
      "messages_list_recent" -> "reviewed Messages"
      "messages_chats_recent" -> "reviewed Messages"
      "messages" -> "reviewed Messages"
      "reminders_open" -> "reviewed Reminders"
      "reminders_due_soon" -> "reviewed Reminders"
      "reminders_search" -> "reviewed Reminders"
      "reminders_get" -> "reviewed Reminders"
      "reminders" -> "reviewed Reminders"
      "browser_history_recent" -> "reviewed browser history"
      "browser_history_by_host" -> "reviewed browser history"
      "browser_history_search" -> "reviewed browser history"
      "browser_history_get" -> "reviewed browser history"
      "browser_history" -> "reviewed browser history"
      "recall_anywhere" -> "reviewed local sources"
      "local_context" -> "reviewed local sources"
      _other -> "completed supporting work"
    end
  end

  defp project_run_outcome_phrase(tool_call) do
    case map_value(tool_call, "label") do
      "Project runs" -> "reviewed project runs"
      _other -> "updated a project run"
    end
  end

  defp phrase_list([]), do: nil
  defp phrase_list([one]), do: one
  defp phrase_list([first, second]), do: "#{first} and #{second}"

  defp phrase_list([first, second, third | rest]) do
    if rest == [] do
      "#{first}, #{second}, and #{third}"
    else
      "#{first}, #{second}, and #{length(rest) + 1} more checks"
    end
  end

  defp completed_reply_phrase(phrases) when is_list(phrases) do
    if phrases != [] and Enum.all?(phrases, &reviewed_phrase?/1) do
      reviewed_reply_phrase(phrases)
    else
      completed_action_reply_phrase(phrases)
    end
  end

  defp completed_action_reply_phrase([one]), do: "#{one} and replied"
  defp completed_action_reply_phrase([first, second]), do: "#{first}, #{second}, and replied"

  defp completed_action_reply_phrase([first, second, third]) do
    "#{first}, #{second}, #{third}, and replied"
  end

  defp completed_action_reply_phrase([first, second, third | rest]) do
    "#{first}, #{second}, #{third}, and #{length(rest)} more #{pluralize("step", length(rest))} before replying"
  end

  defp completed_action_reply_phrase([]), do: "finished the request"

  defp reviewed_phrase?(phrase) when is_binary(phrase),
    do: String.starts_with?(phrase, "reviewed ")

  defp reviewed_phrase?(_phrase), do: false

  defp reviewed_reply_phrase(phrases) do
    subjects = Enum.map(phrases, &String.replace_prefix(&1, "reviewed ", ""))
    "reviewed #{reviewed_subject_list(subjects)} before replying"
  end

  defp reviewed_subject_list([one]), do: one
  defp reviewed_subject_list([first, second]), do: "#{first} and #{second}"

  defp reviewed_subject_list([first, second, third]) do
    "#{first}, #{second}, and #{third}"
  end

  defp reviewed_subject_list([first, second, third | rest]) do
    "#{first}, #{second}, #{third}, and #{length(rest)} more #{pluralize("area", length(rest))}"
  end

  defp capitalize_sentence(phrase) when is_binary(phrase) do
    first = String.slice(phrase, 0, 1)
    rest = String.slice(phrase, 1, String.length(phrase))
    String.upcase(first) <> rest
  end

  defp tool_running_headline(tool) do
    case tool do
      "list_connected_accounts" -> "Reviewing connected accounts"
      "list_todos" -> "Reviewing open work"
      "get_open_work_summary" -> "Reviewing open work"
      "get_open_loops" -> "Reviewing follow-through"
      "inspect_open_insight" -> "Reviewing the selected item"
      "explain_action_ledger" -> "Reviewing action history"
      "update_briefing_schedule" -> "Updating the briefing schedule"
      "list_scheduled_tasks" -> "Reviewing scheduled follow-ups"
      "pause_scheduled_task" -> "Updating scheduled follow-ups"
      "cancel_scheduled_task" -> "Updating scheduled follow-ups"
      "list_preferences" -> "Reviewing preferences"
      "upsert_todos" -> "Updating open work"
      "update_todo" -> "Updating open work"
      "resolve_todo" -> "Updating open work"
      "delete_todo" -> "Updating open work"
      "todo_update" -> "Updating open work"
      "work_update" -> "Updating open work"
      "list_people" -> "Reviewing people"
      "get_person" -> "Reviewing people"
      "upsert_person" -> "Updating people"
      "link_person_data" -> "Updating people"
      "merge_people" -> "Updating people"
      "delete_person" -> "Updating people"
      "get_relationship_context" -> "Reviewing relationship context"
      "crm_context" -> "Reviewing relationship context"
      "relationship_context" -> "Reviewing relationship context"
      "review_connected_context" -> "Reviewing connected sources"
      "learn_relationship_context" -> "Updating relationship notes"
      "calendar_list_events" -> "Reviewing calendar"
      "calendar_events_for_person" -> "Reviewing calendar"
      "calendar_events_around" -> "Reviewing calendar"
      "calendar_search" -> "Reviewing calendar"
      "calendar_event_get" -> "Reviewing calendar"
      "gmail_search_messages" -> "Reviewing Gmail"
      "gmail_get_message" -> "Reviewing Gmail"
      "gmail_drafts" -> "Reviewing Gmail"
      "slack_search_messages" -> "Reviewing Slack"
      "slack_get_thread" -> "Reviewing Slack"
      "slack_get_thread_context" -> "Reviewing Slack"
      "draft_message" -> "Preparing a draft"
      "create_scheduled_task" -> "Scheduling follow-up work"
      "list_memories" -> "Reviewing memory"
      "recall_memory" -> "Reviewing memory"
      "write_memory" -> "Updating memory"
      "remember_preferences" -> "Updating preferences"
      "record_memory_feedback" -> "Recording feedback"
      "update_memory_confidence" -> "Updating memory"
      "forget_memory" -> "Updating memory"
      "forget_preference" -> "Updating preferences"
      "linear_list_or_lookup" -> "Reviewing Linear"
      "notaui_list_tasks" -> "Reviewing Notaui tasks"
      "list_projects" -> "Reviewing projects"
      "inspect_project" -> "Reviewing projects"
      "update_project_scope" -> "Updating a project"
      "decide_project_recommendation" -> "Updating a project"
      "grant_project_repo_access" -> "Updating a project"
      "prepare_project_action" -> "Preparing a project update"
      "start_implementation_run" -> "Starting a project run"
      "list_implementation_runs" -> "Reviewing project runs"
      "update_implementation_run" -> "Updating a project run"
      "list_agents" -> "Reviewing automations"
      "inspect_agent" -> "Reviewing automations"
      "prepare_agent_action" -> "Preparing an automation update"
      "prepare_external_action" -> "Preparing an external action"
      "query_agent" -> "Reviewing an automation"
      "notes_search" -> "Reviewing notes"
      "notes_get" -> "Reviewing notes"
      "notes_list_recent" -> "Reviewing notes"
      "voice_memos_search" -> "Reviewing Voice Memos"
      "voice_memos_get" -> "Reviewing Voice Memos"
      "voice_memos_list_recent" -> "Reviewing Voice Memos"
      "files_search" -> "Reviewing files"
      "files_get" -> "Reviewing files"
      "files_list_recent" -> "Reviewing files"
      "messages_search" -> "Reviewing Messages"
      "messages_get" -> "Reviewing Messages"
      "messages_list_recent" -> "Reviewing Messages"
      "messages_chats_recent" -> "Reviewing Messages"
      "reminders_open" -> "Reviewing Reminders"
      "reminders_due_soon" -> "Reviewing Reminders"
      "reminders_search" -> "Reviewing Reminders"
      "reminders_get" -> "Reviewing Reminders"
      "browser_history_recent" -> "Reviewing browser history"
      "browser_history_by_host" -> "Reviewing browser history"
      "browser_history_search" -> "Reviewing browser history"
      "browser_history_get" -> "Reviewing browser history"
      "recall_anywhere" -> "Reviewing local sources"
      _other -> "Working"
    end
  end

  defp tool_title(tool) do
    %{"tool" => tool}
    |> tool_outcome_phrase()
    |> capitalize_sentence()
  end

  defp pluralize(word, count, plural \\ nil)

  defp pluralize(word, 1, _plural), do: word
  defp pluralize(_word, _count, plural) when is_binary(plural), do: plural
  defp pluralize(word, _count, _plural), do: word <> "s"

  defp format_count(count) when is_integer(count), do: Integer.to_string(count)

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    fetch_value(map, key, default)
  end

  defp map_value(_map, _key, default), do: default

  defp fetch_value(map, key, default) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(map, existing_atom_key(key)) do
          {:ok, value} -> value
          :error -> default
        end
    end
  end

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(key), do: key

  defp drop_blank_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      _entry -> false
    end)
  end

  defp present?(value), do: not is_nil(value) and value != ""

  defp truncate(value) when is_binary(value) do
    if String.length(value) > @max_detail_chars do
      String.slice(value, 0, @max_detail_chars) <> "..."
    else
      value
    end
  end

  defp truncate(value), do: value |> to_string() |> truncate()

  defp truncate_headline(value) when is_binary(value) do
    if String.length(value) > @max_headline_chars do
      String.slice(value, 0, @max_headline_chars) <> "..."
    else
      value
    end
  end

  defp truncate_headline(value), do: value |> to_string() |> truncate_headline()

  defp json_time(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_time(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_time(_value), do: nil
end
