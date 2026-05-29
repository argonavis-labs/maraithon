defmodule Maraithon.Drafts do
  @moduledoc """
  Generates approval-ready Gmail and Slack drafts using durable user voice memory.
  """

  alias Maraithon.LLM
  alias Maraithon.Memory.UserVoice
  alias Maraithon.OperatorMemory
  alias Maraithon.PreferenceMemory
  alias Maraithon.Tools
  alias Maraithon.UserMemory

  require Logger

  @ai_filler_patterns [
    ~r/\bI hope this (email|message) finds you well\.?\s*/i,
    ~r/\bI just wanted to\b/i,
    ~r/\bJust wanted to\b/i,
    ~r/\b[Cc]ircling back\b/,
    ~r/\b[Aa]s an AI\b/,
    ~r/\n+\s*(Best|Regards|Sincerely),\s*\n+\s*Maraithon\s*$/i
  ]

  def create(user_id, attrs, opts \\ [])

  def create(user_id, attrs, opts) when is_binary(user_id) and is_map(attrs) and is_list(opts) do
    with {:ok, channel} <- UserVoice.normalize_channel(read_string(attrs, "channel")),
         {:ok, purpose} <- required_string(attrs, "purpose"),
         {:ok, voice_result} <- maybe_refresh_voice(user_id, channel, attrs, opts),
         voice_context <- UserVoice.prompt_context(user_id, channel),
         prompt <- draft_prompt(user_id, channel, purpose, attrs, voice_context),
         {:ok, draft, llm_warning} <- generate_draft(channel, attrs, prompt, opts),
         draft <- sanitize_draft(draft),
         {:ok, saved, save_warning} <- maybe_save_provider_draft(user_id, channel, attrs, draft) do
      {:ok,
       %{
         source: "drafts",
         channel: channel,
         draft: draft,
         provider_draft: saved,
         voice_profile: voice_summary(voice_context, voice_result),
         warnings: Enum.reject([llm_warning, save_warning], &is_nil/1)
       }}
    end
  end

  def create(_user_id, _attrs, _opts), do: {:error, :invalid_draft_attrs}

  def sanitize_text(text) when is_binary(text) do
    text
    |> String.replace("—", "-")
    |> String.replace("–", "-")
    |> then(fn value ->
      Enum.reduce(@ai_filler_patterns, value, fn pattern, acc ->
        String.replace(acc, pattern, "")
      end)
    end)
    |> String.replace(~r/[ \t]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  def sanitize_text(text), do: text

  defp maybe_refresh_voice(user_id, channel, attrs, opts) do
    if truthy?(Map.get(attrs, "refresh_voice")) do
      refresh_opts =
        opts
        |> Keyword.put(:sample_texts, read_string_list(attrs, "sample_texts"))
        |> Keyword.put(:team_id, read_string(attrs, "team_id"))
        |> Keyword.put(:slack_user_id, read_string(attrs, "slack_user_id"))
        |> Keyword.put(
          :provider,
          read_string(attrs, "provider") || read_string(attrs, "google_provider")
        )
        |> Keyword.put(:max_samples, read_integer(attrs, "max_samples", 40))
        |> Keyword.put(:lookback_days, read_integer(attrs, "lookback_days", 180))

      case UserVoice.refresh_from_connectors(user_id, channel, refresh_opts) do
        {:ok, memory} -> {:ok, {:refreshed, memory.id}}
        {:error, reason} -> {:ok, {:refresh_failed, reason}}
      end
    else
      {:ok, :not_requested}
    end
  end

  defp draft_prompt(user_id, channel, purpose, attrs, voice_context) do
    memory = %{
      preference_memory: PreferenceMemory.prompt_context(user_id),
      operator_summaries: OperatorMemory.summaries_for_prompt(user_id),
      user_memory_profile: UserMemory.prompt_context(user_id),
      channel_voice: voice_context
    }

    response_shape =
      case channel do
        "gmail" -> ~s({"subject":"...","body":"..."})
        "slack" -> ~s({"text":"..."})
      end

    """
    Create an approval-ready #{channel_label(channel)} draft in the operator's first-person voice.

    Return ONLY valid JSON:
    #{response_shape}

    Hard constraints:
    - Write as the operator, not as Maraithon or an assistant.
    - Do not use em dashes. Use commas, periods, colons, or parentheses.
    - Do not include AI-ish filler such as "I hope this finds you well", "circling back", "just wanted to", or assistant sign-offs.
    - Use the channel voice profile when relevant, but do not copy sample text verbatim.
    - Keep the draft direct, useful, and source-grounded.
    - Do not claim work is done, attached, delivered, approved, or sent unless the context proves it.
    - If information is missing, name the missing detail plainly instead of inventing it.

    Draft request JSON:
    #{Jason.encode!(draft_request_payload(channel, purpose, attrs))}

    User voice and memory JSON:
    #{Jason.encode!(memory)}
    """
  end

  defp draft_request_payload(channel, purpose, attrs) do
    %{
      channel: channel,
      purpose: purpose,
      recipient: read_string(attrs, "recipient"),
      to: read_string(attrs, "to"),
      subject: read_string(attrs, "subject"),
      thread_id: read_string(attrs, "thread_id"),
      reply_to_message_id: read_string(attrs, "reply_to_message_id"),
      context: read_value(attrs, "context", %{}),
      instructions: read_string(attrs, "instructions"),
      tone: read_string(attrs, "tone")
    }
    |> compact_map()
  end

  defp generate_draft(channel, attrs, prompt, opts) do
    fallback = fallback_draft(channel, attrs)

    case llm_json(prompt, opts) do
      {:ok, %{"subject" => subject, "body" => body}} when channel == "gmail" ->
        {:ok,
         %{
           "kind" => "gmail_draft",
           "subject" => non_empty(subject) || fallback["subject"],
           "body" => non_empty(body) || fallback["body"]
         }, nil}

      {:ok, %{"text" => text}} when channel == "slack" ->
        {:ok,
         %{
           "kind" => "slack_draft",
           "text" => non_empty(text) || fallback["text"]
         }, nil}

      {:error, reason} ->
        {:ok, fallback, {:llm_draft_failed, reason}}

      _ ->
        {:ok, fallback, :invalid_draft_response}
    end
  end

  defp llm_json(prompt, opts) do
    params = %{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => Keyword.get(opts, :max_tokens, 700),
      "temperature" => Keyword.get(opts, :temperature, 0.2),
      "reasoning_effort" => Keyword.get(opts, :reasoning_effort, "low")
    }

    llm_complete = Keyword.get(opts, :llm_complete, &LLM.complete/1)

    with {:ok, response} <- llm_complete.(params),
         {:ok, content} <- response_content(response),
         {:ok, parsed} <- decode_json(content) do
      {:ok, parsed}
    else
      {:error, reason} ->
        Logger.debug("Draft generation LLM failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp response_content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp response_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp response_content(content) when is_binary(content), do: {:ok, content}
  defp response_content(_response), do: {:error, :missing_llm_content}

  defp decode_json(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, %{} = parsed} -> {:ok, parsed}
      _ -> {:error, :invalid_json}
    end
  end

  defp sanitize_draft(%{"kind" => "gmail_draft"} = draft) do
    draft
    |> Map.update!("subject", &sanitize_text/1)
    |> Map.update!("body", &sanitize_text/1)
  end

  defp sanitize_draft(%{"kind" => "slack_draft"} = draft) do
    Map.update!(draft, "text", &sanitize_text/1)
  end

  defp maybe_save_provider_draft(user_id, "gmail", attrs, %{"subject" => subject, "body" => body})
       when is_binary(user_id) do
    if truthy?(Map.get(attrs, "save_to_provider")) do
      with {:ok, to} <- required_string(attrs, "to"),
           {:ok, subject} <- required_value(subject, "subject is required"),
           {:ok, body} <- required_value(body, "body is required") do
        args =
          %{
            "user_id" => user_id,
            "action" => "create",
            "to" => to,
            "subject" => subject,
            "body" => body,
            "cc" => read_string(attrs, "cc"),
            "bcc" => read_string(attrs, "bcc"),
            "thread_id" => read_string(attrs, "thread_id"),
            "in_reply_to" => read_string(attrs, "in_reply_to"),
            "references" => read_string(attrs, "references"),
            "provider" => read_string(attrs, "provider") || read_string(attrs, "google_provider"),
            "account" =>
              read_string(attrs, "account") || read_string(attrs, "google_account_email")
          }
          |> compact_map()

        case Tools.execute("gmail_drafts", args, %{surface: "internal", user_id: user_id}) do
          {:ok, result} -> {:ok, result, nil}
          {:error, reason} -> {:ok, nil, {:gmail_draft_save_failed, reason}}
        end
      end
    else
      {:ok, nil, nil}
    end
  end

  defp maybe_save_provider_draft(_user_id, "slack", attrs, _draft) do
    warning =
      if truthy?(Map.get(attrs, "save_to_provider")) do
        :slack_provider_drafts_not_supported
      end

    {:ok, nil, warning}
  end

  defp maybe_save_provider_draft(_user_id, _channel, _attrs, _draft), do: {:ok, nil, nil}

  defp fallback_draft("gmail", attrs) do
    recipient = read_string(attrs, "recipient") || "there"
    subject = read_string(attrs, "subject") || "Quick follow-up"
    purpose = read_string(attrs, "purpose") || "follow up"

    %{
      "kind" => "gmail_draft",
      "subject" => normalize_reply_subject(subject),
      "body" =>
        sanitize_text("""
        Hi #{recipient},

        #{String.capitalize(purpose)}. I do not want to overstate anything without the missing context, so the next step is for me to confirm the details and follow up with a clean answer.
        """)
    }
  end

  defp fallback_draft("slack", attrs) do
    purpose = read_string(attrs, "purpose") || "follow up"

    %{
      "kind" => "slack_draft",
      "text" =>
        sanitize_text(
          "#{String.capitalize(purpose)}. I need to confirm the remaining detail before I give a firm answer."
        )
    }
  end

  defp normalize_reply_subject("Re:" <> _ = subject), do: subject
  defp normalize_reply_subject("RE:" <> _ = subject), do: subject
  defp normalize_reply_subject(subject), do: "Re: #{subject}"

  defp voice_summary(voice_context, refresh_result) do
    %{
      status: Map.get(voice_context, "status"),
      channel: Map.get(voice_context, "channel"),
      memory_id: Map.get(voice_context, "memory_id"),
      refreshed: refresh_result
    }
  end

  defp required_string(attrs, key) when is_map(attrs) do
    attrs
    |> read_string(key)
    |> required_value("#{key} is required")
  end

  defp required_value(value, message) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, message}, else: {:ok, value}
  end

  defp required_value(_value, message), do: {:error, message}

  defp read_string(attrs, key) when is_map(attrs) do
    case fetch_key(attrs, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        value |> Atom.to_string() |> read_non_empty()

      _ ->
        nil
    end
  end

  defp read_non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp read_value(attrs, key, default) when is_map(attrs) do
    case fetch_key(attrs, key) do
      nil -> default
      value -> value
    end
  end

  defp fetch_key(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(attrs, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _other ->
            nil
        end)
    end
  end

  defp read_string_list(attrs, key) when is_map(attrs) do
    case read_value(attrs, key, []) do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      value when is_binary(value) ->
        [String.trim(value)]

      _ ->
        []
    end
  end

  defp read_integer(attrs, key, default) do
    case read_value(attrs, key, default) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> integer
          _ -> default
        end

      _ ->
        default
    end
  end

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_value), do: false

  defp non_empty(value) when is_binary(value), do: read_non_empty(value)
  defp non_empty(_value), do: nil

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp channel_label("gmail"), do: "email"
  defp channel_label("slack"), do: "Slack"
end
