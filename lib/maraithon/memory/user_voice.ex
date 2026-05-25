defmodule Maraithon.Memory.UserVoice do
  @moduledoc """
  Channel-specific user voice memory for draft generation.

  The profile is stored as a durable `Maraithon.Memory` item so every drafting
  surface can share the same channel-specific guidance.
  """

  alias Maraithon.Connectors.Slack
  alias Maraithon.Memory
  alias Maraithon.Memory.Item
  alias Maraithon.Tools.GmailHelpers
  alias Maraithon.Tools.SlackHelpers

  @channels ~w(gmail slack)
  @default_lookback_days 180
  @default_max_samples 40

  def channels, do: @channels

  def get_profile(user_id, channel) when is_binary(user_id) do
    with {:ok, channel} <- normalize_channel(channel) do
      user_id
      |> Memory.list_items(
        kind: "instruction",
        source_ref_type: "user_voice_profile",
        source_ref_id: channel,
        limit: 1
      )
      |> List.first()
      |> case do
        %Item{} = item -> {:ok, item}
        nil -> {:error, :voice_profile_not_found}
      end
    end
  end

  def get_profile(_user_id, _channel), do: {:error, :invalid_user}

  def prompt_context(user_id, channel) when is_binary(user_id) do
    case get_profile(user_id, channel) do
      {:ok, %Item{} = item} ->
        %{
          "status" => "available",
          "channel" => item.source_ref_id,
          "memory_id" => item.id,
          "summary" => item.summary,
          "content" => item.content,
          "confidence" => item.confidence,
          "updated_at" => datetime(item.updated_at),
          "metadata" => item.metadata || %{}
        }

      {:error, reason} ->
        %{
          "status" => "missing",
          "channel" => normalized_channel_or_raw(channel),
          "reason" => inspect(reason),
          "content" => ""
        }
    end
  end

  def prompt_context(_user_id, channel) do
    %{
      "status" => "missing",
      "channel" => normalized_channel_or_raw(channel),
      "reason" => "invalid_user",
      "content" => ""
    }
  end

  def refresh_from_connectors(user_id, channel, opts \\ [])

  def refresh_from_connectors(user_id, channel, opts) when is_binary(user_id) and is_list(opts) do
    with {:ok, channel} <- normalize_channel(channel),
         {:ok, samples, source_counts} <- collect_samples(user_id, channel, opts) do
      refresh_profile(user_id, channel,
        sample_texts: samples,
        source_counts: source_counts,
        llm_complete: Keyword.get(opts, :llm_complete)
      )
    end
  end

  def refresh_from_connectors(_user_id, _channel, _opts), do: {:error, :invalid_user}

  def refresh_profile(user_id, channel, opts \\ [])

  def refresh_profile(user_id, channel, opts) when is_binary(user_id) and is_list(opts) do
    with {:ok, channel} <- normalize_channel(channel),
         samples <- normalize_samples(Keyword.get(opts, :sample_texts, [])),
         true <- samples != [] || {:error, :insufficient_voice_samples},
         {:ok, profile} <- build_profile(channel, samples, opts) do
      write_profile(user_id, channel, profile, samples, Keyword.get(opts, :source_counts, %{}))
    end
  end

  def refresh_profile(_user_id, _channel, _opts), do: {:error, :invalid_user}

  def normalize_channel(channel) when is_binary(channel) do
    case channel |> String.trim() |> String.downcase() do
      value when value in ["gmail", "email"] -> {:ok, "gmail"}
      "slack" -> {:ok, "slack"}
      _ -> {:error, :unsupported_voice_channel}
    end
  end

  def normalize_channel(_channel), do: {:error, :unsupported_voice_channel}

  defp collect_samples(user_id, channel, opts) do
    explicit = normalize_samples(Keyword.get(opts, :sample_texts, []))

    if explicit == [] do
      collect_connector_samples(user_id, channel, opts)
    else
      {:ok, explicit, %{"explicit" => length(explicit)}}
    end
  end

  defp collect_connector_samples(user_id, "gmail", opts) do
    max_samples = max_samples(opts)
    query = Keyword.get(opts, :gmail_query) || "from:me newer_than:#{lookback_days(opts)}d"

    case GmailHelpers.list_messages(user_id,
           query: query,
           max_results: max_samples,
           label_ids: [],
           provider: Keyword.get(opts, :provider)
         ) do
      {:ok, messages} ->
        samples =
          messages
          |> Enum.map(&gmail_sample_text/1)
          |> normalize_samples()

        {:ok, samples, %{"gmail" => length(samples)}}

      {:error, reason} ->
        {:error, {:gmail_voice_scan_failed, reason}}
    end
  end

  defp collect_connector_samples(user_id, "slack", opts) do
    team_id = Keyword.get(opts, :team_id)
    slack_user_id = Keyword.get(opts, :slack_user_id)

    cond do
      blank?(team_id) ->
        {:error, :slack_team_id_required}

      true ->
        slack_samples(user_id, team_id, slack_user_id, opts)
    end
  end

  defp slack_samples(user_id, team_id, slack_user_id, opts) do
    query =
      Keyword.get(opts, :slack_query) ||
        "from:me after:#{Date.add(Date.utc_today(), -lookback_days(opts))}"

    with {:ok, token} <-
           SlackHelpers.resolve_access_token(user_id, team_id,
             token_preference: "user",
             slack_user_id: slack_user_id
           ),
         {:ok, response} <-
           Slack.search_messages(token.access_token, query,
             count: max_samples(opts),
             sort: "timestamp",
             sort_dir: "desc"
           ) do
      samples =
        response
        |> get_in(["messages", "matches"])
        |> normalize_list()
        |> Enum.map(&Map.get(&1, "text"))
        |> normalize_samples()

      {:ok, samples, %{"slack" => length(samples)}}
    else
      {:error, reason} -> {:error, {:slack_voice_scan_failed, reason}}
    end
  end

  defp build_profile(channel, samples, opts) do
    prompt = profile_prompt(channel, samples)

    case complete_profile(prompt, Keyword.get(opts, :llm_complete)) do
      {:ok, profile} -> {:ok, normalize_profile(profile, channel, samples)}
      {:error, reason} -> {:ok, fallback_profile(channel, samples, reason)}
    end
  end

  defp profile_prompt(channel, samples) do
    """
    Build a durable #{channel} writing voice profile for Maraithon drafts.

    Return ONLY valid JSON:
    {
      "summary":"short reusable summary",
      "content":"specific drafting guidance in the user's voice",
      "do":["style rules"],
      "avoid":["things to avoid"],
      "confidence":0.0
    }

    Rules:
    - Generalize durable voice patterns from the sent messages.
    - Do not quote private samples.
    - Keep guidance useful for future draft generation.
    - Include channel-specific differences.
    - Always include: no em dashes, no AI-ish filler, no assistant voice.

    Sent message samples JSON:
    #{Jason.encode!(samples)}
    """
  end

  defp complete_profile(_prompt, nil), do: {:error, :llm_unavailable}

  defp complete_profile(prompt, llm_complete) when is_function(llm_complete, 1) do
    case llm_complete.(prompt) do
      {:ok, response} -> decode_profile_response(response)
      {:error, reason} -> {:error, reason}
      other -> decode_profile_response(other)
    end
  end

  defp complete_profile(_prompt, _llm_complete), do: {:error, :llm_unavailable}

  defp decode_profile_response(%{content: content}) when is_binary(content),
    do: decode_json(content)

  defp decode_profile_response(%{"content" => content}) when is_binary(content),
    do: decode_json(content)

  defp decode_profile_response(content) when is_binary(content), do: decode_json(content)
  defp decode_profile_response(_response), do: {:error, :invalid_voice_profile_response}

  defp decode_json(content) when is_binary(content) do
    content
    |> strip_json_fence()
    |> Jason.decode()
    |> case do
      {:ok, %{} = profile} -> {:ok, profile}
      _ -> {:error, :invalid_json}
    end
  end

  defp normalize_profile(profile, channel, samples) do
    content = read_string(profile, "content") || fallback_content(channel, samples)
    summary = read_string(profile, "summary") || String.slice(content, 0, 240)

    %{
      "summary" => summary,
      "content" => content,
      "do" => read_string_list(profile, "do"),
      "avoid" => read_string_list(profile, "avoid") ++ ["em dashes", "AI-ish filler"],
      "confidence" => read_float(profile, "confidence", 0.72)
    }
  end

  defp fallback_profile(channel, samples, reason) do
    content = fallback_content(channel, samples)

    %{
      "summary" =>
        "Draft in a concise, direct #{channel} voice based on recent sent-message samples.",
      "content" => content,
      "do" => ["be concise", "sound like the user", "use source-grounded specifics"],
      "avoid" => ["em dashes", "AI-ish filler", "assistant voice"],
      "confidence" => 0.55,
      "fallback_reason" => inspect(reason)
    }
  end

  defp fallback_content(channel, samples) do
    avg_length =
      samples
      |> Enum.map(&String.length/1)
      |> case do
        [] -> nil
        lengths -> round(Enum.sum(lengths) / length(lengths))
      end

    length_guidance =
      cond do
        is_nil(avg_length) -> "Keep drafts compact."
        avg_length < 160 -> "Prefer short, plain #{channel} replies."
        avg_length < 500 -> "Use concise paragraphs with only necessary detail."
        true -> "Use clear structure but keep the draft tighter than the source context."
      end

    "#{length_guidance} Write as the user, not as Maraithon. Avoid em dashes, vague filler, and assistant-like phrasing."
  end

  defp write_profile(user_id, channel, profile, samples, source_counts) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Memory.write(
      user_id,
      %{
        "kind" => "instruction",
        "scope" => "user",
        "title" => "User #{channel_label(channel)} voice profile",
        "content" => profile["content"],
        "summary" => profile["summary"],
        "source" => "user_voice",
        "source_ref_type" => "user_voice_profile",
        "source_ref_id" => channel,
        "author_type" => "model",
        "tags" => ["user_voice", "drafts", channel],
        "importance" => 84,
        "confidence" => profile["confidence"],
        "dedupe_key" => "user_voice:#{channel}",
        "metadata" => %{
          "channel" => channel,
          "sample_count" => length(samples),
          "source_counts" => source_counts,
          "refreshed_at" => DateTime.to_iso8601(now),
          "do" => profile["do"] || [],
          "avoid" => profile["avoid"] || [],
          "sanitizer_rules" => ["no_em_dash", "no_ai_filler"],
          "fallback_reason" => profile["fallback_reason"]
        }
      },
      source: "user_voice"
    )
  end

  defp gmail_sample_text(message) when is_map(message) do
    [
      read_string(message, :subject) || read_string(message, "subject"),
      read_string(message, :text_body) || read_string(message, "text_body"),
      read_string(message, :snippet) || read_string(message, "snippet")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp normalize_samples(samples) when is_list(samples) do
    samples
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.map(&String.slice(&1, 0, 2_000))
    |> Enum.uniq()
    |> Enum.take(@default_max_samples)
  end

  defp normalize_samples(_samples), do: []

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end
  end

  defp read_string_list(map, key) when is_map(map) do
    case Map.get(map, key) do
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

  defp read_float(map, key, default) when is_map(map) do
    case Map.get(map, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      _ -> default
    end
  end

  defp strip_json_fence(content) do
    content
    |> String.trim()
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end

  defp lookback_days(opts) do
    opts
    |> Keyword.get(:lookback_days, @default_lookback_days)
    |> normalize_integer(@default_lookback_days, 7, 3650)
  end

  defp max_samples(opts) do
    opts
    |> Keyword.get(:max_samples, @default_max_samples)
    |> normalize_integer(@default_max_samples, 1, 100)
  end

  defp normalize_integer(value, _default, min_value, max_value) when is_integer(value) do
    value |> max(min_value) |> min(max_value)
  end

  defp normalize_integer(_value, default, _min_value, _max_value), do: default

  defp channel_label("gmail"), do: "email"
  defp channel_label("slack"), do: "Slack"

  defp normalized_channel_or_raw(channel) do
    case normalize_channel(channel) do
      {:ok, normalized} -> normalized
      {:error, _} when is_binary(channel) -> channel
      {:error, _} -> "unknown"
    end
  end

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(_), do: nil

  defp blank?(value) when value in [nil, "", []], do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
