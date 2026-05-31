defmodule Maraithon.Briefs do
  @moduledoc """
  Persistence and Telegram delivery for operator briefing messages.
  """

  import Ecto.Query

  alias Maraithon.Briefs.Brief
  alias Maraithon.AppUrl
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Telegram
  alias Maraithon.DeliveryErrorCopy
  alias Maraithon.Repo
  alias Maraithon.Redaction
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.BriefTodoReview
  alias Maraithon.Todos
  alias Maraithon.Todos.AttentionRanker
  alias Maraithon.Todos.UserFacingCopy
  alias Maraithon.Travel

  require Logger

  @brief_title_fallback "Chief of staff brief"
  @brief_summary_default "No priority follow-up surfaced in the checked sources."
  @brief_body_default "No checked decision needs your attention right now."
  @brief_summary_fallback "Maraithon kept only checked next steps."
  @brief_body_fallback "No verified recommendation was safe to send yet."
  @internal_brief_markers [
    "<redacted",
    "=>",
    "{",
    "}",
    "llm_",
    "model_name",
    "model_provider",
    "model_response",
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
    "source_health",
    "quality_verification",
    "generation_mode",
    "assistant_behavior",
    "agent_behavior",
    "source_backed",
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
  @internal_brief_patterns [
    ~r/\b(?:confidence|quality|priority|urgency|relevance|interrupt)_score\s*[:=]/,
    ~r/\bscore\s*[:=]\s*\d/,
    ~r/\bthreshold\s*[:=]\s*\d/,
    ~r/\b(?:token|secret|password|api[_-]?key|access[_-]?token|refresh[_-]?token)\s*[:=]/,
    ~r/\b(?:authorization|bearer)\b/
  ]

  def record_many(user_id, agent_id, briefs)
      when is_binary(user_id) and is_binary(agent_id) and is_list(briefs) do
    items =
      briefs
      |> Enum.map(&record(user_id, agent_id, &1))
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, brief} -> brief end)

    {:ok, items}
  end

  def record(user_id, agent_id, attrs)
      when is_binary(user_id) and is_binary(agent_id) and is_map(attrs) do
    normalized = normalize_attrs(attrs, user_id, agent_id)

    case Repo.get_by(Brief, user_id: user_id, dedupe_key: normalized["dedupe_key"]) do
      nil ->
        %Brief{}
        |> Brief.changeset(normalized)
        |> Repo.insert()

      %Brief{} = brief ->
        update_attrs =
          normalized
          |> Map.drop(["user_id", "agent_id", "dedupe_key"])
          |> Map.put("status", preserve_status(brief.status))
          |> Map.put(
            "provider_message_id",
            if(brief.status == "sent", do: brief.provider_message_id)
          )
          |> Map.put("sent_at", if(brief.status == "sent", do: brief.sent_at))
          |> Map.put(
            "error_message",
            normalized["error_message"] || if(brief.status == "failed", do: brief.error_message)
          )

        brief
        |> Brief.changeset(update_attrs)
        |> Repo.update()
    end
  end

  def list_pending(limit \\ 20) when is_integer(limit) and limit > 0 do
    terminal_delivery_errors = DeliveryErrorCopy.terminal_storage_messages()

    Brief
    |> where(
      [b],
      b.status == "pending" or
        (b.status == "failed" and
           (is_nil(b.error_message) or b.error_message not in ^terminal_delivery_errors))
    )
    |> order_by([b], asc: b.scheduled_for, asc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_recent_for_user(user_id, opts \\ []) when is_binary(user_id) do
    limit = Keyword.get(opts, :limit, 20)

    Brief
    |> where([b], b.user_id == ^user_id)
    |> order_by([b], desc: b.scheduled_for, desc: b.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def exists?(user_id, dedupe_key) when is_binary(user_id) and is_binary(dedupe_key) do
    Brief
    |> where([b], b.user_id == ^user_id and b.dedupe_key == ^dedupe_key)
    |> Repo.exists?()
  end

  def attach_linked_todos(%Brief{} = brief, todos_or_ids) do
    linked_todo_ids =
      todos_or_ids
      |> List.wrap()
      |> Enum.map(&todo_id/1)
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    metadata =
      brief.metadata
      |> Kernel.||(%{})
      |> Map.merge(%{
        "linked_todo_ids" => linked_todo_ids,
        "todo_digest" => linked_todo_ids != [],
        "todo_digest_count" => length(linked_todo_ids)
      })

    brief
    |> Ecto.Changeset.change(%{metadata: metadata})
    |> Repo.update()
  end

  def dispatch_telegram_batch(opts \\ []) do
    if telegram_module().configured?() do
      batch_size = Keyword.get(opts, :batch_size, 10)

      list_pending(batch_size)
      |> Enum.reduce(%{sent: 0, failed: 0, skipped: 0}, fn brief, acc ->
        case send_brief(brief) do
          :ok -> %{acc | sent: acc.sent + 1}
          :skip -> %{acc | skipped: acc.skipped + 1}
          {:error, _reason} -> %{acc | failed: acc.failed + 1}
        end
      end)
    else
      %{sent: 0, failed: 0, skipped: 0}
    end
  end

  def send_brief(%Brief{} = brief) do
    case TelegramAssistant.deliver_brief(brief) do
      :ok ->
        Brief
        |> Repo.get!(brief.id)
        |> maybe_mark_travel_delivered()

        :ok

      {:fallback, :disabled} ->
        case telegram_destination(brief.user_id) do
          nil ->
            :skip

          destination ->
            case send_fallback_brief(brief, destination) do
              {:ok, updated_brief} ->
                maybe_mark_travel_delivered(updated_brief)
                :ok

              {:error, reason} ->
                Logger.warning("Failed to send Telegram brief",
                  reason: inspect(reason),
                  brief_id: brief.id
                )

                brief
                |> Ecto.Changeset.change(%{
                  status: "failed",
                  error_message: DeliveryErrorCopy.storage_message(reason)
                })
                |> Repo.update()

                {:error, reason}
            end
        end

      {:error, reason} ->
        Logger.warning("Failed to broker Telegram brief",
          reason: inspect(reason),
          brief_id: brief.id
        )

        {:error, reason}
    end
  end

  def telegram_payload(%Brief{} = brief) do
    %{
      text: render_telegram_text(brief),
      reply_markup: brief_reply_markup(brief)
    }
  end

  def todo_digest_telegram_payload(%Brief{} = brief, todos \\ nil) do
    todos = todos || todo_digest_todos(brief)

    %{
      text: render_todo_digest_telegram_text(brief, todos),
      reply_markup: brief_reply_markup(brief)
    }
  end

  def mark_sent(%Brief{} = brief, message_id \\ nil) do
    mark_fallback_sent(brief, normalize_message_id(message_id))
  end

  def todo_digest_brief?(%Brief{metadata: metadata}) when is_map(metadata) do
    metadata
    |> fetch_attr("linked_todo_ids")
    |> Kernel.||([])
    |> case do
      ids when is_list(ids) -> ids != []
      _ -> false
    end
  end

  def todo_digest_brief?(_brief), do: false

  def todo_digest_todos(%Brief{} = brief) do
    todo_ids =
      brief.metadata
      |> fetch_attr("linked_todo_ids")
      |> Kernel.||([])
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq()

    brief.user_id
    |> Todos.list_by_ids(todo_ids, statuses: ["open", "snoozed"], open_due_only: true)
    |> order_todo_digest_items(brief)
  end

  def todo_digest_intro_text(%Brief{} = brief, todos \\ nil) do
    todos = todos || todo_digest_todos(brief)
    greeting = greeting_line(brief)
    {new_today_count, still_open_count} = todo_digest_counts(brief, todos)

    detail_line =
      case todos do
        [] ->
          "No open work needs a decision right now."

        _ ->
          cond do
            new_today_count > 0 and still_open_count > 0 ->
              "#{new_today_count} new today. #{still_open_count} carried over from earlier."

            new_today_count > 0 ->
              "#{new_today_count} new today."

            still_open_count > 0 ->
              "#{still_open_count} carried over from earlier."

            true ->
              "No open work needs a decision right now."
          end
      end

    if todos == [] do
      """
      #{greeting}

      #{detail_line}
      """
      |> String.trim()
    else
      """
      #{greeting}

      #{detail_line}
      Best next move: #{todo_digest_next_move(todos)}
      """
      |> String.trim()
    end
  end

  def todo_digest_prefix_text(%Brief{} = _brief, _todo), do: nil

  defp normalize_attrs(attrs, user_id, agent_id) do
    %{
      "user_id" => user_id,
      "agent_id" => agent_id,
      "cadence" => read_string(attrs, "cadence", "morning"),
      "title" => read_string(attrs, "title", @brief_title_fallback),
      "summary" => read_string(attrs, "summary", @brief_summary_default),
      "body" => read_string(attrs, "body", @brief_body_default),
      "status" => read_string(attrs, "status", "pending"),
      "scheduled_for" => read_datetime(attrs, "scheduled_for") || DateTime.utc_now(),
      "dedupe_key" => read_string(attrs, "dedupe_key", Ecto.UUID.generate()),
      "error_message" => read_string(attrs, "error_message", nil),
      "metadata" => read_map(attrs, "metadata")
    }
  end

  defp preserve_status("sent"), do: "sent"
  defp preserve_status(_), do: "pending"

  defp telegram_destination(user_id) do
    ConnectedAccounts.telegram_destination(user_id)
  end

  defp render_telegram_text(%Brief{} = brief) do
    if travel_brief?(brief) do
      brief.body
      |> public_brief_body()
      |> Maraithon.TelegramMarkdown.to_html()
    else
      cadence_label = cadence_label(brief.cadence)
      title = public_brief_title(brief.title)
      summary = public_brief_summary(brief.summary)
      body = public_brief_body(brief.body)

      """
      <b>#{safe(cadence_label)}</b>
      <b>#{safe(title)}</b>

      #{Maraithon.TelegramMarkdown.to_html(summary)}

      #{Maraithon.TelegramMarkdown.to_html(body)}
      """
      |> String.trim()
    end
  end

  defp render_todo_digest_telegram_text(%Brief{} = brief, todos) do
    cadence_label = cadence_label(brief.cadence)
    intro = todo_digest_intro_text(brief, todos)

    """
    <b>#{safe(cadence_label)}</b>
    <b>#{safe(public_brief_title(brief.title))}</b>

    #{Maraithon.TelegramMarkdown.to_html(intro)}
    """
    |> String.trim()
  end

  defp send_fallback_brief(%Brief{} = brief, destination) do
    payload = telegram_payload(brief)

    case telegram_module().send_message(destination, payload.text,
           parse_mode: "HTML",
           reply_markup: payload.reply_markup
         ) do
      {:ok, result} ->
        mark_fallback_sent(brief, read_message_id(result))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_fallback_sent(%Brief{} = brief, message_id) do
    brief
    |> Ecto.Changeset.change(%{
      status: "sent",
      sent_at: DateTime.utc_now(),
      provider_message_id: normalize_message_id(message_id),
      error_message: nil
    })
    |> Repo.update()
  end

  defp brief_reply_markup(%Brief{} = brief) do
    if travel_brief?(brief) or failed_brief?(brief) do
      nil
    else
      buttons =
        []
        |> maybe_add_list_todos_button(brief)
        |> Kernel.++([
          [
            %{"text" => "Open Maraithon", "url" => AppUrl.url("/dashboard")}
          ]
        ])

      case brief.metadata do
        %{"agent_behavior" => behavior} when is_binary(behavior) and behavior != "" ->
          %{
            "inline_keyboard" =>
              buttons ++
                [
                  [
                    %{
                      "text" => "Adjust Briefing",
                      "url" => AppUrl.url("/agents/new?behavior=#{URI.encode_www_form(behavior)}")
                    }
                  ]
                ]
          }

        _ ->
          %{"inline_keyboard" => buttons}
      end
    end
  end

  defp maybe_add_list_todos_button(rows, %Brief{} = brief) do
    case BriefTodoReview.brief_buttons(brief) do
      [] -> rows
      buttons -> rows ++ [buttons]
    end
  end

  defp cadence_label("morning"), do: "Morning brief"
  defp cadence_label("check_in"), do: "Chief of staff check-in"
  defp cadence_label("end_of_day"), do: "End-of-day review"
  defp cadence_label("weekly_review"), do: "Weekly review"
  defp cadence_label("weekend_scope"), do: "Weekend project check"
  defp cadence_label("holiday_radar"), do: "Holiday radar"
  defp cadence_label("commitment_tracker"), do: "Commitment tracker"
  defp cadence_label("travel_prep"), do: "Travel prep"
  defp cadence_label("travel_update"), do: "Travel update"
  defp cadence_label(other), do: other

  # A checked-source fallback is still a usable brief. It can carry diagnostic
  # context for operators without losing the executive's follow-up actions.
  defp failed_brief?(%Brief{} = brief) do
    case read_string(brief.metadata || %{}, "generation_mode", nil) do
      "source_fallback" -> false
      "error" -> true
      _ -> present?(brief.error_message)
    end
  end

  defp travel_brief?(%Brief{metadata: %{"brief_type" => type}})
       when type in ["travel_prep", "travel_update"],
       do: true

  defp travel_brief?(%Brief{cadence: cadence}) when cadence in ["travel_prep", "travel_update"],
    do: true

  defp travel_brief?(_brief), do: false

  defp public_brief_title(value), do: public_brief_fragment(value, @brief_title_fallback)

  defp public_brief_summary(value), do: public_brief_fragment(value, @brief_summary_fallback)

  defp public_brief_body(value) do
    value
    |> brief_text_value()
    |> String.split("\n", trim: false)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&unsafe_brief_line?/1)
    |> Enum.map(&public_brief_line/1)
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> @brief_body_fallback
      text -> text
    end
  end

  defp public_brief_fragment(value, fallback) do
    text = brief_text_value(value)

    cond do
      text == "" ->
        fallback

      unsafe_public_text?(text) ->
        fallback

      true ->
        redacted = Redaction.redact_string(text)

        if unsafe_public_text?(redacted) do
          fallback
        else
          product_brief_text(redacted)
        end
    end
  end

  defp unsafe_brief_line?(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        false

      unsafe_public_text?(trimmed) ->
        true

      true ->
        trimmed
        |> Redaction.redact_string()
        |> unsafe_public_text?()
    end
  end

  defp unsafe_public_text?(value) when is_binary(value) do
    lower = String.downcase(value)

    Enum.any?(@internal_brief_markers, &String.contains?(lower, &1)) or
      Enum.any?(@internal_brief_patterns, &Regex.match?(&1, lower))
  end

  defp unsafe_public_text?(_value), do: true

  defp public_brief_line(line) when is_binary(line) do
    line
    |> Redaction.redact_string()
    |> product_brief_text()
  end

  defp brief_text_value(value) when is_binary(value), do: String.trim(value)
  defp brief_text_value(nil), do: ""
  defp brief_text_value(value), do: value |> inspect(limit: 10) |> String.trim()

  defp product_brief_text(value) when is_binary(value) do
    value
    |> UserFacingCopy.polish_text()
    |> String.replace(
      ~r/^No clear follow-up needs your attention from the connected sources yet\.?$/i,
      @brief_summary_default
    )
    |> String.replace(~r/\bCRM context\b/i, "relationship context")
  end

  defp maybe_mark_travel_delivered(%Brief{} = brief) do
    _ = Travel.note_brief_delivered(brief)
    :ok
  end

  defp safe(value) when is_binary(value),
    do: Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()

  defp safe(value), do: value |> to_string() |> safe()

  defp read_message_id(%{"message_id" => value}) when is_integer(value),
    do: Integer.to_string(value)

  defp read_message_id(%{"message_id" => value}) when is_binary(value), do: value
  defp read_message_id(_), do: nil

  defp normalize_message_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_message_id(value) when is_binary(value), do: value
  defp normalize_message_id(_value), do: nil

  def order_todo_digest_items(todos, brief) do
    todos
    |> AttentionRanker.sort()
    |> Enum.with_index()
    |> Enum.sort_by(fn {todo, index} ->
      profile = AttentionRanker.profile(todo)
      {todo_digest_bucket_rank(brief, todo), profile["bucket_rank"], -profile["score"], index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp todo_digest_counts(brief, todos) do
    Enum.reduce(todos, {0, 0}, fn todo, {new_today, still_open} ->
      case todo_digest_bucket(brief, todo) do
        :new_today -> {new_today + 1, still_open}
        :still_open -> {new_today, still_open + 1}
      end
    end)
  end

  defp todo_digest_bucket_rank(brief, todo) do
    case todo_digest_bucket(brief, todo) do
      :new_today -> 0
      :still_open -> 1
    end
  end

  defp todo_digest_next_move([todo | _todos]) do
    focus = todo |> todo_digest_focus() |> todo_digest_sentence()

    "#{focus} Then triage the rest: close resolved items, keep what still needs you, and defer anything that can wait."
  end

  defp todo_digest_next_move(_todos), do: "Nothing needs a decision right now."

  defp todo_digest_sentence(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> "Review the first open item."
      Regex.match?(~r/[.!?]\z/u, value) -> value
      true -> value <> "."
    end
  end

  defp todo_digest_focus(todo) do
    title =
      todo
      |> read_string("title", "the first open item")
      |> UserFacingCopy.polish_text()

    next_action =
      case read_string(todo, "next_action", nil) do
        value when is_binary(value) -> UserFacingCopy.polish_text(value)
        _other -> nil
      end

    cond do
      is_nil(next_action) -> title
      same_digest_text?(next_action, title) -> title
      generic_digest_action?(next_action) -> title
      true -> next_action
    end
  end

  defp same_digest_text?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp same_digest_text?(_left, _right), do: false

  defp generic_digest_action?(value) when is_binary(value) do
    Regex.match?(~r/^(reply|respond)\s+in[-\s]?thread\b/i, String.trim(value))
  end

  defp generic_digest_action?(_value), do: false

  defp todo_digest_bucket(%Brief{} = brief, todo) do
    reference_date = todo_digest_reference_date(brief)

    occurred_at =
      case todo do
        %{source_occurred_at: %DateTime{} = source_occurred_at} ->
          source_occurred_at

        %{inserted_at: %DateTime{} = inserted_at} ->
          inserted_at

        _ ->
          nil
      end

    if is_struct(occurred_at, DateTime) and
         Date.compare(local_date(occurred_at, brief), reference_date) == :eq do
      :new_today
    else
      :still_open
    end
  end

  defp todo_digest_reference_date(%Brief{} = brief) do
    (brief.scheduled_for || brief.inserted_at || DateTime.utc_now())
    |> local_date(brief)
  end

  defp local_date(datetime, %Brief{} = brief) do
    offset_hours = timezone_offset_hours(brief.metadata || %{})

    datetime
    |> DateTime.add(offset_hours * 3600, :second)
    |> DateTime.to_date()
  end

  defp timezone_offset_hours(metadata) when is_map(metadata) do
    case Map.get(metadata, "timezone_offset_hours") do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp greeting_line(%Brief{} = brief) do
    body =
      case normalize_cadence(brief.cadence) do
        "end_of_day" -> "here's the open work still worth a decision before the day closes."
        "morning" -> "here's the open work that needs a decision today."
        "weekly_review" -> "here's the open work still worth deciding this week."
        _ -> "here's the open work that needs review today."
      end

    case greeting_name(brief.user_id) do
      nil -> "Hey, #{body}"
      name -> "Hey #{name}, #{body}"
    end
  end

  defp greeting_name(user_id) when is_binary(user_id) do
    case ConnectedAccounts.get(user_id, "telegram") do
      %{metadata: metadata} when is_map(metadata) ->
        metadata
        |> greeting_candidates(user_id)
        |> Enum.find(&present?/1)

      _ ->
        email_name(user_id)
    end
  end

  defp greeting_name(_user_id), do: nil

  defp greeting_candidates(metadata, user_id) do
    [
      normalize_name(Map.get(metadata, "first_name")),
      normalize_name(Map.get(metadata, "name")),
      normalize_name(Map.get(metadata, "username")),
      email_name(user_id)
    ]
  end

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" ->
        nil

      trimmed ->
        trimmed
        |> String.split(~r/[\s._-]+/u)
        |> List.first()
        |> case do
          nil -> nil
          part -> String.capitalize(part)
        end
    end
  end

  defp normalize_name(_value), do: nil

  defp email_name(user_id) when is_binary(user_id) do
    user_id
    |> String.split("@")
    |> List.first()
    |> normalize_name()
  end

  defp email_name(_user_id), do: nil

  defp normalize_cadence(value) when is_binary(value), do: value
  defp normalize_cadence(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_cadence(_value), do: nil

  defp todo_id(%{id: id}) when is_binary(id), do: id
  defp todo_id(%{"id" => id}) when is_binary(id), do: id
  defp todo_id(id) when is_binary(id), do: id
  defp todo_id(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp telegram_module do
    Application.get_env(:maraithon, :briefs, [])
    |> Keyword.get(:telegram_module, Telegram)
  end

  defp read_string(map, key, default) when is_map(map) do
    case fetch_attr(map, key) do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: default, else: trimmed

      _ ->
        default
    end
  end

  defp read_map(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_datetime(map, key) when is_map(map) do
    case fetch_attr(map, key) do
      %DateTime{} = value ->
        value

      %NaiveDateTime{} = value ->
        DateTime.from_naive!(value, "Etc/UTC")

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_attr(%_{} = struct, key) when is_binary(key) do
    struct
    |> Map.from_struct()
    |> fetch_attr(key)
  end

  defp fetch_attr(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end
end
