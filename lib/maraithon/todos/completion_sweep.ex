defmodule Maraithon.Todos.CompletionSweep do
  @moduledoc """
  Deterministically closes stale open todos when source data proves completion.

  The sweep is intentionally conservative. It only marks a todo done when the
  underlying source has hard evidence that the work is no longer open:

    * Gmail thread todos with a later self-sent message in the same thread.
    * Local cold-thread todos with a later outgoing local message.
    * Dropped-commitment todos whose backing local reminder is completed.
    * Local calendar-conflict todos whose conflict start passed more than 24h ago.

  All mutations go through `Maraithon.Todos.mark_done/3` so linked insight state
  and resolution metadata stay consistent with manual todo actions.
  """

  import Ecto.Query

  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Gmail
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.LocalReminders.LocalReminder
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  require Logger

  @open_statuses ~w(open snoozed)
  @default_limit 500
  @calendar_conflict_grace_hours 24

  @type summary :: %{
          checked: non_neg_integer(),
          completed: non_neg_integer(),
          errors: non_neg_integer(),
          fetch_errors: non_neg_integer(),
          completed_by_source: map(),
          completed_by_reason: map()
        }

  @doc """
  Runs the completion sweep for every user with open todos.
  """
  def run_for_all_users(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    user_ids =
      case Keyword.get(opts, :user_ids) do
        user_ids when is_list(user_ids) -> user_ids
        _other -> candidate_user_ids(opts)
      end
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    results =
      Enum.map(user_ids, fn user_id ->
        run_for_user(user_id, Keyword.put(opts, :now, now))
      end)

    Enum.reduce(results, empty_all_summary(length(user_ids)), &merge_user_summary/2)
  end

  @doc """
  Runs the completion sweep for one user.

  Tests may inject `:gmail_fetcher` as a two-arity function
  `(user_id, todo) -> {:ok, provider, thread_id, messages} | {:error, reason}`.
  """
  def run_for_user(user_id, opts \\ [])

  def run_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    limit = positive_integer(Keyword.get(opts, :limit), @default_limit)
    self_emails = Keyword.get(opts, :self_emails) || self_emails_for_user(user_id)
    opts = Keyword.put(opts, :self_emails, self_emails)

    todos =
      Todos.list_for_user(user_id,
        statuses: @open_statuses,
        limit: limit,
        sort_by: "updated",
        sort_dir: "asc"
      )

    Enum.reduce(todos, empty_user_summary(user_id, length(todos)), fn todo, summary ->
      case completion_evidence(todo, now, opts) do
        {:done, reason, note} ->
          mark_done(summary, todo, reason, note)

        {:fetch_error, reason} ->
          Logger.warning("Todo completion sweep could not verify Gmail thread",
            user_id: user_id,
            todo_id: todo.id,
            reason: inspect(reason)
          )

          Map.update!(summary, :fetch_errors, &(&1 + 1))

        :open ->
          summary
      end
    end)
  end

  def run_for_user(_user_id, _opts), do: empty_user_summary(nil, 0)

  defp completion_evidence(%Todo{source: "gmail"} = todo, _now, opts) do
    gmail_completion_evidence(todo, opts)
  end

  defp completion_evidence(%Todo{source: "local_patterns"} = todo, now, _opts) do
    case Map.get(todo.metadata || %{}, "detector") do
      "cold_thread" -> cold_thread_completion_evidence(todo)
      "dropped_commitment" -> dropped_commitment_completion_evidence(todo)
      "calendar_conflict" -> calendar_conflict_completion_evidence(todo, now)
      _detector -> :open
    end
  end

  defp completion_evidence(_todo, _now, _opts), do: :open

  defp gmail_completion_evidence(%Todo{} = todo, opts) do
    if is_struct(todo.source_occurred_at, DateTime) do
      gmail_fetcher = Keyword.get(opts, :gmail_fetcher, &fetch_gmail_thread/2)
      self_emails = Keyword.get(opts, :self_emails, [])

      case gmail_fetcher.(todo.user_id, todo) do
        {:ok, provider, thread_id, messages} when is_list(messages) ->
          case later_self_message(messages, todo.source_occurred_at, self_emails) do
            nil ->
              :open

            message ->
              {:done, :gmail_self_reply,
               gmail_resolution_note(provider, thread_id, message, todo.source_occurred_at)}
          end

        {:ok, messages} when is_list(messages) ->
          case later_self_message(messages, todo.source_occurred_at, self_emails) do
            nil ->
              :open

            message ->
              {:done, :gmail_self_reply,
               gmail_resolution_note(nil, nil, message, todo.source_occurred_at)}
          end

        {:error, :not_found} ->
          :open

        {:error, reason} ->
          {:fetch_error, reason}
      end
    else
      :open
    end
  end

  defp cold_thread_completion_evidence(%Todo{} = todo) do
    metadata = todo.metadata || %{}
    chat_key = first_present([metadata["chat_key"], todo.source_item_id])

    if is_binary(chat_key) and is_struct(todo.source_occurred_at, DateTime) do
      latest =
        LocalMessage
        |> where([message], message.user_id == ^todo.user_id)
        |> where([message], message.chat_key == ^chat_key)
        |> where([message], message.is_from_me == true)
        |> where([message], message.sent_at > ^todo.source_occurred_at)
        |> order_by([message], desc: message.sent_at)
        |> limit(1)
        |> Repo.one()

      case latest do
        %LocalMessage{} = message ->
          {:done, :local_message_reply,
           "Scheduled completion sweep: Newer outgoing local message in chat #{chat_key} at #{format_dt(message.sent_at)} after source #{format_dt(todo.source_occurred_at)}."}

        nil ->
          :open
      end
    else
      :open
    end
  end

  defp dropped_commitment_completion_evidence(%Todo{} = todo) do
    metadata = todo.metadata || %{}

    reminder_id =
      first_present([metadata["reminder_guid"], metadata["reminder_id"], todo.source_item_id])

    case completed_reminder(todo.user_id, reminder_id) do
      %LocalReminder{} = reminder ->
        {:done, :completed_local_reminder,
         "Scheduled completion sweep: Backing local reminder #{reminder_id} was completed at #{format_dt(reminder.completed_at)}."}

      nil ->
        :open
    end
  end

  defp calendar_conflict_completion_evidence(%Todo{} = todo, %DateTime{} = now) do
    cutoff = DateTime.add(now, -@calendar_conflict_grace_hours, :hour)

    if is_struct(todo.source_occurred_at, DateTime) and
         DateTime.compare(todo.source_occurred_at, cutoff) == :lt do
      {:done, :expired_calendar_conflict,
       "Scheduled completion sweep: Calendar conflict window passed more than #{@calendar_conflict_grace_hours} hours before this sweep."}
    else
      :open
    end
  end

  defp completed_reminder(_user_id, nil), do: nil

  defp completed_reminder(user_id, reminder_id) when is_binary(reminder_id) do
    identifier_filter =
      dynamic([reminder], reminder.guid == ^reminder_id or reminder.local_id == ^reminder_id)

    identifier_filter =
      case Ecto.UUID.cast(reminder_id) do
        {:ok, uuid} -> dynamic([reminder], ^identifier_filter or reminder.id == ^uuid)
        :error -> identifier_filter
      end

    LocalReminder
    |> where([reminder], reminder.user_id == ^user_id)
    |> where([reminder], reminder.is_completed == true)
    |> where(^identifier_filter)
    |> order_by([reminder], desc_nulls_last: reminder.completed_at, desc: reminder.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp completed_reminder(_user_id, _reminder_id), do: nil

  defp later_self_message(messages, %DateTime{} = source_at, self_emails) do
    messages
    |> Enum.filter(fn message ->
      from_self?(message, self_emails) and
        case message_datetime(message) do
          %DateTime{} = message_at -> DateTime.compare(message_at, source_at) == :gt
          _ -> false
        end
    end)
    |> Enum.sort_by(fn message ->
      message |> message_datetime() |> DateTime.to_unix(:microsecond)
    end)
    |> List.first()
  end

  defp later_self_message(_messages, _source_at, _self_emails), do: nil

  defp from_self?(message, self_emails) do
    email = message |> read_field(:from) |> extract_email()
    email in self_emails
  end

  defp gmail_resolution_note(provider, thread_id, message, source_at) do
    message_id = read_field(message, :message_id) || read_field(message, :id) || "unknown"
    sent_at = message_datetime(message)

    [
      "Scheduled completion sweep: Sent Gmail reply #{message_id}",
      if(thread_id, do: "in thread #{thread_id}"),
      if(provider, do: "via #{provider}"),
      "at #{format_dt(sent_at)} after source #{format_dt(source_at)}."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp fetch_gmail_thread(user_id, %Todo{} = todo) do
    providers = gmail_provider_candidates(user_id, todo)

    providers
    |> Enum.reduce_while({:error, :not_found}, fn provider, _acc ->
      case fetch_gmail_thread_for_provider(user_id, todo, provider) do
        {:ok, thread_id, messages} -> {:halt, {:ok, provider, thread_id, messages}}
        {:error, _reason} -> {:cont, {:error, :not_found}}
      end
    end)
  end

  defp fetch_gmail_thread_for_provider(user_id, %Todo{} = todo, provider) do
    metadata = todo.metadata || %{}

    thread_id =
      first_present([
        metadata["thread_id"],
        metadata["gmail_thread_id"],
        metadata["source_thread_id"],
        todo.source_item_id
      ])

    with {:thread_id, thread_id} when is_binary(thread_id) <- {:thread_id, thread_id},
         {:ok, messages} when is_list(messages) and messages != [] <-
           Gmail.fetch_thread(user_id, thread_id, provider: provider) do
      {:ok, thread_id, messages}
    else
      _ -> fetch_gmail_thread_from_message(user_id, todo, provider)
    end
  end

  defp fetch_gmail_thread_from_message(user_id, %Todo{} = todo, provider) do
    metadata = todo.metadata || %{}

    message_id =
      first_present([
        metadata["message_id"],
        metadata["gmail_message_id"],
        metadata["source_message_id"],
        todo.source_item_id
      ])

    with {:message_id, message_id} when is_binary(message_id) <- {:message_id, message_id},
         {:ok, message} <- Gmail.fetch_message(user_id, message_id, provider: provider),
         thread_id when is_binary(thread_id) and thread_id != "" <-
           read_field(message, :thread_id),
         {:ok, messages} when is_list(messages) and messages != [] <-
           Gmail.fetch_thread(user_id, thread_id, provider: provider) do
      {:ok, thread_id, messages}
    else
      _ -> {:error, :not_found}
    end
  end

  defp gmail_provider_candidates(user_id, %Todo{} = todo) do
    metadata = todo.metadata || %{}

    source_account_provider =
      if is_binary(todo.source_account_label) and String.contains?(todo.source_account_label, "@") do
        "google:" <> todo.source_account_label
      end

    metadata_account_provider =
      case metadata["google_account_email"] do
        email when is_binary(email) and email != "" -> "google:" <> email
        _ -> nil
      end

    [
      metadata["google_provider"],
      metadata["provider"],
      metadata_account_provider,
      source_account_provider
    ]
    |> Enum.concat(connected_google_providers(user_id))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> case do
      [] -> ["google"]
      providers -> providers
    end
  end

  defp connected_google_providers(user_id) when is_binary(user_id) do
    account_providers =
      user_id
      |> ConnectedAccounts.list_for_user()
      |> Enum.filter(fn account ->
        account.status == "connected" and String.starts_with?(account.provider, "google:")
      end)
      |> Enum.map(& &1.provider)

    token_providers =
      user_id
      |> OAuth.list_user_tokens()
      |> Enum.map(& &1.provider)
      |> Enum.filter(&String.starts_with?(&1, "google:"))

    (account_providers ++ token_providers)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp connected_google_providers(_user_id), do: []

  defp self_emails_for_user(user_id) do
    ([user_id] ++ Enum.map(connected_google_providers(user_id), &provider_email/1))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp provider_email("google:" <> email), do: email
  defp provider_email(_provider), do: nil

  defp candidate_user_ids(opts) do
    limit = Keyword.get(opts, :user_limit)

    Todo
    |> where([todo], todo.status in ^@open_statuses)
    |> select([todo], todo.user_id)
    |> distinct(true)
    |> order_by([todo], asc: todo.user_id)
    |> maybe_limit_users(limit)
    |> Repo.all()
  end

  defp maybe_limit_users(query, limit) when is_integer(limit) and limit > 0,
    do: limit(query, ^limit)

  defp maybe_limit_users(query, _limit), do: query

  defp mark_done(summary, %Todo{} = todo, reason, note) do
    case Todos.mark_done(todo.user_id, todo.id, note: note) do
      {:ok, _updated} ->
        summary
        |> Map.update!(:completed, &(&1 + 1))
        |> increment_nested(:completed_by_source, todo.source)
        |> increment_nested(:completed_by_reason, Atom.to_string(reason))

      {:error, error} ->
        Logger.warning("Todo completion sweep failed to mark todo done",
          user_id: todo.user_id,
          todo_id: todo.id,
          reason: inspect(error)
        )

        Map.update!(summary, :errors, &(&1 + 1))
    end
  end

  defp empty_all_summary(user_count) do
    %{
      users: user_count,
      checked: 0,
      completed: 0,
      errors: 0,
      fetch_errors: 0,
      completed_by_source: %{},
      completed_by_reason: %{},
      user_summaries: []
    }
  end

  defp empty_user_summary(user_id, checked) do
    %{
      user_id: user_id,
      checked: checked,
      completed: 0,
      errors: 0,
      fetch_errors: 0,
      completed_by_source: %{},
      completed_by_reason: %{}
    }
  end

  defp merge_user_summary(user_summary, all_summary) do
    all_summary
    |> Map.update!(:checked, &(&1 + user_summary.checked))
    |> Map.update!(:completed, &(&1 + user_summary.completed))
    |> Map.update!(:errors, &(&1 + user_summary.errors))
    |> Map.update!(:fetch_errors, &(&1 + user_summary.fetch_errors))
    |> Map.update!(:completed_by_source, &merge_count_maps(&1, user_summary.completed_by_source))
    |> Map.update!(:completed_by_reason, &merge_count_maps(&1, user_summary.completed_by_reason))
    |> Map.update!(:user_summaries, &[user_summary | &1])
  end

  defp merge_count_maps(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  defp increment_nested(summary, key, value) when is_binary(value) and value != "" do
    Map.update!(summary, key, fn counts -> Map.update(counts, value, 1, &(&1 + 1)) end)
  end

  defp increment_nested(summary, _key, _value), do: summary

  defp read_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp read_field(_map, _key), do: nil

  defp message_datetime(message) do
    message
    |> read_field(:internal_date)
    |> parse_datetime()
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp extract_email(nil), do: nil

  defp extract_email(raw) do
    raw = to_string(raw)

    email =
      case Regex.run(~r/<([^>]+)>/, raw) do
        [_, address] -> address
        _ -> raw
      end

    email
    |> String.trim()
    |> String.downcase()
  end

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end)
  end

  defp format_dt(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_dt(_datetime), do: "unknown time"

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
