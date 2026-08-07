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
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm.Observation
  alias Maraithon.LLM
  alias Maraithon.LocalMessages.LocalMessage
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.PushBroker
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  require Logger

  @open_statuses ~w(open snoozed)
  # Per-cycle LLM prompt-size cap (SPEC 05 R3). This bounds "how many todos
  # we check this cycle", not "which 40 we permanently limit to":
  # evidence-linked (delta) candidates fill the budget first, and whatever
  # remains rotates through the backstop by `last_completion_checked_at`.
  @max_todos 40
  # Safety bound on the open-todo scan for one pathological user; not the
  # real per-cycle cap (see @max_todos above).
  @max_open_todo_scan 500
  @max_observations 120
  @max_outgoing_messages 80
  @max_live_evidence_per_source 120
  @evidence_window_days 7
  @min_todo_age_minutes 30
  @min_confidence 0.8
  @max_excerpt 280
  @default_max_tokens 2_048
  @default_timeout_ms 60_000
  @source_acquisition_timeout_ms 90_000
  @source_skill_id "commitment_tracker"
  @source_skill_config %{
    "email_scan_limit" => 40,
    "event_scan_limit" => 40,
    "gmail_fetch_timeout_ms" => 18_000,
    "gmail_body_fetch_limit" => 24,
    "gmail_body_fetch_timeout_ms" => 750,
    "calendar_fetch_timeout_ms" => 12_000,
    "slack_fetch_timeout_ms" => 45_000,
    "slack_channel_fetch_timeout_ms" => 4_000,
    "slack_search_timeout_ms" => 5_000,
    "slack_self_authored_query_limit" => 3,
    "slack_channel_scan_limit" => 4,
    "slack_message_scan_limit" => 60,
    "companion_fetch_timeout_ms" => 4_000,
    "local_message_limit" => 180,
    "local_chat_limit" => 80,
    "local_voice_memo_limit" => 60,
    "local_note_limit" => 80,
    "local_reminder_limit" => 80,
    "local_file_limit" => 80,
    "local_browser_visit_limit" => 160,
    "lookback_hours" => @evidence_window_days * 24 * 2
  }

  @doc """
  Runs the cross-source pass for every user with open todos.
  """
  def run_for_all_users(opts \\ []) do
    user_ids =
      case Keyword.get(opts, :user_ids) do
        user_ids when is_list(user_ids) ->
          user_ids

        _other ->
          # Every user with open todos: a capped enumeration with no rotation
          # would starve users past the cutoff forever, and user counts are
          # small, so `:user_limit` is deliberately ignored here.
          Repo.all(
            from(t in Todo,
              where: t.status in @open_statuses,
              distinct: true,
              select: t.user_id
            )
          )
      end
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    empty = %{users: length(user_ids), checked: 0, completed: 0, skipped: 0, errors: 0}

    Enum.reduce(user_ids, empty, fn user_id, acc ->
      case run_for_user_safely(user_id, opts) do
        %{checked: checked, completed: completed} ->
          %{acc | checked: acc.checked + checked, completed: acc.completed + completed}

        {:skip, _reason} ->
          %{acc | skipped: acc.skipped + 1}

        {:error, _reason} ->
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  # One user's crash must never abort the pass for every user after them
  # (mirrors StalenessTriageSweep.run_for_user_safely/2).
  defp run_for_user_safely(user_id, opts) do
    run_for_user(user_id, opts)
  rescue
    error ->
      Logger.warning("Cross-source completion crashed for user",
        user_id: user_id,
        reason: Exception.message(error)
      )

      {:error, error}
  catch
    kind, reason ->
      Logger.warning("Cross-source completion crashed for user",
        user_id: user_id,
        reason: "#{kind}: #{inspect(reason)}"
      )

      {:error, {kind, reason}}
  end

  @doc """
  Runs the cross-source pass for one user.

  Returns `%{checked: n, completed: n}`, `{:skip, reason}` when there is
  nothing to evaluate, or `{:error, reason}` when the LLM call fails.
  Tests may inject `:llm_complete` as a prompt-level one-arity function or
  `:llm_request` as a request-map one-arity function.
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    # Cheap existence gate first (SPEC 05 R2): evidence acquisition — which
    # fires live Gmail/Slack/etc. calls — must never run for a user with
    # nothing to check, preserving the original zero-open-todos short-circuit.
    open_todos = open_todo_pool(user_id, now)

    cond do
      open_todos == [] ->
        {:skip, :no_open_todos}

      true ->
        # Evidence before candidate selection (SPEC 05 R2): live acquisition
        # is independent of which todos are checked (`build_live_source_bundle/4`
        # takes `_todos` and never reads it), so collecting first lets R3
        # partition candidates into evidence-linked vs backstop.
        case collect_evidence(user_id, open_todos, now, opts) do
          [] ->
            {:skip, :no_evidence}

          evidence ->
            todos = select_candidates(user_id, open_todos, evidence)

            # Stamp only on success: a failed evaluation checked nothing, so
            # advancing the backstop rotation would skip these todos unchecked.
            case evaluate(user_id, todos, evidence, now, opts) do
              %{} = result ->
                stamp_completion_checked(user_id, todos, now)
                result

              {:error, _reason} = error ->
                error
            end
        end
    end
  end

  # ── Candidates ────────────────────────────────────────────────────────────

  defp open_todo_pool(user_id, now) do
    age_cutoff = DateTime.add(now, -@min_todo_age_minutes * 60, :second)

    user_id
    |> Todos.list_for_user(
      statuses: @open_statuses,
      limit: @max_open_todo_scan,
      sort_by: "updated",
      sort_dir: "asc",
      # Completion checking must see everything open — an unsurfaceable todo
      # still deserves to be closed when the evidence proves it done.
      exclude_unsurfaceable?: false
    )
    |> Enum.filter(fn todo ->
      DateTime.compare(todo.inserted_at, age_cutoff) == :lt
    end)
  end

  # Delta-driven candidate selection with a bounded backstop (SPEC 05 R3):
  # anything with fresh related activity ("active") is checked every cycle
  # regardless of its position in any ordering; the remaining budget rotates
  # deterministically through the rest by `last_completion_checked_at`
  # ascending with never-checked items first.
  defp select_candidates(user_id, todos, evidence) do
    identifiers = evidence_identifiers(evidence)

    {active, backstop} = Enum.split_with(todos, &evidence_linked?(&1, identifiers))

    active =
      if length(active) > @max_todos do
        # The evidence-matched set must respect the prompt-size cap too — an
        # unbounded active set blows the response token budget. `todos` arrive
        # ordered by `updated` ascending, so truncation keeps the stalest
        # items; the rest re-qualify next cycle.
        Logger.info("Cross-source completion truncated active candidates to the per-cycle cap",
          user_id: user_id,
          active: length(active),
          cap: @max_todos
        )

        Enum.take(active, @max_todos)
      else
        active
      end

    backstop_fill =
      backstop
      |> Enum.sort_by(fn todo ->
        case todo.last_completion_checked_at do
          %DateTime{} = checked_at -> {1, DateTime.to_unix(checked_at, :second)}
          _never_checked -> {0, 0}
        end
      end)
      |> Enum.take(max(@max_todos - length(active), 0))

    active ++ backstop_fill
  end

  defp evidence_identifiers(evidence) do
    evidence
    |> Enum.reject(fn item -> read_string(item, "channel", nil) == "source_health" end)
    |> Enum.reduce(%{item_ids: MapSet.new(), label_items: []}, fn item, acc ->
      ids =
        [read_string(item, "thread_id", nil), read_string(item, "source_item_id", nil)]
        |> Enum.reject(&is_nil/1)

      acc = %{acc | item_ids: Enum.into(ids, acc.item_ids)}

      channel = read_string(item, "channel", nil)
      account = read_string(item, "account", nil)
      subject = read_string(item, "subject", nil)

      if channel && account && subject do
        %{acc | label_items: [{channel, account, String.downcase(subject)} | acc.label_items]}
      else
        acc
      end
    end)
  end

  defp evidence_linked?(todo, %{item_ids: item_ids, label_items: label_items}) do
    (is_binary(todo.source_item_id) and todo.source_item_id != "" and
       MapSet.member?(item_ids, todo.source_item_id)) or
      counterparty_label_linked?(todo, label_items)
  end

  defp counterparty_label_linked?(
         %Todo{source: source, source_account_label: account, counterparty_label: label},
         label_items
       )
       when is_binary(source) and is_binary(account) and is_binary(label) do
    case String.trim(label) do
      "" ->
        false

      trimmed ->
        needle = String.downcase(trimmed)

        Enum.any?(label_items, fn {channel, evidence_account, subject} ->
          channel == source and evidence_account == account and
            String.contains?(subject, needle)
        end)
    end
  end

  defp counterparty_label_linked?(_todo, _label_items), do: false

  # Bulk-stamp every candidate considered this cycle (SPEC 05 R4) — including
  # ones that did not close — so the backstop rotation advances even when
  # nothing resolved. `update_all` with an explicit `set:` list (mirroring
  # `Todos.record_nudge_sent/3`), namespaced by user and tolerant of ids that
  # no longer exist (zero rows affected is fine). `updated_at` is deliberately
  # not touched: a "we looked at it" stamp across 40 todos every cycle must
  # not churn updated-ordering or freshness signals.
  defp stamp_completion_checked(_user_id, [], _now), do: :ok

  defp stamp_completion_checked(user_id, todos, now) do
    ids = Enum.map(todos, & &1.id)
    stamped_at = DateTime.truncate(now, :second)

    Todo
    |> where([todo], todo.id in ^ids and todo.user_id == ^user_id)
    |> Repo.update_all(set: [last_completion_checked_at: stamped_at])

    :ok
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

      live_source_unavailable_evidence(now, Exception.message(exception))
  catch
    kind, reason ->
      Logger.warning("Cross-source completion could not collect live source evidence",
        user_id: user_id,
        reason: "#{kind}: #{inspect(reason)}"
      )

      live_source_unavailable_evidence(now, "#{kind}: #{inspect(reason)}")
  end

  defp fetch_live_source_bundle(user_id, todos, now, opts) do
    timeout_ms =
      positive_integer(Keyword.get(opts, :source_timeout_ms), @source_acquisition_timeout_ms)

    fetcher = Keyword.get(opts, :source_bundle_fetcher) || (&build_live_source_bundle/4)

    task = Task.async(fn -> fetcher.(user_id, todos, now, opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, bundle} ->
        bundle

      {:exit, reason} ->
        raise "live source acquisition failed: #{inspect(reason)}"

      nil ->
        raise "live source acquisition timed out after #{timeout_ms}ms"
    end
  end

  defp build_live_source_bundle(user_id, _todos, now, opts) do
    skill_config =
      @source_skill_config
      |> Map.merge(Keyword.get(opts, :source_skill_config, %{}))

    context = %{
      user_id: user_id,
      timestamp: now,
      trigger: %{type: :wakeup, job_type: "todo_completion_sweep"},
      recent_events: [],
      event: nil,
      # An explicit evidence sweep, not a scheduled scan — keep the deep
      # lookback window (SPEC 04 R2 caps scheduled scans to 48h).
      acquisition_deep_lookback: true
    }

    {bundle, _telemetry, _proposed_watermarks} =
      Acquisition.build(
        user_id,
        [@source_skill_id],
        %{@source_skill_id => skill_config},
        context
      )

    bundle
  end

  defp live_source_unavailable_evidence(now, reason) do
    [
      %{
        "channel" => "source_health",
        "kind" => "connected source coverage for this sweep",
        "subject" => "all connected Chief-of-Staff sources",
        "text" =>
          Jason.encode!(%{
            "live_sources" => %{
              "status" => "unavailable",
              "reason" => truncate(reason, @max_excerpt)
            }
          }),
        "at" => DateTime.to_iso8601(now)
      }
    ]
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
      completed = apply_resolutions(user_id, Map.new(todos, &{&1.id, &1}), resolutions, opts)
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
          "captured_at" => DateTime.to_iso8601(todo.source_occurred_at || todo.inserted_at),
          # SPEC 05 R5: structured linkage so the model can match a specific
          # piece of inbound evidence to a specific waiting-on item.
          "direction" => todo.direction,
          "counterparty_label" => todo.counterparty_label,
          "source_item_id" => todo.source_item_id,
          "source_account_label" => todo.source_account_label
        }
        |> compact_map()
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
    - When an item's `direction` is `owed_to_me`, a reply FROM the
      counterparty (not from the user — check the evidence item's `kind`,
      e.g. `email received`, `slack message`, `message received`, never
      `... sent by the user`) that actually answers or resolves what the
      item's `next_action`/`summary` describes is completion for that item,
      exactly like the user doing the work — return it with
      "completed": true and "reply_outcome": "answered". A reply that only
      acknowledges ("got your message, will look at it") or defers ("will
      get back to you Friday") is NOT completion — return that item with
      "completed": false and "reply_outcome": "acknowledged_only", still
      quoting the acknowledgment as evidence_quote, and leave it open. Omit
      reply_outcome (or use "no_reply") when there is no counterparty-reply
      signal for an item.
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
          "confidence": 0.0,
          "reply_outcome": "answered | acknowledged_only | no_reply — only for owed_to_me items with a counterparty-reply signal; omit otherwise"
        }
      ]
    }
    Return {"resolutions": []} when nothing is provably complete.
    """
  end

  defp default_llm_complete(prompt, opts) when is_binary(prompt) do
    config = Application.get_env(:maraithon, :todos, [])
    llm_request = Keyword.get(opts, :llm_request, &LLM.complete/1)

    llm_request.(%{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
      "temperature" => 0.1,
      # The prompt already asks for explicit, evidence-backed reasoning in
      # the JSON payload. Hidden chain-of-thought consumed the entire output
      # budget on hybrid models and left no parseable response.
      "reasoning_effort" => Keyword.get(config, :reasoning_effort, "none"),
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

  # SPEC 05 shared contract (05 owns this dispatch; 01 only consumes it):
  # the model emits exactly one `owed_to_me` reply-outcome per resolved item —
  # "answered" closes (identical in effect to the user doing the work),
  # "acknowledged_only" keeps the item open but clears its nudge cadence,
  # "no_reply"/omitted leaves the item and its cadence untouched.
  defp apply_resolutions(user_id, todos_by_id, resolutions, opts) do
    resolutions
    |> Enum.filter(&is_map/1)
    # The model can emit the same todo twice; only the first resolution per
    # todo applies, so a duplicate can never double-close or double-notify.
    |> Enum.uniq_by(& &1["todo_id"])
    |> Enum.reduce(0, fn resolution, count ->
      with todo_id when is_binary(todo_id) <- resolution["todo_id"],
           %Todo{} = todo <- Map.get(todos_by_id, todo_id) do
        apply_resolution(user_id, todo, resolution, opts, count)
      else
        _other -> count
      end
    end)
  end

  # `owed_to_me` + acknowledgment-only counterparty reply (SPEC 05 R7): never
  # a completion, regardless of what else the resolution claims — stop the
  # old chase cadence but keep the item open, and never notify (an
  # acknowledged-only reply is not a completion event worth a push).
  defp apply_resolution(
         user_id,
         %Todo{direction: "owed_to_me"} = todo,
         %{"reply_outcome" => "acknowledged_only"},
         _opts,
         count
       ) do
    case Todos.clear_nudge_cadence(user_id, todo.id) do
      {:ok, _todo} ->
        Logger.info("Cross-source completion cleared nudge cadence (acknowledged-only reply)",
          user_id: user_id,
          todo_id: todo.id
        )

      {:error, reason} ->
        Logger.warning("Cross-source completion could not clear nudge cadence",
          user_id: user_id,
          todo_id: todo.id,
          reason: inspect(reason)
        )
    end

    count
  end

  defp apply_resolution(user_id, %Todo{} = todo, resolution, opts, count) do
    with true <- resolution["completed"] == true,
         confidence when is_number(confidence) and confidence >= @min_confidence <-
           resolution["confidence"],
         quote_text when is_binary(quote_text) and quote_text != "" <-
           resolution["evidence_quote"] do
      note = resolution_note(todo, resolution, quote_text)

      case Todos.mark_done(user_id, todo.id, note: note) do
        {:ok, _todo} ->
          Logger.info("Cross-source completion closed todo",
            user_id: user_id,
            todo_id: todo.id,
            todo_source: todo.source,
            evidence_channel: resolution["evidence_channel"]
          )

          maybe_push_completion_confirmation(user_id, todo, resolution, opts)
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
  end

  # Distinct confirmation copy for the counterparty-answered close (SPEC 05
  # R7); everything else keeps the pre-existing generic note.
  defp resolution_note(
         %Todo{direction: "owed_to_me"} = todo,
         %{"reply_outcome" => "answered"} = resolution,
         quote_text
       ) do
    "#{counterparty_name(todo)} replied — closing that loop. " <>
      "#{evidence_channel_label(resolution["evidence_channel"])} " <>
      "shows it: \"#{truncate(quote_text, 200)}\""
  end

  defp resolution_note(_todo, resolution, quote_text) do
    "Handled already — #{evidence_channel_label(resolution["evidence_channel"])} " <>
      "shows it: \"#{truncate(quote_text, 200)}\""
  end

  # SPEC 05 R8: Telegram confirmation for the `owed_to_me` inbound-reply close
  # only — `owed_by_me`/`fyi` closes stay silent exactly as before. Goes
  # through `PushBroker.deliver/1` (the only path that respects quiet hours,
  # the interruption budget, and push-receipt dedupe), never `TelegramResponder`
  # directly. `chat_id` must be resolved explicitly — `deliver/1` hard-requires
  # it and never supplies it.
  defp maybe_push_completion_confirmation(
         user_id,
         %Todo{direction: "owed_to_me"} = todo,
         %{"reply_outcome" => "answered"},
         opts
       ) do
    case ConnectedAccounts.telegram_destination(user_id) do
      nil ->
        Logger.info(
          "Cross-source completion skipped closing-loop push: no Telegram destination",
          user_id: user_id,
          todo_id: todo.id
        )

        :ok

      chat_id ->
        deliver = Keyword.get(opts, :push_deliver) || (&PushBroker.deliver/1)

        candidate = %{
          user_id: user_id,
          chat_id: chat_id,
          origin_type: "todo_completion_confirm",
          origin_id: todo.id,
          # Defense-in-depth idempotency: a todo can only close once (closing
          # exits the open/snoozed candidate pool), but the receipt dedupe on
          # this key means even a hypothetical double-apply cannot double-notify.
          dedupe_key: "todo_completion_confirm:#{todo.id}",
          # Low urgency, never the >= 0.9 quiet-hours exemption; rides the
          # normal budget/quiet-hours path like any other low-urgency notice.
          urgency: 0.3,
          interrupt_now: false,
          body: "#{counterparty_name(todo)} replied — closing that loop on: #{todo.title}."
        }

        case deliver.(candidate) do
          {:ok, _result} ->
            :ok

          {:fallback, _reason} ->
            :ok

          {:error, reason} ->
            Logger.warning("Cross-source completion closing-loop push failed",
              user_id: user_id,
              todo_id: todo.id,
              reason: inspect(reason)
            )

            :ok
        end
    end
  end

  defp maybe_push_completion_confirmation(_user_id, _todo, _resolution, _opts), do: :ok

  defp counterparty_name(%Todo{counterparty_label: label}) when is_binary(label) do
    case String.trim(label) do
      "" -> "They"
      trimmed -> trimmed
    end
  end

  defp counterparty_name(_todo), do: "They"

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
