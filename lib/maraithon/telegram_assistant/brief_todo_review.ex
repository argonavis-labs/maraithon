defmodule Maraithon.TelegramAssistant.BriefTodoReview do
  @moduledoc """
  Drives one-at-a-time Telegram review sessions for todos linked to a brief.
  """

  import Ecto.Query

  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.TodoActions
  alias Maraithon.TelegramResponder
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @callback_prefix "brftd"
  @review_key "todo_review"
  @open_statuses ["open", "snoozed"]

  def reviewable?(%Brief{} = brief), do: linked_todo_ids(brief) != []
  def reviewable?(_brief), do: false

  def list_button(%Brief{} = brief) do
    if reviewable?(brief) do
      %{"text" => "List Todos", "callback_data" => callback_data(brief.id, "start")}
    end
  end

  def list_button(_brief), do: nil

  def handle_callback(data) when is_map(data) do
    case parse_callback(read_string(data, "data", "")) do
      {:ok, brief_id, "start"} ->
        start_review(data, brief_id)

      {:error, :invalid_callback} ->
        :ignored
    end
  end

  def handle_callback(_data), do: :ignored

  def after_todo_action(user_id, chat_id, %Todo{} = todo, action)
      when is_binary(user_id) and is_binary(chat_id) and is_binary(action) do
    case active_review_for(user_id, chat_id, todo.id) do
      %Brief{} = brief -> advance_after_action(brief, chat_id, todo, action)
      nil -> :ok
    end
  end

  def after_todo_action(_user_id, _chat_id, _todo, _action), do: :ok

  defp start_review(data, brief_id) do
    chat_id = read_id_string(data, "chat_id")
    callback_id = read_string(data, "callback_id")

    with chat_id when is_binary(chat_id) <- chat_id,
         %{user_id: user_id} <-
           ConnectedAccounts.get_connected_by_external_account("telegram", chat_id),
         %Brief{} = brief <- Repo.get(Brief, brief_id),
         true <- brief.user_id == user_id do
      todos = review_todos(brief)

      review =
        %{
          "status" => "active",
          "chat_id" => chat_id,
          "started_at" => now_iso8601(),
          "todo_ids" => Enum.map(todos, & &1.id),
          "reviewed" => []
        }

      brief = put_review!(brief, review)

      case next_unreviewed_open_todo(brief) do
        {%Todo{} = todo, position, total} ->
          brief = set_current_todo!(brief, todo.id)
          maybe_answer_callback(callback_id, "Sending #{position}/#{total}")
          send_review_todo(chat_id, brief, todo, position, total)

        nil ->
          brief = complete_review!(brief)
          maybe_answer_callback(callback_id, "No open todos")
          send_summary(chat_id, brief)
      end

      :ok
    else
      {:error, :invalid_callback} ->
        :ignored

      _ ->
        maybe_answer_callback(callback_id, "I couldn't open that todo list.")
        :ok
    end
  end

  defp advance_after_action(%Brief{} = brief, chat_id, %Todo{} = todo, action) do
    brief =
      brief
      |> append_reviewed_action!(todo, action)
      |> clear_current_todo!()

    case next_unreviewed_open_todo(brief) do
      {%Todo{} = next_todo, position, total} ->
        brief = set_current_todo!(brief, next_todo.id)
        send_review_todo(chat_id, brief, next_todo, position, total)

      nil ->
        brief = complete_review!(brief)
        send_summary(chat_id, brief)
    end

    :ok
  end

  defp active_review_for(user_id, chat_id, todo_id) do
    Brief
    |> where([brief], brief.user_id == ^user_id)
    |> order_by([brief], desc: brief.updated_at, desc: brief.inserted_at)
    |> limit(30)
    |> Repo.all()
    |> Enum.find(fn brief ->
      review = review_metadata(brief)

      read_string(review, "status") == "active" and
        read_string(review, "chat_id") == chat_id and
        read_string(review, "current_todo_id") == todo_id
    end)
  end

  defp send_review_todo(chat_id, %Brief{} = _brief, %Todo{} = todo, position, total) do
    payload = TodoActions.telegram_payload(todo, prefix_text: "Todo #{position} of #{total}")

    case TelegramResponder.send(chat_id, payload.text,
           parse_mode: "HTML",
           reply_markup: payload.reply_markup
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp send_summary(chat_id, %Brief{} = brief) do
    text = summary_text(brief)

    case TelegramResponder.send(chat_id, text, parse_mode: "HTML") do
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp summary_text(%Brief{} = brief) do
    todos = all_review_todos(brief)
    done = Enum.filter(todos, &(&1.status == "done"))
    dismissed = Enum.filter(todos, &(&1.status == "dismissed"))
    open = Enum.filter(todos, &(&1.status in @open_statuses))
    reviewed_count = length(reviewed_entries(brief))

    still_open =
      case open do
        [] ->
          "Still open: 0"

        todos ->
          lines =
            todos
            |> Enum.take(6)
            |> Enum.map(fn todo -> "• #{safe(todo.title)}" end)
            |> Enum.join("\n")

          extra =
            if length(todos) > 6 do
              "\n• #{length(todos) - 6} more still open"
            else
              ""
            end

          "Still open: #{length(todos)}\n#{lines}#{extra}"
      end

    """
    <b>Todo review complete</b>
    Reviewed: #{reviewed_count}
    Done: #{length(done)}
    Dismissed: #{length(dismissed)}
    #{still_open}

    Tomorrow's briefing will build on this: done and dismissed items stay out; still-open items can carry forward.
    """
    |> String.trim()
  end

  defp next_unreviewed_open_todo(%Brief{} = brief) do
    todos = review_todos(brief)
    reviewed_ids = reviewed_ids(brief)

    open_todos =
      Enum.reject(todos, fn todo ->
        todo.status not in @open_statuses or MapSet.member?(reviewed_ids, todo.id)
      end)

    case open_todos do
      [] ->
        nil

      [todo | _] ->
        total = review_total(brief)
        position = MapSet.size(reviewed_ids) + 1
        {todo, min(position, max(total, 1)), max(total, 1)}
    end
  end

  defp review_total(%Brief{} = brief) do
    case review_metadata(brief) do
      %{"todo_ids" => ids} when is_list(ids) and ids != [] -> length(ids)
      _ -> length(review_todos(brief))
    end
  end

  defp review_todos(%Brief{} = brief) do
    todo_ids =
      case review_metadata(brief) do
        %{"todo_ids" => ids} when is_list(ids) and ids != [] -> ids
        _ -> linked_todo_ids(brief)
      end

    brief.user_id
    |> Todos.list_by_ids(todo_ids, statuses: @open_statuses, open_due_only: true)
    |> Briefs.order_todo_digest_items(brief)
  end

  defp all_review_todos(%Brief{} = brief) do
    todo_ids =
      case review_metadata(brief) do
        %{"todo_ids" => ids} when is_list(ids) and ids != [] -> ids
        _ -> linked_todo_ids(brief)
      end

    Todos.list_by_ids(brief.user_id, todo_ids)
  end

  defp linked_todo_ids(%Brief{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("linked_todo_ids", [])
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp linked_todo_ids(_brief), do: []

  defp put_review!(%Brief{} = brief, review) when is_map(review) do
    metadata =
      brief.metadata
      |> Kernel.||(%{})
      |> Map.put(@review_key, review)

    brief
    |> Ecto.Changeset.change(%{metadata: metadata})
    |> Repo.update!()
  end

  defp set_current_todo!(%Brief{} = brief, todo_id) do
    review =
      brief
      |> review_metadata()
      |> Map.put("status", "active")
      |> Map.put("current_todo_id", todo_id)
      |> Map.put("updated_at", now_iso8601())

    put_review!(brief, review)
  end

  defp clear_current_todo!(%Brief{} = brief) do
    review =
      brief
      |> review_metadata()
      |> Map.delete("current_todo_id")
      |> Map.put("updated_at", now_iso8601())

    put_review!(brief, review)
  end

  defp complete_review!(%Brief{} = brief) do
    review =
      brief
      |> review_metadata()
      |> Map.put("status", "completed")
      |> Map.delete("current_todo_id")
      |> Map.put("completed_at", now_iso8601())
      |> Map.put("summary", summary_snapshot(brief))

    put_review!(brief, review)
  end

  defp append_reviewed_action!(%Brief{} = brief, %Todo{} = todo, action) do
    review = review_metadata(brief)

    reviewed =
      review
      |> Map.get("reviewed", [])
      |> List.wrap()
      |> Enum.reject(&(read_string(&1, "todo_id") == todo.id))

    entry = %{
      "todo_id" => todo.id,
      "action" => action,
      "status" => todo.status,
      "at" => now_iso8601()
    }

    put_review!(brief, Map.put(review, "reviewed", reviewed ++ [entry]))
  end

  defp summary_snapshot(%Brief{} = brief) do
    todos = all_review_todos(brief)

    %{
      "done_count" => Enum.count(todos, &(&1.status == "done")),
      "dismissed_count" => Enum.count(todos, &(&1.status == "dismissed")),
      "open_count" => Enum.count(todos, &(&1.status in @open_statuses)),
      "reviewed_count" => length(reviewed_entries(brief))
    }
  end

  defp reviewed_ids(%Brief{} = brief) do
    brief
    |> reviewed_entries()
    |> Enum.map(&read_string(&1, "todo_id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp reviewed_entries(%Brief{} = brief) do
    case Map.get(review_metadata(brief), "reviewed") do
      entries when is_list(entries) -> Enum.filter(entries, &is_map/1)
      _ -> []
    end
  end

  defp review_metadata(%Brief{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, @review_key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp review_metadata(_brief), do: %{}

  defp parse_callback(value) when is_binary(value) do
    case Regex.run(~r/^#{@callback_prefix}:([0-9a-f\-]{36}):(start)$/i, value,
           capture: :all_but_first
         ) do
      [brief_id, action] -> {:ok, brief_id, String.downcase(action)}
      _ -> {:error, :invalid_callback}
    end
  end

  defp parse_callback(_value), do: {:error, :invalid_callback}

  defp callback_data(brief_id, action), do: "#{@callback_prefix}:#{brief_id}:#{action}"

  defp maybe_answer_callback(callback_id, text)
       when is_binary(callback_id) and is_binary(text) and text != "" do
    _ = TelegramResponder.answer_callback(callback_id, text)
    :ok
  end

  defp maybe_answer_callback(_callback_id, _text), do: :ok

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp read_string(map, key, default \\ nil)

  defp read_string(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: default, else: value

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        Enum.find_value(map, default, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key do
              cond do
                is_binary(value) and String.trim(value) != "" -> String.trim(value)
                is_integer(value) -> Integer.to_string(value)
                true -> nil
              end
            end

          _ ->
            nil
        end)
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_id_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        value

      value when is_integer(value) ->
        Integer.to_string(value)

      _ ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key do
              cond do
                is_binary(value) -> value
                is_integer(value) -> Integer.to_string(value)
                true -> nil
              end
            end

          _ ->
            nil
        end)
    end
  end

  defp safe(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp safe(value), do: to_string(value || "") |> safe()
end
