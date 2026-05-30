defmodule Maraithon.TelegramAssistant.VerificationClient do
  @moduledoc """
  Deterministic client used by the operational Telegram verification loop.

  It exercises the same runner, context, and toolbox path without depending on a
  live LLM provider. The live model can still be used by opting out in the Mix
  task.
  """

  def next_step(payload) when is_map(payload) do
    text = current_text(payload)
    tool_history = read_field(payload, "tool_history") |> List.wrap()

    if tool_history == [] do
      first_step(text, payload)
    else
      final_step(text, payload)
    end
  end

  def next_step(_payload), do: {:error, :invalid_verification_payload}

  def todo_intelligence_complete(prompt) when is_binary(prompt) do
    candidates = extract_json_after(prompt, "CANDIDATE_TODOS_JSON:") || []

    decisions =
      candidates
      |> Enum.with_index()
      |> Enum.map(fn {candidate, index} ->
        todo = candidate |> stringify_top_level_keys() |> ensure_todo(index)

        %{
          "candidate_index" => index,
          "action" => "create",
          "existing_todo_id" => nil,
          "dedupe_key" => todo["dedupe_key"],
          "reasoning" => "Verification accepted the requested todo write.",
          "todo" => todo
        }
      end)

    {:ok,
     %{
       "content" =>
         Jason.encode!(%{
           "summary" => "Verification todo intelligence decisions.",
           "decisions" => decisions
         }),
       "usage" => %{}
     }}
  end

  def todo_intelligence_complete(%{"messages" => messages}) when is_list(messages) do
    messages
    |> List.last()
    |> case do
      %{"content" => prompt} when is_binary(prompt) -> todo_intelligence_complete(prompt)
      _other -> {:error, :verification_todo_prompt_missing}
    end
  end

  def todo_intelligence_complete(_prompt), do: {:error, :verification_todo_prompt_missing}

  defp first_step(text, payload) do
    normalized = normalize(text)

    cond do
      String.contains?(normalized, "add renew the verification passport") ->
        tool_calls([
          {"upsert_todos",
           %{
             "todos" => [
               %{
                 "source" => "telegram_verification",
                 "kind" => "general",
                 "attention_mode" => "act_now",
                 "title" => "Renew the verification passport",
                 "summary" => "Renew the verification passport by Friday.",
                 "next_action" => "Renew the verification passport by Friday.",
                 "dedupe_key" => "verification:renew-passport",
                 "metadata" => %{
                   "life_domain" => "personal",
                   "why_now" => "The operator asked to add it by Friday.",
                   "source_evidence" => text,
                   "confidence" => 0.95
                 }
               }
             ]
           }}
        ])

      String.contains?(normalized, "todo list") or String.contains?(normalized, "todos are open") ->
        tool_calls([{"list_todos", %{"limit" => 20}}])

      String.contains?(normalized, "change this todo") ->
        tool_calls([
          {"update_todo",
           %{
             "todo_id" => linked_todo_id(payload),
             "priority" => 88,
             "next_action" => "Return the verification library book today."
           }}
        ])

      String.contains?(normalized, "mark this done") ->
        tool_calls([
          {"resolve_todo",
           %{
             "todo_id" => linked_todo_id(payload),
             "status" => "done",
             "include_remaining" => true,
             "limit" => 5
           }}
        ])

      String.contains?(normalized, "dismiss this todo") ->
        tool_calls([
          {"delete_todo",
           %{
             "todo_id" => linked_todo_id(payload),
             "resolution_note" => "No longer relevant.",
             "include_remaining" => true
           }}
        ])

      String.contains?(normalized, "merge crm person") ->
        [merged_id, surviving_id] = crm_merge_ids(text)

        tool_calls([
          {"merge_people",
           %{
             "surviving_person_id" => surviving_id,
             "merged_person_id" => merged_id,
             "evidence" => "User explicitly confirmed these CRM records are the same person.",
             "model_rationale" => "Verification merge request supplied both CRM ids.",
             "performed_by" => "telegram_verification"
           }}
        ])

      String.contains?(normalized, "priya shah") ->
        tool_calls([
          {"upsert_person",
           %{
             "display_name" => "Priya Shah",
             "relationship" => "Design partner",
             "preferred_communication_method" => "Slack",
             "notes" => "Priya Shah is the operator's design partner and prefers Slack.",
             "metadata" => %{"verification_source" => "telegram_verification"}
           }}
        ])

      String.contains?(normalized, "meeting with matthew raue") or
        String.contains?(normalized, "meeting with matthew") or
          String.contains?(normalized, "prep me for matthew") ->
        tool_calls([
          {"calendar_events_for_person", %{"person" => "Matthew Raue", "limit" => 5}},
          {"review_connected_context", %{"query" => "Matthew Raue", "max_results" => 5}},
          {"list_todos", %{"query" => "Matthew Raue", "limit" => 10}}
        ])

      String.contains?(normalized, "remember as durable memory") ->
        tool_calls([
          {"remember_preferences",
           %{
             "rules" => [
               %{
                 "label" => "chief_of_staff_priority_stack",
                 "instruction" =>
                   "In chief-of-staff mode, family and personal calendar commitments outrank routine stale work unless the work is a close relationship or active deliverable.",
                 "source" => "telegram_verification",
                 "confidence" => 0.98
               }
             ]
           }}
        ])

      String.contains?(normalized, "queue a one-time job") or
          String.contains?(normalized, "queue a job") ->
        tool_calls([
          {"create_scheduled_task",
           %{
             "title" => "Review open loops, calendar, CRM, and todos",
             "once_at" => scheduled_at(text),
             "prompt" =>
               "Review my open loops, calendar, CRM, and todos, then send me a prep note."
           }}
        ])

      String.contains?(normalized, "what did i look at") or
          String.contains?(normalized, "researching the matthew raue") ->
        tool_calls([
          {"browser_history_search", %{"query" => "Matthew Raue setup pricing", "limit" => 5}}
        ])

      String.contains?(normalized, "what needs my attention first") ->
        tool_calls([
          {"list_todos", %{"limit" => 20}},
          {"calendar_events_around", %{"hours_before" => 2, "hours_after" => 72}}
        ])

      true ->
        final_step(text, payload)
    end
  end

  defp final_step(text, _payload) do
    normalized = normalize(text)

    cond do
      String.contains?(normalized, "concise two-sentence reply") ->
        final("That works for me. Send over a couple of times next week and I will confirm one.")

      String.contains?(normalized, "todo list") ->
        final(
          "Your open work includes Emma's dentist appointment, Matthew Raue setup/pricing, and the verification passport renewal."
        )

      String.contains?(normalized, "add renew the verification passport") ->
        final("Added the passport renewal work item for Friday.", "assistant_reply")

      String.contains?(normalized, "change this todo") ->
        final("Updated the linked work item with the new priority and next action.")

      String.contains?(normalized, "mark this done") ->
        final("Done. I marked the linked work item complete.")

      String.contains?(normalized, "dismiss this todo") ->
        final("Dismissed the linked work item as no longer relevant.")

      String.contains?(normalized, "merge crm person") ->
        final("Merged the duplicate CRM person into the surviving relationship record.")

      String.contains?(normalized, "who is matthew raue") ->
        final(
          "Matthew Raue is the Raue Automation contact tied to setup help and pricing. You owe him the recommended setup path, pricing owner, and a concrete ETA."
        )

      String.contains?(normalized, "priya shah") ->
        final("Remembered Priya Shah as your design partner who prefers Slack.")

      String.contains?(normalized, "who is this") ->
        final(
          "This is Matthew Raue from Raue Automation. He is attached to the setup-help and pricing follow-up, and you owe him the recommended path, owner, and ETA."
        )

      String.contains?(normalized, "what accounts are connected") ->
        final(
          "Connected accounts include Telegram, Gmail, and Slack in this verification workspace."
        )

      String.contains?(normalized, "meeting with matthew") ->
        final(
          "For the Matthew Raue meeting, the purpose is setup and pricing prep. Bring the recommended setup path, name the pricing owner, and give him an ETA."
        )

      String.contains?(normalized, "draft a reply to matthew") ->
        final(
          "Hi Matthew - I recommend we use the setup path we discussed, with pricing owned on our side before we lock the final number. I will send the concrete owner and ETA by Friday."
        )

      String.contains?(normalized, "remember as durable memory") ->
        final(
          "Remembered: family and personal calendar items outrank routine stale work unless the work is a close relationship or active deliverable."
        )

      String.contains?(normalized, "queue a one-time job") or
          String.contains?(normalized, "queue a job") ->
        final(
          "Queued the job to review open loops, calendar, CRM, and todos, then send a prep note."
        )

      String.contains?(normalized, "what did i look at") ->
        final(
          "You looked at Matthew Raue setup/pricing context in browser history, including the Raue Automation setup pricing notes."
        )

      String.contains?(normalized, "what needs my attention first") ->
        final(
          "First: family/personal, including Emma's dentist and personal calendar context. Next: Matthew Raue's setup/pricing follow-up because it is an active relationship/business commitment.",
          "todo_digest"
        )

      true ->
        final("Verification response complete.")
    end
  end

  defp tool_calls(calls) do
    {:ok,
     %{
       "status" => "tool_calls",
       "tool_calls" =>
         Enum.map(calls, fn {tool, arguments} ->
           %{"tool" => tool, "arguments" => arguments || %{}}
         end),
       "summary" => "verification tool step"
     }}
  end

  defp final(text, message_class \\ "assistant_reply") do
    {:ok,
     %{
       "status" => "final",
       "assistant_message" => text,
       "message_class" => message_class,
       "summary" => "verification final"
     }}
  end

  defp current_text(payload) do
    payload
    |> read_field("current_user_request")
    |> read_field("text")
    |> case do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp linked_todo_id(payload) do
    payload
    |> read_field("context")
    |> read_field("linked_item")
    |> read_field("todo")
    |> read_field("id")
  end

  defp crm_merge_ids(text) when is_binary(text) do
    case Regex.scan(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i, text) do
      [[merged_id], [surviving_id] | _rest] -> [merged_id, surviving_id]
      _other -> [nil, nil]
    end
  end

  defp scheduled_at(text) do
    case Regex.run(~r/for\s+([0-9T:Z+.-]+)\s+to\s+review/i, text) do
      [_full, at] -> at
      _other -> DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.to_iso8601()
    end
  end

  defp normalize(text) when is_binary(text), do: String.downcase(text)
  defp normalize(_text), do: ""

  defp read_field(%_{} = struct, key), do: read_field(Map.from_struct(struct), key)

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _other ->
          nil
      end)
  end

  defp read_field(_map, _key), do: nil

  defp extract_json_after(prompt, marker) do
    case String.split(prompt, marker, parts: 2) do
      [_before, json] ->
        case Jason.decode(String.trim(json)) do
          {:ok, decoded} -> decoded
          _other -> nil
        end

      _other ->
        nil
    end
  end

  defp ensure_todo(candidate, index) do
    source = read_string(candidate, "source", "telegram")
    kind = read_string(candidate, "kind", "general")
    title = read_string(candidate, "title", "Open todo")
    summary = read_string(candidate, "summary", read_string(candidate, "todo", title))

    next_action =
      read_string(
        candidate,
        "next_action",
        "Open the source item, confirm the real ask, and decide whether this still matters."
      )

    source_item_id = read_string(candidate, "source_item_id", nil)

    dedupe_key =
      read_string(
        candidate,
        "dedupe_key",
        generated_dedupe_key(source, kind, source_item_id, title, index)
      )

    candidate
    |> Map.put("source", source)
    |> Map.put("kind", kind)
    |> Map.put_new("attention_mode", "act_now")
    |> Map.put("title", title)
    |> Map.put("summary", summary)
    |> Map.put("next_action", next_action)
    |> Map.put_new("priority", 50)
    |> Map.put_new("status", "open")
    |> Map.put("dedupe_key", dedupe_key)
    |> Map.update("metadata", %{}, fn
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end)
    |> Map.update("action_draft", %{}, fn
      draft when is_map(draft) -> draft
      draft when is_binary(draft) -> %{"text" => draft}
      _other -> %{}
    end)
  end

  defp generated_dedupe_key(source, kind, source_item_id, title, index) do
    slug =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "todo-#{index}"
        value -> value
      end

    item = source_item_id || "#{slug}-#{index}"
    "#{source}:#{kind}:#{item}"
  end

  defp read_string(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _other ->
        default
    end
  end

  defp read_string(_map, _key, default), do: default

  defp stringify_top_level_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
