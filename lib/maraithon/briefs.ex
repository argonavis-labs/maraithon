defmodule Maraithon.Briefs do
  @moduledoc """
  Persistence and Telegram delivery for operator briefing messages.
  """

  import Ecto.Query

  alias Maraithon.Briefs.Brief
  alias Maraithon.AppUrl
  alias Maraithon.DeliveryErrorCopy
  alias Maraithon.Repo
  alias Maraithon.Redaction
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.BriefTodoReview
  alias Maraithon.Todos
  alias Maraithon.Todos.AttentionRanker
  alias Maraithon.Todos.UserFacingCopy

  require Logger

  @brief_title_fallback "Chief of staff brief"
  @brief_summary_default "No priority follow-up is ready to review."
  @brief_body_default "No decision needs your attention right now."
  @brief_summary_fallback "Maraithon kept only review-ready next steps."
  @brief_body_fallback "No verified recommendation was safe to send yet."
  @todo_digest_empty_decision_text "No saved open work is ready for a decision right now."
  # Bug 3 fix: Telegram rejects messages over 4096 chars with HTTP 400
  # "message is too long". Cap well under that so HTML entities introduced
  # by escaping (e.g. `&amp;`, `&lt;`) can't push the final payload over the
  # wire limit. The full brief still reaches the user via email
  # (Briefs.Email.maybe_deliver/1), so a cap-with-trailer — not general
  # multi-message chunking — is the right scope here.
  @telegram_text_cap 3900
  @telegram_truncation_trailer "… Full briefing in your email inbox."
  # SPEC 09 R17: hard ceiling of `proactive_candidates.body`
  # (`validate_length(:body, max: 10_000)`). The full-text renderers below
  # clamp only to this — a much larger budget than the Telegram wire cap —
  # so the candidate changeset never rejects a long brief outright. Telegram
  # wire-size chunking happens at send time in `PushBroker.send_candidate/1`.
  @proactive_candidate_body_cap 10_000
  @internal_brief_markers [
    "<redacted",
    "=>",
    "{",
    "}",
    "llm_",
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

  # Failed briefs wait before retrying — without the backoff a dead
  # Telegram destination meant a retry (and a warning log) every minute,
  # indefinitely.
  @failed_retry_after_seconds 15 * 60

  # Bug 1 fix: cadences that repeat multiple times a day (check_in,
  # commitment_tracker) go stale fast — a 26-brief backlog stretching back
  # to Jun 27 permanently filled the dispatch batch and starved same-day
  # briefs (including the morning brief) from ever being attempted. These
  # cadences expire after 36 hours; everything else (morning and other daily
  # cadences) gets a 3-day window — a morning brief that old is stale news
  # the user already got a late alert for.
  @fast_cadence_expiry_cadences ["check_in", "commitment_tracker"]
  @fast_cadence_expiry_seconds 36 * 60 * 60
  @default_cadence_expiry_seconds 3 * 24 * 60 * 60

  # Cheap, idempotent single UPDATE run at the top of every notifier tick
  # (before list_pending/1) so a stale backlog can never again permanently
  # starve the batch. Once stamped "brief_expired_unsent" (a terminal
  # DeliveryErrorCopy message) a brief stops qualifying for list_pending/1
  # forever, so re-running this is a no-op for already-expired rows.
  def expire_stale_pending(now \\ DateTime.utc_now()) do
    terminal_delivery_errors = DeliveryErrorCopy.terminal_storage_messages()
    fast_cutoff = DateTime.add(now, -@fast_cadence_expiry_seconds, :second)
    default_cutoff = DateTime.add(now, -@default_cadence_expiry_seconds, :second)

    {count, _} =
      Brief
      |> where(
        [b],
        b.status == "pending" or
          (b.status == "failed" and
             (is_nil(b.error_message) or b.error_message not in ^terminal_delivery_errors))
      )
      |> where(
        [b],
        (b.cadence in ^@fast_cadence_expiry_cadences and b.scheduled_for < ^fast_cutoff) or
          (b.cadence not in ^@fast_cadence_expiry_cadences and b.scheduled_for < ^default_cutoff)
      )
      |> Repo.update_all(
        set: [status: "failed", error_message: "brief_expired_unsent", updated_at: now]
      )

    count
  end

  def list_pending(limit \\ 20) when is_integer(limit) and limit > 0 do
    terminal_delivery_errors = DeliveryErrorCopy.terminal_storage_messages()
    retry_cutoff = DateTime.add(DateTime.utc_now(), -@failed_retry_after_seconds, :second)

    Brief
    |> where(
      [b],
      b.status == "pending" or
        (b.status == "failed" and b.updated_at < ^retry_cutoff and
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

  def get_for_user(user_id, brief_id) when is_binary(user_id) and is_binary(brief_id) do
    case Ecto.UUID.cast(brief_id) do
      {:ok, _uuid} -> Repo.get_by(Brief, id: brief_id, user_id: user_id)
      :error -> nil
    end
  end

  def get_for_user(_user_id, _brief_id), do: nil

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

  def dispatch_pending_batch(opts \\ []) do
    expire_stale_pending(Keyword.get(opts, :now, DateTime.utc_now()))

    batch_size = Keyword.get(opts, :batch_size, 10)
    pending = list_pending(batch_size)

    # Morning briefs also go to the user's inbox. Email delivery is
    # idempotent per brief and independent of the push state machine, so a
    # push outage cannot block the daily ritual.
    Enum.each(pending, &Maraithon.Briefs.Email.maybe_deliver/1)

    pending
    |> Enum.reduce(%{sent: 0, failed: 0, skipped: 0}, fn brief, acc ->
      case send_brief(brief) do
        :ok -> %{acc | sent: acc.sent + 1}
        :skip -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  def send_brief(%Brief{} = brief) do
    case TelegramAssistant.deliver_brief(brief) do
      :ok ->
        :ok

      :queued ->
        # Handed to the DeliveryPlanner as a proactive candidate; nothing
        # reached the user yet, so this tick sent nothing. Travel marking
        # happens at the confirmed-delivery points (PushBroker /
        # DeliveryPlanner brief marking), not here.
        :skip

      {:fallback, :disabled} ->
        # Unified push broker globally off: nothing to send (email already
        # went out above for morning briefs).
        :skip

      {:error, :no_push_device} ->
        # No registered phone yet; the brief stays pending until one
        # registers or the expiry sweep retires it.
        :skip

      {:error, reason} ->
        Logger.warning("Failed to broker brief push",
          reason: inspect(reason),
          brief_id: brief.id
        )

        {:error, reason}
    end
  end

  def telegram_payload(%Brief{} = brief) do
    %{
      text: brief |> render_telegram_text() |> cap_telegram_text(),
      reply_markup: brief_reply_markup(brief)
    }
  end

  @doc """
  Full (uncapped) Telegram rendering of a standard brief — same rendering as
  `telegram_payload/1` but without `cap_telegram_text/1`, clamped only to the
  proactive-candidate body ceiling (SPEC 09 R17). Chunked at send time by
  `PushBroker.send_candidate/1` instead of truncating the tail (where Look
  Ahead and the closing "today's move" directive live).
  """
  def telegram_full_text(%Brief{} = brief) do
    brief
    |> render_telegram_text()
    |> clamp_length(@proactive_candidate_body_cap)
  end

  @doc """
  Full (uncapped) Telegram rendering of a todo-digest brief intro — the
  todo-digest sibling of `telegram_full_text/1` (SPEC 09 R17).
  """
  def todo_digest_full_text(%Brief{} = brief, todos \\ nil) do
    todos = todos || todo_digest_todos(brief)

    brief
    |> render_todo_digest_telegram_text(todos)
    |> clamp_length(@proactive_candidate_body_cap)
  end

  def public_title(%Brief{} = brief), do: public_brief_title(brief.title)
  def public_title(value), do: public_brief_title(value)

  def public_summary(%Brief{} = brief), do: public_brief_summary(brief.summary)
  def public_summary(value), do: public_brief_summary(value)

  def todo_digest_telegram_payload(%Brief{} = brief, todos \\ nil) do
    todos = todos || todo_digest_todos(brief)

    %{
      text: brief |> render_todo_digest_telegram_text(todos) |> cap_telegram_text(),
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
    {new_today_count, still_open_count} = todo_digest_counts(brief, todos)

    detail_line =
      case todos do
        [] ->
          @todo_digest_empty_decision_text

        _ ->
          cond do
            new_today_count > 0 and still_open_count > 0 ->
              "#{new_today_count} new today. #{still_open_count} carried over from earlier."

            new_today_count > 0 ->
              "#{new_today_count} new today."

            still_open_count > 0 ->
              "#{still_open_count} carried over from earlier."

            true ->
              @todo_digest_empty_decision_text
          end
      end

    if todos == [] do
      detail_line
    else
      """
      Best next move: #{todo_digest_next_move(todos)}

      Open work: #{detail_line}
      """
      |> String.trim()
    end
  end

  def todo_digest_prefix_text(%Brief{} = _brief, _todo), do: nil

  # A generated briefing one character over a schema cap must be clamped,
  # never rejected — a too-long body used to silently drop the whole day's
  # briefing at the persistence boundary.
  defp normalize_attrs(attrs, user_id, agent_id) do
    %{
      "user_id" => user_id,
      "agent_id" => agent_id,
      "cadence" => read_string(attrs, "cadence", "morning"),
      "title" => attrs |> read_string("title", @brief_title_fallback) |> clamp_length(180),
      "summary" => attrs |> read_string("summary", @brief_summary_default) |> clamp_length(500),
      "body" => attrs |> read_string("body", @brief_body_default) |> clamp_length(20_000),
      "status" => read_string(attrs, "status", "pending"),
      "scheduled_for" => read_datetime(attrs, "scheduled_for") || DateTime.utc_now(),
      "dedupe_key" => read_string(attrs, "dedupe_key", Ecto.UUID.generate()),
      "error_message" => read_string(attrs, "error_message", nil),
      "metadata" => read_map(attrs, "metadata")
    }
  end

  defp clamp_length(value, max) when is_binary(value) do
    if String.length(value) > max do
      String.slice(value, 0, max - 1) <> "…"
    else
      value
    end
  end

  defp clamp_length(value, _max), do: value

  defp preserve_status("sent"), do: "sent"
  defp preserve_status(_), do: "pending"

  # Rendering cap for the manual todo-review-brief path; the push path
  # clamps separately in APNS.payload/1.
  defp cap_telegram_text(text) when is_binary(text) do
    if String.length(text) <= @telegram_text_cap do
      text
    else
      trailer_budget = String.length(@telegram_truncation_trailer) + 2
      body_budget = max(@telegram_text_cap - trailer_budget, 0)

      text
      |> truncate_at_paragraph_boundary(body_budget)
      |> String.trim_trailing()
      |> Kernel.<>("\n\n" <> @telegram_truncation_trailer)
    end
  end

  defp cap_telegram_text(text), do: text

  defp truncate_at_paragraph_boundary(text, max_length) when max_length > 0 do
    candidate = String.slice(text, 0, max_length)

    case String.split(candidate, "\n\n") do
      [_only] ->
        candidate

      parts ->
        parts
        |> Enum.slice(0, length(parts) - 1)
        |> Enum.join("\n\n")
    end
  end

  defp truncate_at_paragraph_boundary(_text, _max_length), do: ""

  defp render_telegram_text(%Brief{} = brief) do
    if travel_brief?(brief) do
      brief.body
      |> public_brief_body()
      |> Maraithon.TelegramMarkdown.to_html()
    else
      cadence_label = cadence_label(brief.cadence)
      title = public_title(brief)
      summary = public_summary(brief)
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
    <b>#{safe(public_title(brief))}</b>

    #{Maraithon.TelegramMarkdown.to_html(intro)}
    """
    |> String.trim()
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
  defp cadence_label("commitment_tracker"), do: "Open work review"
  defp cadence_label("travel_prep"), do: "Travel prep"
  defp cadence_label("travel_update"), do: "Travel update"
  defp cadence_label(other), do: other

  # A context-backed fallback is still a usable brief. It can carry diagnostic
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

  defp safe(value) when is_binary(value),
    do: Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()

  defp safe(value), do: value |> to_string() |> safe()

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

  defp todo_digest_next_move([todo]) do
    focus = todo |> todo_digest_focus() |> todo_digest_sentence()

    "#{focus} Then make the call: mark it done, snooze it, keep it active, or dismiss it."
  end

  defp todo_digest_next_move([todo | _todos]) do
    focus = todo |> todo_digest_focus() |> todo_digest_sentence()

    "#{focus} Then decide the rest: mark done, snooze, keep active, or dismiss each one."
  end

  defp todo_digest_next_move(_todos), do: @todo_digest_empty_decision_text

  defp todo_digest_sentence(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> "Start with the first open item and choose the outcome."
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

  defp todo_id(%{id: id}) when is_binary(id), do: id
  defp todo_id(%{"id" => id}) when is_binary(id), do: id
  defp todo_id(id) when is_binary(id), do: id
  defp todo_id(_value), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

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
