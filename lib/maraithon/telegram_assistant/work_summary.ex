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

  @max_detail_chars 140
  @max_headline_chars 96
  @max_steps 12
  @max_tool_calls 8
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
    |> Enum.take(@max_steps)
    |> maybe_query_steps(run_id)
  end

  defp run_steps(%Run{id: run_id}) do
    query_steps(run_id)
  end

  defp maybe_query_steps([], run_id), do: query_steps(run_id)
  defp maybe_query_steps(steps, _run_id), do: steps

  defp query_steps(run_id) when is_binary(run_id) do
    Step
    |> where([step], step.run_id == ^run_id)
    |> order_by([step], asc: step.sequence)
    |> limit(@max_steps)
    |> Repo.all()
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
        "summary" => tool_history_summary(entry)
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
  defp step_title(%Step{step_type: "llm_request"}), do: "Prepared the answer"

  defp step_title(%Step{step_type: "llm_response", response_payload: response}) do
    case map_value(response || %{}, "status") do
      "tool_calls" -> "Planned supporting checks"
      _ -> "Wrote the reply"
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

  defp step_detail(%Step{step_type: "tool_call"} = step), do: tool_step_summary(step)

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
    |> replace_result_regex(~r/^No open work found\.?$/i, "This check surfaced no open work.")
    |> replace_result_regex(~r/\bStart with\s+/, "Start here: ")
    |> replace_result_regex(~r/\bstart with\s+/, "start here: ")
    |> replace_result_regex(
      ~r/^No connected accounts found\.?$/i,
      "No connected accounts are available yet."
    )
    |> replace_result_regex(
      ~r/^No connected sources found\.?$/i,
      "No connected sources are available yet."
    )
    |> replace_result_regex(~r/\bCRM context\b/i, "relationship context")
    |> replace_result_regex(~r/\bCRM\b/i, "relationship data")
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
        "This check surfaced no open work."

      {"work item", count} ->
        "Found #{format_count(count)} open work #{pluralize("item", count)}."

      {"connected account", 0} ->
        "No connected accounts are available yet."

      {"connected source", 0} ->
        "No connected sources are available yet."

      {_singular, 0} ->
        "No #{pluralize(singular, 2, plural)} found."

      {_singular, count} ->
        "Found #{format_count(count)} #{pluralize(singular, count, plural)}."
    end
  end

  defp result_count_summary(0), do: "No results found."

  defp result_count_summary(count),
    do: "Found #{format_count(count)} #{pluralize("result", count)}."

  defp completed_check_summary, do: "Completed the check."

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
        "No preferences saved yet."

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
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp clean_item_text(_value), do: nil

  defp append_status(nil, _status), do: nil
  defp append_status(label, status) when status in [nil, "", "connected", "completed"], do: label
  defp append_status(label, status), do: "#{label} (#{status_label(status)})"

  defp status_label("needs_refresh"), do: "reconnect needed"
  defp status_label("missing_scope"), do: "needs permission"
  defp status_label("not_configured"), do: "setup needed"
  defp status_label("setup_required"), do: "setup needed"
  defp status_label("partially_configured"), do: "partially set up"
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

  defp run_headline(%Run{status: "running"}, steps, _tool_calls) do
    case List.last(steps) do
      %Step{step_type: "context_fetch"} ->
        "Reading context"

      %Step{step_type: "llm_request"} ->
        "Preparing the answer"

      %Step{step_type: "llm_response"} ->
        "Reviewing the answer"

      %Step{step_type: "tool_call", request_payload: request} ->
        tool_running_headline(map_value(request || %{}, "tool", "tool"))

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
      ~r/^(?:No |Found \d+\b|Completed the check\.?$|Checking now\.?$|This check (?:returned|surfaced)\b|This check could not finish\.?$|.* could not finish\.?$)/i,
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
      "list_connected_accounts" -> "checked connected accounts"
      "connected_accounts" -> "checked connected accounts"
      "list_todos" -> "checked open work"
      "open_work" -> "checked open work"
      "get_open_work_summary" -> "reviewed open work"
      "open_work_review" -> "reviewed open work"
      "get_open_loops" -> "reviewed follow-through"
      "open_loops" -> "reviewed follow-through"
      "inspect_open_insight" -> "checked the selected item"
      "linked_item" -> "checked the selected item"
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
      "list_people" -> "checked people"
      "get_person" -> "checked people"
      "people" -> "checked people"
      "upsert_person" -> "updated people"
      "link_person_data" -> "updated people"
      "merge_people" -> "updated people"
      "delete_person" -> "updated people"
      "people_update" -> "updated people"
      "get_relationship_context" -> "checked relationship context"
      "crm_context" -> "checked relationship context"
      "relationship_context" -> "checked relationship context"
      "review_connected_context" -> "checked connected sources"
      "connected_sources" -> "checked connected sources"
      "learn_relationship_context" -> "updated relationship notes"
      "relationship_learning" -> "updated relationship notes"
      "calendar_list_events" -> "checked calendar"
      "calendar_events_for_person" -> "checked calendar"
      "calendar_events_around" -> "checked calendar"
      "calendar_search" -> "checked calendar"
      "calendar_event_get" -> "checked calendar"
      "calendar" -> "checked calendar"
      "gmail_search_messages" -> "checked Gmail"
      "gmail_get_message" -> "checked Gmail"
      "gmail_drafts" -> "checked Gmail"
      "gmail" -> "checked Gmail"
      "slack_search_messages" -> "checked Slack"
      "slack_get_thread" -> "checked Slack"
      "slack_get_thread_context" -> "checked Slack"
      "slack" -> "checked Slack"
      "draft_message" -> "prepared a draft"
      "draft" -> "prepared a draft"
      "create_scheduled_task" -> "scheduled follow-up work"
      "scheduled_task" -> "scheduled follow-up work"
      "list_memories" -> "checked memory"
      "recall_memory" -> "checked memory"
      "write_memory" -> "updated memory"
      "memory_check" -> "checked memory"
      "memory_update" -> "updated memory"
      "memory" -> "updated memory"
      "list_preferences" -> "checked preferences"
      "preferences" -> "checked preferences"
      "remember_preferences" -> "updated preferences"
      "preference_update" -> "updated preferences"
      "preference" -> "updated a preference"
      "record_memory_feedback" -> "recorded feedback"
      "feedback" -> "recorded feedback"
      "update_memory_confidence" -> "updated memory"
      "forget_memory" -> "updated memory"
      "forget_preference" -> "updated preferences"
      "linear_list_or_lookup" -> "checked Linear"
      "linear" -> "checked Linear"
      "notaui_list_tasks" -> "checked Notaui tasks"
      "notaui" -> "checked Notaui tasks"
      "list_projects" -> "checked projects"
      "inspect_project" -> "checked projects"
      "projects" -> "checked projects"
      "update_project_scope" -> "updated a project"
      "decide_project_recommendation" -> "updated a project"
      "grant_project_repo_access" -> "updated a project"
      "prepare_project_action" -> "prepared a project update"
      "project_update" -> "updated a project"
      "start_implementation_run" -> "started a project run"
      "list_implementation_runs" -> "checked project runs"
      "update_implementation_run" -> "updated a project run"
      "project_run" -> "updated a project run"
      "list_agents" -> "checked automations"
      "inspect_agent" -> "checked automations"
      "automations" -> "checked automations"
      "prepare_agent_action" -> "prepared an automation update"
      "automation_update" -> "prepared an automation update"
      "prepare_external_action" -> "prepared an external action"
      "prepared_action" -> "prepared an external action"
      "query_agent" -> "checked an automation"
      "automation_query" -> "checked an automation"
      "notes_search" -> "checked notes"
      "notes_get" -> "checked notes"
      "notes_list_recent" -> "checked notes"
      "notes" -> "checked notes"
      "voice_memos_search" -> "checked Voice Memos"
      "voice_memos_get" -> "checked Voice Memos"
      "voice_memos_list_recent" -> "checked Voice Memos"
      "voice_memos" -> "checked Voice Memos"
      "files_search" -> "checked files"
      "files_get" -> "checked files"
      "files_list_recent" -> "checked files"
      "files" -> "checked files"
      "messages_search" -> "checked Messages"
      "messages_get" -> "checked Messages"
      "messages_list_recent" -> "checked Messages"
      "messages_chats_recent" -> "checked Messages"
      "messages" -> "checked Messages"
      "reminders_open" -> "checked Reminders"
      "reminders_due_soon" -> "checked Reminders"
      "reminders_search" -> "checked Reminders"
      "reminders_get" -> "checked Reminders"
      "reminders" -> "checked Reminders"
      "browser_history_recent" -> "checked browser history"
      "browser_history_by_host" -> "checked browser history"
      "browser_history_search" -> "checked browser history"
      "browser_history_get" -> "checked browser history"
      "browser_history" -> "checked browser history"
      "recall_anywhere" -> "checked local sources"
      "local_context" -> "checked local sources"
      _other -> "completed supporting work"
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

  defp completed_reply_phrase([one]), do: "#{one} and replied"
  defp completed_reply_phrase([first, second]), do: "#{first}, #{second}, and replied"

  defp completed_reply_phrase([first, second, third]) do
    "#{first}, #{second}, #{third}, and replied"
  end

  defp completed_reply_phrase([first, second, third | rest]) do
    "#{first}, #{second}, #{third}, and #{length(rest)} more #{pluralize("check", length(rest))} before replying"
  end

  defp capitalize_sentence(phrase) when is_binary(phrase) do
    first = String.slice(phrase, 0, 1)
    rest = String.slice(phrase, 1, String.length(phrase))
    String.upcase(first) <> rest
  end

  defp tool_running_headline(tool) do
    case tool do
      "list_connected_accounts" -> "Checking connected accounts"
      "list_todos" -> "Checking open work"
      "get_open_work_summary" -> "Reviewing open work"
      "get_open_loops" -> "Reviewing follow-through"
      "inspect_open_insight" -> "Checking the selected item"
      "explain_action_ledger" -> "Reviewing action history"
      "update_briefing_schedule" -> "Updating the briefing schedule"
      "list_scheduled_tasks" -> "Reviewing scheduled follow-ups"
      "pause_scheduled_task" -> "Updating scheduled follow-ups"
      "cancel_scheduled_task" -> "Updating scheduled follow-ups"
      "list_preferences" -> "Checking preferences"
      "upsert_todos" -> "Updating open work"
      "update_todo" -> "Updating open work"
      "resolve_todo" -> "Updating open work"
      "delete_todo" -> "Updating open work"
      "todo_update" -> "Updating open work"
      "work_update" -> "Updating open work"
      "list_people" -> "Checking people"
      "get_person" -> "Checking people"
      "upsert_person" -> "Updating people"
      "link_person_data" -> "Updating people"
      "merge_people" -> "Updating people"
      "delete_person" -> "Updating people"
      "get_relationship_context" -> "Checking relationship context"
      "crm_context" -> "Checking relationship context"
      "relationship_context" -> "Checking relationship context"
      "review_connected_context" -> "Checking connected sources"
      "learn_relationship_context" -> "Updating relationship notes"
      "calendar_list_events" -> "Checking calendar"
      "calendar_events_for_person" -> "Checking calendar"
      "calendar_events_around" -> "Checking calendar"
      "calendar_search" -> "Checking calendar"
      "calendar_event_get" -> "Checking calendar"
      "gmail_search_messages" -> "Checking Gmail"
      "gmail_get_message" -> "Checking Gmail"
      "gmail_drafts" -> "Checking Gmail"
      "slack_search_messages" -> "Checking Slack"
      "slack_get_thread" -> "Checking Slack"
      "slack_get_thread_context" -> "Checking Slack"
      "draft_message" -> "Preparing a draft"
      "create_scheduled_task" -> "Scheduling follow-up work"
      "list_memories" -> "Checking memory"
      "recall_memory" -> "Checking memory"
      "write_memory" -> "Updating memory"
      "remember_preferences" -> "Updating preferences"
      "record_memory_feedback" -> "Recording feedback"
      "update_memory_confidence" -> "Updating memory"
      "forget_memory" -> "Updating memory"
      "forget_preference" -> "Updating preferences"
      "linear_list_or_lookup" -> "Checking Linear"
      "notaui_list_tasks" -> "Checking Notaui tasks"
      "list_projects" -> "Checking projects"
      "inspect_project" -> "Checking projects"
      "update_project_scope" -> "Updating a project"
      "decide_project_recommendation" -> "Updating a project"
      "grant_project_repo_access" -> "Updating a project"
      "prepare_project_action" -> "Preparing a project update"
      "start_implementation_run" -> "Starting a project run"
      "list_implementation_runs" -> "Checking project runs"
      "update_implementation_run" -> "Updating a project run"
      "list_agents" -> "Checking automations"
      "inspect_agent" -> "Checking automations"
      "prepare_agent_action" -> "Preparing an automation update"
      "prepare_external_action" -> "Preparing an external action"
      "query_agent" -> "Checking an automation"
      "notes_search" -> "Checking notes"
      "notes_get" -> "Checking notes"
      "notes_list_recent" -> "Checking notes"
      "voice_memos_search" -> "Checking Voice Memos"
      "voice_memos_get" -> "Checking Voice Memos"
      "voice_memos_list_recent" -> "Checking Voice Memos"
      "files_search" -> "Checking files"
      "files_get" -> "Checking files"
      "files_list_recent" -> "Checking files"
      "messages_search" -> "Checking Messages"
      "messages_get" -> "Checking Messages"
      "messages_list_recent" -> "Checking Messages"
      "messages_chats_recent" -> "Checking Messages"
      "reminders_open" -> "Checking Reminders"
      "reminders_due_soon" -> "Checking Reminders"
      "reminders_search" -> "Checking Reminders"
      "reminders_get" -> "Checking Reminders"
      "browser_history_recent" -> "Checking browser history"
      "browser_history_by_host" -> "Checking browser history"
      "browser_history_search" -> "Checking browser history"
      "browser_history_get" -> "Checking browser history"
      "recall_anywhere" -> "Checking local sources"
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
