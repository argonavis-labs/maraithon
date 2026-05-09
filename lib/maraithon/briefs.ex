defmodule Maraithon.Briefs do
  @moduledoc """
  Persistence and Telegram delivery for operator briefing messages.
  """

  import Ecto.Query

  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Telegram
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.TodoActions
  alias Maraithon.Todos
  alias Maraithon.Travel
  alias MaraithonWeb.Endpoint

  require Logger

  @open_statuses ["pending", "failed"]

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
    Brief
    |> where([b], b.status in ^@open_statuses)
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
                  error_message: inspect(reason)
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
      cond do
        new_today_count > 0 and still_open_count > 0 ->
          "#{new_today_count} new today. #{still_open_count} still open from earlier."

        new_today_count > 0 ->
          "#{new_today_count} new today."

        still_open_count > 0 ->
          "#{still_open_count} still open from earlier."

        true ->
          "Nothing newly urgent surfaced."
      end

    """
    #{greeting}

    #{detail_line}
    I'm sending them one by one so you can mark them done or say not interested.
    """
    |> String.trim()
  end

  def todo_digest_prefix_text(%Brief{} = brief, todo) do
    case {normalize_cadence(brief.cadence), todo_digest_bucket(brief, todo)} do
      {"end_of_day", :new_today} -> "<b>Opened Today</b>"
      {"end_of_day", _} -> "<b>Still Open Tonight</b>"
      {"morning", :new_today} -> "<b>For Today</b>"
      {"morning", _} -> "<b>Carried Over</b>"
      {_, :new_today} -> "<b>New Today</b>"
      _ -> "<b>Still Open</b>"
    end
  end

  defp normalize_attrs(attrs, user_id, agent_id) do
    %{
      "user_id" => user_id,
      "agent_id" => agent_id,
      "cadence" => read_string(attrs, "cadence", "morning"),
      "title" => read_string(attrs, "title", "Chief of staff brief"),
      "summary" => read_string(attrs, "summary", "Review the latest loop summary."),
      "body" =>
        read_string(attrs, "body", "Open Maraithon to review the latest follow-through summary."),
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
    case ConnectedAccounts.get(user_id, "telegram") do
      %{status: "connected", external_account_id: destination}
      when is_binary(destination) and destination != "" ->
        destination

      %{status: "connected", metadata: %{"chat_id" => destination}}
      when is_binary(destination) and destination != "" ->
        destination

      _ ->
        nil
    end
  end

  defp render_telegram_text(%Brief{} = brief) do
    if travel_brief?(brief) do
      Maraithon.TelegramMarkdown.to_html(brief.body)
    else
      cadence_label = cadence_label(brief.cadence)

      """
      <b>#{safe(cadence_label)}</b>
      <b>#{safe(brief.title)}</b>

      #{Maraithon.TelegramMarkdown.to_html(brief.summary)}

      #{Maraithon.TelegramMarkdown.to_html(brief.body)}
      """
      |> String.trim()
    end
  end

  defp send_fallback_brief(%Brief{} = brief, destination) do
    todos =
      if todo_digest_brief?(brief) do
        todo_digest_todos(brief)
      else
        []
      end

    if todos == [] do
      payload = telegram_payload(brief)

      case telegram_module().send_message(
             destination,
             payload.text,
             parse_mode: "HTML",
             reply_markup: payload.reply_markup
           ) do
        {:ok, result} ->
          mark_fallback_sent(brief, read_message_id(result))

        {:error, reason} ->
          {:error, reason}
      end
    else
      intro_text = todo_digest_intro_text(brief, todos)

      with {:ok, result} <-
             telegram_module().send_message(destination, intro_text, parse_mode: "HTML"),
           :ok <- send_fallback_todo_messages(destination, brief, todos) do
        mark_fallback_sent(brief, read_message_id(result))
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp mark_fallback_sent(%Brief{} = brief, message_id) do
    brief
    |> Ecto.Changeset.change(%{
      status: "sent",
      sent_at: DateTime.utc_now(),
      provider_message_id: message_id,
      error_message: nil
    })
    |> Repo.update()
  end

  defp send_fallback_todo_messages(destination, brief, todos) do
    Enum.reduce_while(todos, :ok, fn todo, :ok ->
      payload =
        TodoActions.telegram_payload(todo,
          prefix_text: todo_digest_prefix_text(brief, todo)
        )

      case telegram_module().send_message(destination, payload.text,
             parse_mode: "HTML",
             reply_markup: payload.reply_markup
           ) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp brief_reply_markup(%Brief{} = brief) do
    if travel_brief?(brief) do
      nil
    else
      buttons = [
        [
          %{"text" => "Open Dashboard", "url" => "#{Endpoint.url()}/dashboard"}
        ]
      ]

      case brief.metadata do
        %{"agent_behavior" => behavior} when is_binary(behavior) and behavior != "" ->
          %{
            "inline_keyboard" =>
              buttons ++
                [
                  [
                    %{
                      "text" => "Tune Agent",
                      "url" =>
                        "#{Endpoint.url()}/agents/new?behavior=#{URI.encode_www_form(behavior)}"
                    }
                  ]
                ]
          }

        _ ->
          %{"inline_keyboard" => buttons}
      end
    end
  end

  defp cadence_label("morning"), do: "Morning brief"
  defp cadence_label("check_in"), do: "Chief of staff check-in"
  defp cadence_label("end_of_day"), do: "End-of-day debt"
  defp cadence_label("weekly_review"), do: "Weekly review"
  defp cadence_label("weekend_scope"), do: "Weekend project check"
  defp cadence_label("holiday_radar"), do: "Holiday radar"
  defp cadence_label("travel_prep"), do: "Travel prep"
  defp cadence_label("travel_update"), do: "Travel update"
  defp cadence_label(other), do: other

  defp travel_brief?(%Brief{metadata: %{"brief_type" => type}})
       when type in ["travel_prep", "travel_update"],
       do: true

  defp travel_brief?(%Brief{cadence: cadence}) when cadence in ["travel_prep", "travel_update"],
    do: true

  defp travel_brief?(_brief), do: false

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

  defp order_todo_digest_items(todos, brief) do
    todos
    |> Enum.with_index()
    |> Enum.sort_by(fn {todo, index} ->
      {todo_digest_bucket_rank(brief, todo), index}
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
        "end_of_day" -> "these still need movement tonight."
        "morning" -> "here's the full list for today."
        "weekly_review" -> "here's everything still open this week."
        _ -> "checking on these today."
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
