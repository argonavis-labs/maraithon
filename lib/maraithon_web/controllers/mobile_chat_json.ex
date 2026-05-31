defmodule MaraithonWeb.MobileChatJSON do
  @moduledoc false

  alias Maraithon.TelegramAssistant.{PreparedAction, Run}
  alias Maraithon.TelegramAssistant.WorkSummary
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Todos.{Todo, UserFacingCopy}
  alias Maraithon.AssistantChat.ThreadNaming
  alias Maraithon.Repo
  alias MaraithonWeb.{ApiErrorCopy, MobileJSON}

  @public_structured_data_keys ~w(calculation)
  @internal_assistant_markers [
    "<redacted",
    "=>",
    "{",
    "}",
    "confidence_score",
    "quality_score",
    "priority_score",
    "urgency_score",
    "relevance_score",
    "interrupt_score",
    "source_health",
    "quality_verification",
    "generation_mode",
    "message_class",
    "model_name",
    "model_provider",
    "model_response",
    "model confidence",
    "model reasoning",
    "model score",
    "configured model",
    "model synthesis",
    "generation failed",
    "did not produce a valid brief",
    "checked source view",
    "valid json",
    "structured json",
    "reasoning_effort",
    "finish_reason",
    "max_output_tokens",
    "input_tokens",
    "output_tokens",
    "total_tokens",
    "prompt_snapshot",
    "system_prompt",
    "raw_prompt",
    "tool_call",
    "tool call",
    "tool_name",
    "http_status",
    "db_timeout",
    "stacktrace",
    "postgrex",
    "ecto.",
    "phoenix.",
    "dbconnection",
    "metadata",
    "internal_",
    "token=",
    "token:",
    "authorization",
    "bearer",
    "access_token",
    "refresh_token",
    "client_secret",
    "private_key",
    "api_key",
    "apikey",
    "secret=",
    "secret:"
  ]
  @internal_assistant_patterns [
    ~r/\b(?:confidence|quality|priority|urgency|relevance|interrupt)_score\s*[:=]/,
    ~r/\b\d{1,3}%\s+confidence\b/,
    ~r/\bconfidence\s+(?:this|that|was|is)\b/,
    ~r/^\s*reasoning\s*:/,
    ~r/\bmodel\s+(?:classified|confidence|ranked|reasoning|saw|score)\b/,
    ~r/\bscore\s*[:=]\s*\d/,
    ~r/\bscore\s+(?:says|was|is)\b/,
    ~r/\bthreshold\s*[:=]\s*\d/,
    ~r/\b(?:token|secret|password|api[_-]?key|access[_-]?token|refresh[_-]?token)\s*[:=]/,
    ~r/\b(?:authorization|bearer)\b/
  ]
  @public_linked_todo_fields [
    {"id", :id},
    {"source", :source},
    {"kind", :kind},
    {"attention_mode", :attention_mode},
    {"title", :title},
    {"summary", :summary},
    {"next_action", :next_action},
    {"due_at", :due_at},
    {"notes", :notes},
    {"action_plan", :action_plan},
    {"owner_label", :owner_label},
    {"priority", :priority},
    {"status", :status},
    {"snoozed_until", :snoozed_until},
    {"closed_at", :closed_at},
    {"source_occurred_at", :source_occurred_at},
    {"inserted_at", :inserted_at},
    {"updated_at", :updated_at}
  ]
  @action_card_label_pattern ~r/^(\s*(?:Context used|Context|Decision|Why now|State|Next|Prepared|Evidence):\s*)(.*)$/i

  def thread_index(threads) when is_list(threads) do
    %{threads: Enum.map(threads, &thread_summary/1), next_cursor: nil}
  end

  def thread(%Conversation{} = conversation) do
    %{thread: full_thread(conversation)}
  end

  def thread_with_run(%Conversation{} = conversation, %Run{} = run) do
    %{thread: full_thread(conversation, run), run: run(run)}
  end

  def thread_with_run(%Conversation{} = conversation, _run), do: thread(conversation)

  def run(%Run{} = run) do
    %{
      id: run.id,
      thread_id: run.conversation_id,
      status: normalize_run_status(run),
      started_at: json_value(run.started_at),
      finished_at: json_value(run.finished_at),
      error: public_run_error(run),
      message_class: summary_value(run.result_summary, :message_class),
      work_summary: WorkSummary.for_run(run)
    }
  end

  def prepared_action(%PreparedAction{} = prepared_action) do
    %{
      id: prepared_action.id,
      status: prepared_action.status,
      action_type: prepared_action.action_type,
      target_type: prepared_action.target_type,
      preview_text: prepared_action.preview_text,
      expires_at: json_value(prepared_action.expires_at)
    }
  end

  def error(reason), do: ApiErrorCopy.mobile_chat(reason)

  def action_result(%PreparedAction{} = prepared_action, %Conversation{} = conversation) do
    %{
      prepared_action: prepared_action(prepared_action),
      thread: full_thread(conversation)
    }
  end

  defp thread_summary(%Conversation{} = conversation) do
    latest = latest_turn(conversation)

    %{
      id: conversation.id,
      title: thread_title(conversation),
      status: conversation.status,
      last_turn_at: json_value(conversation.last_turn_at),
      updated_at: json_value(conversation.updated_at),
      message_count: length(conversation.turns || []),
      latest_message: latest && message(latest)
    }
  end

  defp full_thread(%Conversation{} = conversation, run \\ nil) do
    active_run = run || active_run(conversation)

    %{
      id: conversation.id,
      title: thread_title(conversation),
      status: conversation.status,
      pending_run: active_run && run(active_run),
      messages:
        conversation
        |> sorted_turns()
        |> Enum.map(&message/1)
    }
  end

  defp message(%Turn{} = turn) do
    structured_data = turn.structured_data || %{}
    public_structured_data = public_structured_data(structured_data)
    prepared_action_id = structured_data["prepared_action_id"]

    %{
      id: turn.id,
      client_message_id: turn.client_message_id || structured_data["client_message_id"],
      role: turn.role,
      body: public_message_body(turn),
      turn_kind: turn.turn_kind,
      message_class: structured_data["message_class"],
      sent_at: json_value(turn.inserted_at),
      delivery_state: turn.delivery_state || "delivered",
      run_id: structured_data["run_id"],
      actions: actions_for(turn, prepared_action_id),
      linked_todo: public_linked_todo(structured_data["linked_todo"]),
      work_summary: WorkSummary.for_message(turn),
      structured_data: public_structured_data
    }
  end

  defp public_message_body(%Turn{role: "assistant", text: text} = turn) when is_binary(text) do
    text
    |> strip_message_role_prefix()
    |> then(fn stripped_text ->
      if action_card_message?(turn.structured_data) do
        public_action_card_message_text(stripped_text)
      else
        public_assistant_message_text(stripped_text)
      end
    end)
  end

  defp public_message_body(%Turn{text: text}), do: text

  defp strip_message_role_prefix(value) do
    value
    |> String.replace(~r/(^|\n)\s*(?:assistant|maraithon|system)\s*:\s*/i, "\\1")
    |> String.trim()
  end

  defp public_assistant_message_text(value) do
    safe_text =
      value
      |> String.split("\n", trim: false)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&unsafe_assistant_line?/1)
      |> Enum.map(&product_message_text/1)
      |> Enum.join("\n")
      |> String.trim()

    cond do
      safe_text != "" ->
        safe_text

      unsafe_assistant_text?(value) ->
        ApiErrorCopy.mobile_chat_run_error(value)

      true ->
        value
        |> product_message_text()
        |> String.trim()
    end
  end

  defp public_action_card_message_text(value) do
    safe_text =
      value
      |> String.split("\n", trim: false)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&unsafe_assistant_line?/1)
      |> Enum.map(&product_action_card_message_text/1)
      |> Enum.join("\n")
      |> String.trim()

    cond do
      safe_text != "" ->
        safe_text

      unsafe_assistant_text?(value) ->
        ApiErrorCopy.mobile_chat_run_error(value)

      true ->
        value
        |> product_action_card_message_text()
        |> String.trim()
    end
  end

  defp action_card_message?(%{"message_class" => "todo_item"}), do: true
  defp action_card_message?(%{message_class: "todo_item"}), do: true
  defp action_card_message?(_structured_data), do: false

  defp unsafe_assistant_line?(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        false

      unsafe_assistant_text?(trimmed) ->
        true

      true ->
        false
    end
  end

  defp unsafe_assistant_text?(value) when is_binary(value) do
    lower = String.downcase(value)

    technical_message_body?(value) or
      Enum.any?(@internal_assistant_markers, &String.contains?(lower, &1)) or
      Enum.any?(@internal_assistant_patterns, &Regex.match?(&1, lower))
  end

  defp unsafe_assistant_text?(_value), do: true

  defp product_message_text(value) when is_binary(value) do
    value
    |> UserFacingCopy.open_work_language()
    |> String.replace(~r/\bCRM context\b/i, "relationship context")
    |> String.replace(~r/\bCRM\b/i, "relationship data")
  end

  defp product_message_text(value), do: value

  defp product_action_card_message_text(value) when is_binary(value) do
    case Regex.run(@action_card_label_pattern, value, capture: :all_but_first) do
      [label, body] -> label <> product_message_text(body)
      _other -> product_message_text(value)
    end
  end

  defp product_action_card_message_text(value), do: value

  defp technical_message_body?(value) do
    Regex.match?(
      ~r/(?:\b(?:authorization|bearer|access_token|refresh_token|client_secret|api[_-]?key|token|http_status)\b\s*[:=]|\b(?:stacktrace|internal_stacktrace|FunctionClauseError|RuntimeError|DBConnection|Postgrex|clientError|serverError)\b|\b(?:Ecto|Phoenix|Elixir)\.)/i,
      value
    )
  end

  defp public_linked_todo(nil), do: nil

  defp public_linked_todo(%Todo{} = todo), do: MobileJSON.todo(todo)

  defp public_linked_todo(%{} = todo) do
    @public_linked_todo_fields
    |> Enum.reduce(%{}, fn {key, atom_key}, acc ->
      todo
      |> known_map_value(key, atom_key)
      |> put_linked_todo_value(acc, key)
    end)
    |> Map.put(
      "metadata",
      MobileJSON.public_todo_metadata(known_map_value(todo, "metadata", :metadata))
    )
  end

  defp public_linked_todo(_linked_todo), do: nil

  defp put_linked_todo_value(nil, acc, _key), do: acc

  defp put_linked_todo_value(value, acc, key) when is_binary(value) do
    if String.trim(value) == "" do
      acc
    else
      Map.put(acc, key, value)
    end
  end

  defp put_linked_todo_value(value, acc, key), do: Map.put(acc, key, json_value(value))

  defp known_map_value(map, string_key, atom_key) when is_map(map) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end

  defp public_structured_data(structured_data) when is_map(structured_data) do
    Enum.reduce(structured_data, %{}, fn {key, value}, acc ->
      key = to_string(key)

      if key in @public_structured_data_keys do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp public_structured_data(_structured_data), do: %{}

  defp actions_for(%Turn{turn_kind: "approval_prompt"}, prepared_action_id)
       when is_binary(prepared_action_id) do
    if prepared_action_pending?(prepared_action_id) do
      [
        %{
          id: prepared_action_id,
          kind: "prepared_action_decision",
          label: "Confirm",
          decision: "confirm",
          style: "primary"
        },
        %{
          id: prepared_action_id,
          kind: "prepared_action_decision",
          label: "Cancel",
          decision: "reject",
          style: "destructive"
        }
      ]
    else
      []
    end
  end

  defp actions_for(_turn, _prepared_action_id), do: []

  defp prepared_action_pending?(prepared_action_id) do
    case Repo.get(PreparedAction, prepared_action_id) do
      %PreparedAction{status: "awaiting_confirmation"} -> true
      _ -> false
    end
  end

  defp active_run(%Conversation{} = conversation) do
    case Maraithon.TelegramConversations.active_run_for_conversation(conversation.id) do
      %Run{} = run -> run
      nil -> nil
    end
  end

  defp normalize_run_status(%Run{status: "completed", result_summary: result_summary}) do
    if summary_value(result_summary, :message_class) == "approval_prompt" do
      "waiting_confirmation"
    else
      "completed"
    end
  end

  defp normalize_run_status(%Run{status: status}), do: status

  defp public_run_error(%Run{error: error}) do
    ApiErrorCopy.mobile_chat_run_error(error)
  end

  defp latest_turn(%Conversation{} = conversation) do
    conversation
    |> sorted_turns()
    |> List.last()
  end

  defp sorted_turns(%Conversation{turns: turns}) when is_list(turns) do
    Enum.sort_by(turns, & &1.inserted_at, DateTime)
  end

  defp sorted_turns(_conversation), do: []

  defp thread_title(%Conversation{} = conversation) do
    [
      get_in(conversation.metadata || %{}, ["title"]),
      first_user_turn_title(conversation),
      conversation.summary
    ]
    |> Enum.find_value(&public_thread_title/1)
    |> Kernel.||("New conversation")
  end

  defp public_thread_title(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> strip_title_role_prefix()
    |> reject_placeholder_title()
    |> reject_technical_title()
    |> truncate_title()
  end

  defp public_thread_title(_value), do: nil

  defp strip_title_role_prefix(value) do
    value
    |> String.replace(~r/(^|\s)(?:assistant|maraithon|user|operator|system)\s*:\s*/i, "\\1")
    |> String.trim()
  end

  defp reject_placeholder_title(""), do: nil

  defp reject_placeholder_title(value) do
    if String.downcase(value) == "new conversation", do: nil, else: value
  end

  defp reject_technical_title(nil), do: nil

  defp reject_technical_title(value) do
    cond do
      String.contains?(value, ["{", "}", "=>"]) ->
        nil

      Regex.match?(~r/\b(?:assistant_reply|approval_prompt|tool_call)\b/i, value) ->
        nil

      Regex.match?(
        ~r/\b(?:run_id|client_message_id|structured_data|authorization|token)\b\s*[:=]/i,
        value
      ) ->
        nil

      unsafe_generation_title?(value) ->
        nil

      true ->
        value
    end
  end

  defp unsafe_generation_title?(value) when is_binary(value) do
    Regex.match?(
      ~r/\b(?:generation failed|configured model|model synthesis|did not produce a valid brief|checked source view|valid json|structured json)\b/i,
      value
    )
  end

  defp truncate_title(nil), do: nil

  defp truncate_title(value) do
    if String.length(value) > 90 do
      value
      |> String.slice(0, 89)
      |> String.trim()
      |> Kernel.<>("...")
    else
      value
    end
  end

  defp first_user_turn_title(%Conversation{} = conversation) do
    conversation
    |> sorted_turns()
    |> Enum.find(&(&1.role == "user"))
    |> case do
      %Turn{text: text} when is_binary(text) ->
        ThreadNaming.title_for_message(text)

      _ ->
        nil
    end
  end

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_value(value), do: value

  defp summary_value(summary, key) when is_map(summary) and is_atom(key) do
    Map.get(summary, key) || Map.get(summary, Atom.to_string(key))
  end

  defp summary_value(_summary, _key), do: nil
end
