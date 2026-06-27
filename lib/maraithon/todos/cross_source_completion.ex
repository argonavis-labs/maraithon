defmodule Maraithon.Todos.CrossSourceCompletion do
  @moduledoc """
  LLM-backed completion pass that closes open todos when later source material
  shows the work was already handled.

  The deterministic `CompletionSweep` only sees hard same-source evidence (a
  Gmail reply closes a Gmail todo). This pass gives the model current material
  from every connected Chief-of-Staff source, plus persisted observations, so it
  can reason across Gmail, Slack, Calendar, local messages, notes, reminders,
  files, browser history, and other companion sources.

  The bar for closing is strict and the LLM must quote source evidence;
  ambiguous matches stay open, because wrongly closing real work is worse than
  showing a finished item.
  """

  import Ecto.Query

  alias Maraithon.ChiefOfStaff.{Acquisition, SourceBundle}
  alias Maraithon.Crm.Observation
  alias Maraithon.LLM
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  require Logger

  @open_statuses ~w(open snoozed)
  @max_todos 40
  @max_observations 120
  @max_outgoing_messages 80
  @max_live_evidence_per_source 120
  @evidence_window_days 7
  @min_todo_age_minutes 30
  @min_confidence 0.8
  @max_excerpt 280
  @default_max_tokens 2_048
  @default_timeout_ms 60_000
  @source_skill_id "commitment_tracker"
  @source_skill_config %{
    "email_scan_limit" => 200,
    "event_scan_limit" => 120,
    "slack_message_scan_limit" => 220,
    "local_message_limit" => 300,
    "local_chat_limit" => 140,
    "local_voice_memo_limit" => 120,
    "local_note_limit" => 140,
    "local_reminder_limit" => 140,
    "local_file_limit" => 120,
    "local_browser_visit_limit" => 240,
    "lookback_hours" => @evidence_window_days * 24 * 2
  }

  @doc """
  Runs the cross-source pass for every user with open todos.
  """
  def run_for_all_users(opts \\ []) do
    user_limit = positive_integer(Keyword.get(opts, :user_limit), 100)

    user_ids =
      case Keyword.get(opts, :user_ids) do
        user_ids when is_list(user_ids) ->
          user_ids

        _other ->
          Repo.all(
            from(t in Todo,
              where: t.status in @open_statuses,
              distinct: true,
              select: t.user_id,
              limit: ^user_limit
            )
          )
      end
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    empty = %{users: length(user_ids), checked: 0, completed: 0, skipped: 0, errors: 0}

    Enum.reduce(user_ids, empty, fn user_id, acc ->
      case run_for_user(user_id, opts) do
        %{checked: checked, completed: completed} ->
          %{acc | checked: acc.checked + checked, completed: acc.completed + completed}

        {:skip, _reason} ->
          %{acc | skipped: acc.skipped + 1}

        {:error, _reason} ->
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  @doc """
  Runs the cross-source pass for one user.

  Returns `%{checked: n, completed: n}`, `{:skip, reason}` when there is
  nothing to evaluate, or `{:error, reason}` when the LLM call fails.
  Tests may inject `:llm_complete` as a one-arity function.
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    todos = candidate_todos(user_id, now)

    cond do
      todos == [] ->
        {:skip, :no_open_todos}

      true ->
        case collect_evidence(user_id, todos, now, opts) do
          [] -> {:skip, :no_evidence}
          evidence -> evaluate(user_id, todos, evidence, now, opts)
        end
    end
  end

  # ── Candidates ────────────────────────────────────────────────────────────

  defp candidate_todos(user_id, now) do
    age_cutoff = DateTime.add(now, -@min_todo_age_minutes * 60, :second)

    user_id
    |> Todos.list_for_user(
      statuses: @open_statuses,
      limit: @max_todos,
      sort_by: "updated",
      sort_dir: "asc"
    )
    |> Enum.filter(fn todo ->
      DateTime.compare(todo.inserted_at, age_cutoff) == :lt
    end)
  end

  # ── Evidence ──────────────────────────────────────────────────────────────

  defp collect_evidence(user_id, todos, now, opts) do
    cutoff = DateTime.add(now, -@evidence_window_days * 24 * 3600, :second)

    user_id
    |> observation_evidence(cutoff)
    |> Enum.concat(outgoing_message_evidence(user_id, cutoff))
    |> Enum.concat(live_source_evidence(user_id, todos, now, opts))
    |> dedupe_evidence()
  end

  defp observation_evidence(user_id, cutoff) do
    Repo.all(
      from(o in Observation,
        where: o.user_id == ^user_id and o.occurred_at >= ^cutoff,
        where: not is_nil(o.excerpt) and o.excerpt != "",
        order_by: [desc: o.occurred_at],
        limit: @max_observations,
        select: %{
          source: o.source,
          direction: o.direction,
          subject: o.subject,
          excerpt: o.excerpt,
          occurred_at: o.occurred_at
        }
      )
    )
    |> Enum.map(fn obs ->
      %{
        "channel" => obs.source,
        "kind" => observation_kind(obs),
        "subject" => obs.subject,
        "text" => truncate(obs.excerpt, @max_excerpt),
        "at" => DateTime.to_iso8601(obs.occurred_at)
      }
    end)
  rescue
    _exception -> []
  end

  defp observation_kind(%{source: "gmail", direction: "outbound"}), do: "email sent by the user"
  defp observation_kind(%{source: "gmail"}), do: "email received"
  defp observation_kind(%{source: "slack"}), do: "slack message"
  defp observation_kind(%{source: source}), do: to_string(source)

  defp outgoing_message_evidence(user_id, cutoff) do
    Repo.all(
      from(m in LocalMessage,
        where: m.user_id == ^user_id and m.is_from_me == true,
        where: m.sent_at >= ^cutoff,
        where: not is_nil(m.text) and m.text != "",
        order_by: [desc: m.sent_at],
        limit: @max_outgoing_messages,
        select: %{
          chat: m.chat_display_name,
          handle: m.chat_key,
          text: m.text,
          sent_at: m.sent_at
        }
      )
    )
    |> Enum.map(fn message ->
      %{
        "channel" => "imessage",
        "kind" => "message sent by the user",
        "subject" => message.chat || message.handle,
        "text" => truncate(message.text, @max_excerpt),
        "at" => DateTime.to_iso8601(message.sent_at)
      }
    end)
  rescue
    _exception -> []
  end

  defp live_source_evidence(user_id, todos, now, opts) do
    cond do
      Keyword.has_key?(opts, :source_bundle) ->
        opts
        |> Keyword.get(:source_bundle)
        |> source_bundle_evidence(now)

      Keyword.get(opts, :live_sources, true) ->
        user_id
        |> fetch_live_source_bundle(todos, now, opts)
        |> source_bundle_evidence(now)

      true ->
        []
    end
  rescue
    exception ->
      Logger.warning("Cross-source completion could not collect live source evidence",
        user_id: user_id,
        reason: Exception.message(exception)
      )

      []
  catch
    kind, reason ->
      Logger.warning("Cross-source completion could not collect live source evidence",
        user_id: user_id,
        reason: "#{kind}: #{inspect(reason)}"
      )

      []
  end

  defp fetch_live_source_bundle(user_id, _todos, now, opts) do
    skill_config =
      @source_skill_config
      |> Map.merge(Keyword.get(opts, :source_skill_config, %{}))

    context = %{
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup, job_type: "todo_completion_sweep"},
      recent_events: [],
      event: nil
    }

    {bundle, _telemetry} =
      Acquisition.build(
        user_id,
        [@source_skill_id],
        %{@source_skill_id => skill_config},
        context
      )

    bundle
  end

  defp source_bundle_evidence(bundle, now) when is_map(bundle) do
    [
      source_health_evidence(bundle, now),
      bundle |> SourceBundle.gmail_messages() |> evidence_bucket(&gmail_source_evidence/1),
      bundle |> SourceBundle.calendar_events() |> evidence_bucket(&calendar_source_evidence/1),
      bundle
      |> SourceBundle.calendar_local_events()
      |> evidence_bucket(&local_calendar_source_evidence/1),
      bundle |> SourceBundle.slack_messages() |> evidence_bucket(&slack_source_evidence/1),
      bundle |> SourceBundle.slack_mentions() |> evidence_bucket(&slack_mention_evidence/1),
      bundle |> SourceBundle.imessage_messages() |> evidence_bucket(&imessage_source_evidence/1),
      bundle |> SourceBundle.notes() |> evidence_bucket(&note_source_evidence/1),
      bundle |> SourceBundle.reminders() |> evidence_bucket(&reminder_source_evidence/1),
      bundle |> SourceBundle.files() |> evidence_bucket(&file_source_evidence/1),
      bundle
      |> SourceBundle.browser_visits()
      |> evidence_bucket(&browser_history_source_evidence/1),
      bundle |> SourceBundle.voice_memos() |> evidence_bucket(&voice_memo_source_evidence/1)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp source_bundle_evidence(_bundle, _now), do: []

  defp source_health_evidence(bundle, now) do
    freshness = SourceBundle.freshness(bundle)

    %{
      "channel" => "source_health",
      "kind" => "connected source coverage for this sweep",
      "subject" => "all connected Chief-of-Staff sources",
      "text" => Jason.encode!(freshness),
      "at" => DateTime.to_iso8601(now)
    }
  end

  defp evidence_bucket(items, mapper) when is_list(items) and is_function(mapper, 1) do
    items
    |> Enum.map(mapper)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&evidence_sort_key/1, :desc)
    |> Enum.take(@max_live_evidence_per_source)
  end

  defp evidence_bucket(_items, _mapper), do: []

  defp gmail_source_evidence(message) when is_map(message) do
    text =
      [
        read_string(message, "body_text", nil),
        read_string(message, "text_body", nil),
        read_string(message, "snippet", nil),
        read_string(message, "html_body", nil)
      ]
      |> first_present()

    evidence_item(%{
      "channel" => "gmail",
      "kind" => gmail_kind(message),
      "subject" => read_string(message, "subject", nil),
      "text" => text,
      "at" => evidence_time(message, ["internal_date", "date"]),
      "source_item_id" => read_string(message, "message_id", read_string(message, "id", nil)),
      "thread_id" => read_string(message, "thread_id", nil),
      "account" =>
        read_string(message, "account", read_string(message, "google_account_email", nil))
    })
  end

  defp gmail_source_evidence(_message), do: nil

  defp gmail_kind(message) do
    labels = read_list(message, "labels")

    cond do
      "SENT" in labels -> "email sent by the user"
      "INBOX" in labels -> "email received"
      true -> "gmail message"
    end
  end

  defp calendar_source_evidence(event) when is_map(event) do
    calendar_evidence_item("google_calendar", "calendar event", event)
  end

  defp calendar_source_evidence(_event), do: nil

  defp local_calendar_source_evidence(event) when is_map(event) do
    calendar_evidence_item("local_calendar", "local calendar event", event)
  end

  defp local_calendar_source_evidence(_event), do: nil

  defp calendar_evidence_item(channel, kind, event) do
    summary = read_string(event, "summary", read_string(event, "title", nil))

    text =
      [
        read_string(event, "description", nil),
        read_string(event, "notes", nil),
        read_string(event, "location", nil),
        read_string(event, "html_link", nil),
        event |> read_list("attendees") |> attendee_summary()
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")

    evidence_item(%{
      "channel" => channel,
      "kind" => kind,
      "subject" => summary,
      "text" => text,
      "at" => evidence_time(event, ["start", "start_at", "created", "updated"]),
      "source_item_id" =>
        read_string(event, "event_id", read_string(event, "id", read_string(event, "guid", nil))),
      "account" => read_string(event, "account", read_string(event, "google_account_email", nil))
    })
  end

  defp slack_source_evidence(message) when is_map(message) do
    evidence_item(%{
      "channel" => "slack",
      "kind" => "slack message",
      "subject" => read_string(message, "channel_name", read_string(message, "channel_id", nil)),
      "text" => read_string(message, "text_resolved", read_string(message, "text", nil)),
      "at" => evidence_time(message, ["date", "ts"]),
      "source_item_id" =>
        slack_source_item_id(
          read_string(message, "channel_id", nil),
          read_string(message, "ts", nil)
        ),
      "thread_id" => read_string(message, "thread_ts", nil),
      "permalink" => read_string(message, "permalink", nil)
    })
  end

  defp slack_source_evidence(_message), do: nil

  defp slack_mention_evidence(message) when is_map(message) do
    message
    |> slack_source_evidence()
    |> case do
      nil -> nil
      item -> Map.put(item, "kind", "slack mention")
    end
  end

  defp slack_mention_evidence(_message), do: nil

  defp imessage_source_evidence(message) when is_map(message) do
    evidence_item(%{
      "channel" => "imessage",
      "kind" =>
        if(truthy?(read_value(message, "is_from_me")),
          do: "message sent by the user",
          else: "message received"
        ),
      "subject" =>
        read_string(message, "chat_display_name", read_string(message, "chat_key", nil)),
      "text" => read_string(message, "text", nil),
      "at" => evidence_time(message, ["sent_at", "date"]),
      "source_item_id" => read_string(message, "guid", read_string(message, "message_id", nil))
    })
  end

  defp imessage_source_evidence(_message), do: nil

  defp note_source_evidence(note) when is_map(note) do
    evidence_item(%{
      "channel" => "notes",
      "kind" => "note",
      "subject" => read_string(note, "title", nil),
      "text" => read_string(note, "body", read_string(note, "text", nil)),
      "at" => evidence_time(note, ["updated_at", "modified_at", "created_at"]),
      "source_item_id" => read_string(note, "guid", read_string(note, "id", nil))
    })
  end

  defp note_source_evidence(_note), do: nil

  defp reminder_source_evidence(reminder) when is_map(reminder) do
    evidence_item(%{
      "channel" => "reminders",
      "kind" =>
        if(truthy?(read_value(reminder, "is_completed")),
          do: "completed reminder",
          else: "open reminder"
        ),
      "subject" => read_string(reminder, "title", nil),
      "text" => read_string(reminder, "notes", nil),
      "at" => evidence_time(reminder, ["completed_at", "due_at", "updated_at"]),
      "source_item_id" => read_string(reminder, "guid", read_string(reminder, "id", nil))
    })
  end

  defp reminder_source_evidence(_reminder), do: nil

  defp file_source_evidence(file) when is_map(file) do
    evidence_item(%{
      "channel" => "files",
      "kind" => "recent file",
      "subject" => read_string(file, "name", read_string(file, "filename", nil)),
      "text" => read_string(file, "path", read_string(file, "text", nil)),
      "at" => evidence_time(file, ["modified_at", "created_at"]),
      "source_item_id" => read_string(file, "id", read_string(file, "path", nil))
    })
  end

  defp file_source_evidence(_file), do: nil

  defp browser_history_source_evidence(visit) when is_map(visit) do
    evidence_item(%{
      "channel" => "browser_history",
      "kind" => "browser visit",
      "subject" => read_string(visit, "title", nil),
      "text" => read_string(visit, "url", nil),
      "at" => evidence_time(visit, ["visited_at", "last_visit_at"]),
      "source_item_id" => read_string(visit, "id", read_string(visit, "url", nil))
    })
  end

  defp browser_history_source_evidence(_visit), do: nil

  defp voice_memo_source_evidence(memo) when is_map(memo) do
    evidence_item(%{
      "channel" => "voice_memos",
      "kind" => "voice memo",
      "subject" => read_string(memo, "title", nil),
      "text" => read_string(memo, "transcript", read_string(memo, "text", nil)),
      "at" => evidence_time(memo, ["recorded_at", "created_at", "updated_at"]),
      "source_item_id" => read_string(memo, "guid", read_string(memo, "id", nil))
    })
  end

  defp voice_memo_source_evidence(_memo), do: nil

  # ── Evaluation ────────────────────────────────────────────────────────────

  defp evaluate(user_id, todos, evidence, now, opts) do
    prompt = build_prompt(todos, evidence, now)
    llm_complete = Keyword.get(opts, :llm_complete) || (&default_llm_complete(&1, opts))

    with {:ok, response} <- llm_complete.(prompt),
         {:ok, resolutions} <- decode_response(response) do
      completed = apply_resolutions(user_id, Map.new(todos, &{&1.id, &1}), resolutions)
      %{checked: length(todos), completed: completed}
    else
      {:error, reason} ->
        Logger.warning("Cross-source completion pass failed",
          user_id: user_id,
          reason: inspect(reason)
        )

        {:error, reason}

      other ->
        {:error, {:unexpected_llm_result, other}}
    end
  end

  defp build_prompt(todos, evidence, now) do
    todos_json =
      todos
      |> Enum.map(fn todo ->
        %{
          "todo_id" => todo.id,
          "source_channel" => todo.source,
          "title" => todo.title,
          "summary" => truncate(todo.summary, 300),
          "next_action" => truncate(todo.next_action, 200),
          "captured_at" => DateTime.to_iso8601(todo.source_occurred_at || todo.inserted_at)
        }
      end)
      |> Jason.encode!()

    evidence_json = Jason.encode!(evidence)

    """
    You are the completion checker for a chief-of-staff product. The user has
    saved open work items. Below is current source material from every connected
    source this sweep could access: Gmail, Slack, Google Calendar, local
    Calendar, iMessage/Messages, Reminders, Notes, files, browser history, voice
    memos, and persisted CRM observations. The `source_health` item records
    which sources were ready, partial, unavailable, or empty for this sweep.

    Decide which open work items the user has ALREADY COMPLETED or which have
    been made obsolete by newer source evidence, judged only from the supplied
    source material.

    Strict rules:
    - Close an item only when the evidence explicitly shows that the specific
      work was done: a past-tense completion statement by the user ("paid",
      "sent it", "booked", "submitted", "done", "renewed", "shipped"), or a
      counterparty confirming receipt/closure ("got it, thanks", a receipt or
      confirmation message), about the SAME counterparty/object as the item.
    - For work whose action is to create, publish, schedule, or share an event,
      later source material showing the same event exists, has a public/manage
      URL, has guests/attendees, is live, is being promoted, or is otherwise
      already operating is completion evidence for that creation/publishing
      step. Do not keep the creation item open just because follow-on work
      remains; follow-on work belongs in a separate work item.
    - Use intelligence, not keyword overlap. Compare the object, counterparty,
      timing, source references, and the actual action requested. Source search
      terms or topic similarity alone are not completion.
    - Evidence must be AFTER the item's captured_at timestamp.
    - Topic overlap alone is NOT completion. Future intent ("will pay
      tomorrow"), questions, reminders, or partial progress are NOT
      completion.
    - If a relevant connected source is unavailable or the source window is too
      weak to prove completion, leave the item open.
    - When unsure, leave the item open. Wrongly closing real work is worse
      than showing a finished item.

    OPEN_WORK_ITEMS_JSON:
    #{todos_json}

    RECENT_ACTIVITY_JSON (current time #{DateTime.to_iso8601(now)}):
    #{evidence_json}

    Respond with only this JSON shape, no prose:
    {
      "resolutions": [
        {
          "todo_id": "uuid of a completed item",
          "completed": true,
          "evidence_channel": "slack | gmail | google_calendar | local_calendar | imessage | reminders | notes | files | browser_history | voice_memos | crm",
          "evidence_quote": "the exact activity text that proves completion",
          "reasoning": "one short sentence",
          "confidence": 0.0
        }
      ]
    }
    Return {"resolutions": []} when nothing is provably complete.
    """
  end

  defp default_llm_complete(prompt, opts) when is_binary(prompt) do
    config = Application.get_env(:maraithon, :todos, [])

    LLM.complete(%{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
      "temperature" => 0.1,
      "reasoning_effort" => Keyword.get(config, :reasoning_effort, LLM.intelligence()),
      "timeout_ms" => Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    })
  end

  defp decode_response(response) do
    content =
      case response do
        %{"content" => content} when is_binary(content) -> content
        %{content: content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _other -> nil
      end

    with content when is_binary(content) <- content,
         json when is_binary(json) <- extract_json(content),
         {:ok, %{"resolutions" => resolutions}} when is_list(resolutions) <-
           Jason.decode(json) do
      {:ok, resolutions}
    else
      _other -> {:error, :cross_source_completion_invalid_response}
    end
  end

  # Byte offsets are safe here: the braces are ASCII, so slicing between
  # them keeps any multibyte content in the middle intact.
  defp extract_json(content) do
    with {start, _length} <- :binary.match(content, "{"),
         [_ | _] = closers <- :binary.matches(content, "}") do
      {finish, _length} = List.last(closers)
      binary_part(content, start, finish - start + 1)
    else
      _other -> nil
    end
  end

  defp apply_resolutions(user_id, todos_by_id, resolutions) do
    Enum.reduce(resolutions, 0, fn resolution, count ->
      with todo_id when is_binary(todo_id) <- resolution["todo_id"],
           %Todo{} = todo <- Map.get(todos_by_id, todo_id),
           true <- resolution["completed"] == true,
           confidence when is_number(confidence) and confidence >= @min_confidence <-
             resolution["confidence"],
           quote_text when is_binary(quote_text) and quote_text != "" <-
             resolution["evidence_quote"] do
        note =
          "Handled already — #{evidence_channel_label(resolution["evidence_channel"])} " <>
            "shows it: \"#{truncate(quote_text, 200)}\""

        case Todos.mark_done(user_id, todo.id, note: note) do
          {:ok, _todo} ->
            Logger.info("Cross-source completion closed todo",
              user_id: user_id,
              todo_id: todo.id,
              todo_source: todo.source,
              evidence_channel: resolution["evidence_channel"]
            )

            count + 1

          {:error, reason} ->
            Logger.warning("Cross-source completion could not close todo",
              user_id: user_id,
              todo_id: todo.id,
              reason: inspect(reason)
            )

            count
        end
      else
        _other -> count
      end
    end)
  end

  defp evidence_channel_label("gmail"), do: "your email activity"
  defp evidence_channel_label("slack"), do: "your Slack activity"
  defp evidence_channel_label("google_calendar"), do: "your Google Calendar"
  defp evidence_channel_label("local_calendar"), do: "your calendar"
  defp evidence_channel_label("imessage"), do: "a message you sent"
  defp evidence_channel_label("reminders"), do: "your reminders"
  defp evidence_channel_label("notes"), do: "your notes"
  defp evidence_channel_label("files"), do: "your files"
  defp evidence_channel_label("browser_history"), do: "your browser history"
  defp evidence_channel_label("voice_memos"), do: "your voice memos"
  defp evidence_channel_label(other) when is_binary(other), do: "your #{other} activity"
  defp evidence_channel_label(_other), do: "your recent activity"

  defp evidence_item(attrs) when is_map(attrs) do
    text = read_string(attrs, "text", nil)
    subject = read_string(attrs, "subject", nil)

    if blank?(text) and blank?(subject) do
      nil
    else
      attrs
      |> Map.update("text", nil, &truncate(&1, @max_excerpt))
      |> Map.update("subject", nil, &truncate(&1, 180))
      |> compact_map()
    end
  end

  defp evidence_item(_attrs), do: nil

  defp dedupe_evidence(evidence) when is_list(evidence) do
    evidence
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn item ->
      {
        read_string(item, "channel", nil),
        read_string(item, "source_item_id", nil),
        read_string(item, "thread_id", nil),
        read_string(item, "subject", nil),
        read_string(item, "text", nil)
      }
    end)
  end

  defp evidence_sort_key(item) when is_map(item) do
    case item |> read_string("at", nil) |> parse_datetime() do
      %DateTime{} = at -> DateTime.to_unix(at, :microsecond)
      _ -> 0
    end
  end

  defp evidence_sort_key(_item), do: 0

  defp evidence_time(map, keys) when is_map(map) and is_list(keys) do
    keys
    |> Enum.find_value(fn key ->
      map
      |> read_value(key)
      |> normalize_evidence_time()
    end)
  end

  defp evidence_time(_map, _keys), do: nil

  defp normalize_evidence_time(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp normalize_evidence_time(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp normalize_evidence_time(%{date: date}) when is_binary(date), do: date
  defp normalize_evidence_time(%{"date" => date}) when is_binary(date), do: date

  defp normalize_evidence_time(value) when is_binary(value) do
    cond do
      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        DateTime.to_iso8601(datetime)

      Regex.match?(~r/^\d+(?:\.\d+)?$/, value) ->
        {seconds, _rest} = Float.parse(value)

        seconds
        |> Kernel.*(1_000_000)
        |> round()
        |> DateTime.from_unix!(:microsecond)
        |> DateTime.to_iso8601()

      true ->
        value
    end
  end

  defp normalize_evidence_time(_value), do: nil

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp attendee_summary([]), do: nil

  defp attendee_summary(attendees) when is_list(attendees) do
    attendees
    |> Enum.take(12)
    |> Enum.map(fn
      attendee when is_map(attendee) ->
        first_present([
          read_string(attendee, "display_name", nil),
          read_string(attendee, "displayName", nil),
          read_string(attendee, "email", nil)
        ])

      attendee when is_binary(attendee) ->
        attendee

      _other ->
        nil
    end)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      names -> "Attendees: " <> Enum.join(names, ", ")
    end
  end

  defp attendee_summary(_attendees), do: nil

  defp slack_source_item_id(channel_id, ts) when is_binary(channel_id) and is_binary(ts),
    do: "#{channel_id}:#{ts}"

  defp slack_source_item_id(_channel_id, _ts), do: nil

  defp read_list(map, key) when is_map(map) do
    case read_value(map, key) do
      value when is_list(value) -> value
      _other -> []
    end
  end

  defp read_list(_map, _key), do: []

  defp read_string(map, key, default) when is_map(map) do
    case read_value(map, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> default
          trimmed -> trimmed
        end

      nil ->
        default

      value when is_atom(value) ->
        value |> Atom.to_string() |> read_string_value(default)

      value when is_integer(value) or is_float(value) ->
        to_string(value)

      _other ->
        default
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_string_value("", default), do: default
  defp read_string_value(value, _default), do: value

  defp read_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp read_value(_map, _key), do: nil

  defp first_present(values) when is_list(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
      _value -> true
    end)
  end

  defp first_present(_values), do: nil

  defp truthy?(value) when value in [true, 1], do: true

  defp truthy?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> then(&(&1 in ["true", "yes", "1"]))
  end

  defp truthy?(_value), do: false

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max - 1) <> "…"
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
