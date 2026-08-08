defmodule Maraithon.Todos.StalenessTriage do
  @moduledoc """
  Weekly-ish batched staleness review (SPEC 05 Part C).

  Proposes — never auto-applies — Keep/Done/Dismiss for up to
  `@max_batch_items` long-quiet todos in a single Telegram card. The model's
  `suggested_action` is advisory copy only; the ONLY thing that ever changes
  a todo's status from this pass is an explicit user tap, handled by
  `Maraithon.TelegramAssistant.TodoActions` through the exact same
  `dispatch_action/4` clauses every other todo card uses.
  """

  import Ecto.Query

  alias Maraithon.AssistantHarness.PromptStability
  alias Maraithon.ConnectedAccounts
  alias Maraithon.LLM
  alias Maraithon.PromptBudget
  alias Maraithon.Repo
  alias Maraithon.Runtime.ToolCallSupervisor
  alias Maraithon.TelegramAssistant.PushBroker
  alias Maraithon.Todos
  alias Maraithon.Todos.{AttentionRanker, StalenessBatch, Todo}

  require Logger

  @open_statuses ~w(open snoozed)
  @max_batch_items 6
  @candidate_scan_limit 200
  @recent_nudge_days 7
  @reproposal_guard_days 6
  @default_llm_timeout_ms 30_000
  @default_max_tokens 1_024
  @max_llm_timeout_ms 30_000
  @max_prompt_bytes 32_000
  @max_response_bytes 128_000
  @fallback_rationale "No recent activity and nothing shows it was handled."

  @doc """
  Runs the staleness triage for one user.

  Returns `{:ok, summary}` when a card decision was made (sent or held),
  `{:skip, reason}` when there is nothing to do, or `{:error, reason}` when
  the model/send failed. Tests may inject `:llm_complete` (one-arity) and
  `:push_deliver` (one-arity, defaults to `PushBroker.deliver/1`).
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    recent_batch_cutoff =
      DateTime.add(now, -@reproposal_guard_days * 24 * 3600, :second)

    cond do
      not Keyword.has_key?(opts, :push_deliver) ->
        # The production delivery path is mobile-push-only and does not yet
        # support this card's inline Keep/Done/Dismiss actions. Do not send a
        # non-actionable notification or create a batch that cannot resolve.
        {:skip, :interactive_delivery_unavailable}

      StalenessBatch.exists_since?(user_id, recent_batch_cutoff) ->
        {:skip, :recent_batch}

      true ->
        case candidate_todos(user_id, now) do
          [] ->
            {:skip, :no_candidates}

          candidates ->
            # `chat_id` resolution is not optional plumbing — `deliver/1`
            # hard-requires it and never supplies it (SPEC 05 edge cases).
            case ConnectedAccounts.telegram_destination(user_id) do
              nil ->
                Logger.info("Staleness triage skipped: no Telegram destination",
                  user_fingerprint: Maraithon.Redaction.fingerprint(user_id)
                )

                {:skip, :no_telegram_destination}

              chat_id ->
                propose(user_id, chat_id, candidates, now, opts)
            end
        end
    end
  end

  # ── Candidates (SPEC 05 R9) ───────────────────────────────────────────────

  defp candidate_todos(user_id, now) do
    nudge_cutoff = DateTime.add(now, -@recent_nudge_days * 24 * 3600, :second)
    proposal_cutoff = DateTime.add(now, -@reproposal_guard_days * 24 * 3600, :second)

    scanned =
      Todo
      |> where([todo], todo.user_id == ^user_id and todo.status in ^@open_statuses)
      |> order_by(
        [todo],
        asc_nulls_first: todo.last_staleness_triage_checked_at,
        asc: todo.source_occurred_at,
        asc: todo.id
      )
      |> limit(^@candidate_scan_limit)
      |> Repo.all()

    stamp_triage_scan(scanned, now)

    scanned
    |> Enum.filter(fn todo ->
      # Reuses the exact flag and its family/strong-relationship/priority
      # carve-outs from AttentionRanker — never reimplemented here.
      AttentionRanker.profile(todo, now: now)["stale_confirmation_candidate"] == true and
        not recently_nudged?(todo, nudge_cutoff) and
        not recently_proposed?(todo, proposal_cutoff)
    end)
    # Preserve the durable scan order: never-scanned rows come first, then
    # the least-recently scanned rows in stable source/id order.
    |> Enum.take(@max_batch_items)
  end

  defp stamp_triage_scan([], _now), do: :ok

  defp stamp_triage_scan(todos, now) do
    ids = Enum.map(todos, & &1.id)

    Todo
    |> where([todo], todo.id in ^ids)
    |> Repo.update_all(set: [last_staleness_triage_checked_at: DateTime.truncate(now, :second)])

    :ok
  end

  # Recently-nudged is "actively being chased," not stale.
  defp recently_nudged?(%Todo{last_nudged_at: %DateTime{} = at}, cutoff),
    do: DateTime.compare(at, cutoff) != :lt

  defp recently_nudged?(_todo, _cutoff), do: false

  # Idempotency across weekly runs (R9/R13): stamped only after a card
  # actually reached the user (`decision == "sent_now"`).
  defp recently_proposed?(%Todo{metadata: metadata}, cutoff) when is_map(metadata) do
    with %{} = triage <- Map.get(metadata, "staleness_triage"),
         raw when is_binary(raw) <- Map.get(triage, "last_proposed_at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(raw) do
      DateTime.compare(at, cutoff) != :lt
    else
      _other -> false
    end
  end

  defp recently_proposed?(_todo, _cutoff), do: false

  # ── Model pass (bounded, advisory-only) ───────────────────────────────────

  defp propose(user_id, chat_id, candidates, now, opts) do
    case triage_rationales(user_id, candidates, now, opts) do
      {:ok, rationales} ->
        send_card(user_id, chat_id, candidates, rationales, now, opts)

      {:error, reason} ->
        # Degrade to "skip this cycle, no card" — never crash the sweep.
        Logger.info("Staleness triage model pass failed; skipping this cycle",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        {:skip, :llm_unavailable}
    end
  end

  defp triage_rationales(user_id, candidates, now, opts) do
    timeout_ms =
      opts
      |> Keyword.get(:llm_timeout_ms)
      |> positive_integer(@default_llm_timeout_ms)
      |> min(@max_llm_timeout_ms)

    bounded_opts = Keyword.put(opts, :llm_timeout_ms, timeout_ms)
    llm_complete = Keyword.get(opts, :llm_complete) || (&default_llm_complete(&1, bounded_opts))

    with {:ok, prompt} <- build_prompt(candidates, now, Todos.user_timezone_context(user_id)) do
      task = Task.Supervisor.async_nolink(ToolCallSupervisor, fn -> llm_complete.(prompt) end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, response}} -> decode_response(response, candidates)
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, other} -> {:error, {:unexpected_llm_result, other}}
        {:exit, reason} -> {:error, {:llm_task_exit, Maraithon.Redaction.error_class(reason)}}
        nil -> {:error, {:llm_timeout, timeout_ms}}
      end
    end
  end

  defp build_prompt(candidates, now, timezone_context) do
    items =
      Enum.map(candidates, fn todo ->
        %{
          "todo_id" => bounded_binary(todo.id, 64),
          "title" => bounded_binary(todo.title, 240),
          "summary" => bounded_binary(todo.summary, 480),
          "next_action" => bounded_binary(todo.next_action, 320),
          "source" => bounded_binary(todo.source, 64),
          "age_days" => age_days(todo, now),
          "direction" => todo.direction
        }
        |> compact_map()
      end)

    prompt =
      """
      You are the staleness reviewer for a chief-of-staff product. Each open
      work item below has been quiet for a while: no completion evidence and no
      recent activity. For each item write one short sentence on why it looks
      stale / what is still unresolved, and suggest whether the operator should
      keep it active or dismiss it. Your suggestion is advisory copy only — the
      operator decides with explicit buttons; nothing is ever closed
      automatically.

      CURRENT_LOCAL_TIME: #{local_label(now, timezone_context)}

      STALE_CANDIDATES_JSON:
      #{Jason.encode!(items)}

      Respond with only a JSON array, no prose:
      [
      {
        "todo_id": "uuid",
        "rationale": "one short sentence on why it looks stale / what's still unresolved",
        "suggested_action": "keep" or "dismiss"
      }
      ]
      """

    request_bytes =
      [%{"role" => "user", "content" => prompt}]
      |> PromptStability.encode!()
      |> byte_size()

    if request_bytes <= @max_prompt_bytes do
      {:ok, prompt}
    else
      {:error, {:staleness_prompt_exceeds_budget, request_bytes}}
    end
  end

  defp default_llm_complete(prompt, opts) when is_binary(prompt) do
    config = Application.get_env(:maraithon, :todos, [])

    LLM.complete(%{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
      "temperature" => 0.1,
      "reasoning_effort" => Keyword.get(config, :reasoning_effort, LLM.intelligence()),
      "timeout_ms" => Keyword.get(opts, :llm_timeout_ms, @default_llm_timeout_ms)
    })
  end

  defp decode_response(response, candidates) do
    content =
      case response do
        %{"content" => content} when is_binary(content) -> content
        %{content: content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _other -> nil
      end

    with content when is_binary(content) and byte_size(content) <= @max_response_bytes <- content,
         json when is_binary(json) <- extract_json_array(content),
         {:ok, items} when is_list(items) <- Jason.decode(json),
         true <- length(Enum.take(items, @max_batch_items + 1)) <= @max_batch_items do
      known = MapSet.new(candidates, & &1.id)

      rationales =
        items
        |> Enum.filter(&is_map/1)
        |> Enum.reduce(%{}, fn item, acc ->
          todo_id = item["todo_id"]

          if is_binary(todo_id) and MapSet.member?(known, todo_id) do
            Map.put(acc, todo_id, format_rationale(item["rationale"], item["suggested_action"]))
          else
            acc
          end
        end)

      rationales =
        Enum.reduce(candidates, rationales, fn todo, acc ->
          Map.put_new(acc, todo.id, @fallback_rationale)
        end)

      {:ok, rationales}
    else
      _other -> {:error, :staleness_triage_invalid_response}
    end
  end

  # Byte offsets are safe: the brackets are ASCII, so slicing between them
  # keeps multibyte content in the middle intact.
  defp extract_json_array(content) do
    with {start, _length} <- :binary.match(content, "["),
         [_ | _] = closers <- :binary.matches(content, "]") do
      {finish, _length} = List.last(closers)
      binary_part(content, start, finish - start + 1)
    else
      _other -> nil
    end
  end

  defp format_rationale(rationale, suggested_action) do
    rationale = rationale |> bounded_binary(600) |> presence() || @fallback_rationale

    case suggested_action do
      action when action in ["keep", "dismiss"] -> "Suggested: #{action} — #{rationale}"
      _other -> rationale
    end
  end

  # ── Card send (SPEC 05 R11) ───────────────────────────────────────────────

  defp send_card(user_id, chat_id, candidates, rationales, now, opts) do
    # Pre-generated so `origin_id` can reference the batch row that is only
    # inserted after a confirmed "sent_now" (the row needs the message_id).
    batch_id = Ecto.UUID.generate()
    payload = card_payload(candidates, rationales, now)
    deliver = Keyword.get(opts, :push_deliver) || (&PushBroker.deliver/1)

    candidate = %{
      user_id: user_id,
      chat_id: chat_id,
      origin_type: "staleness_triage",
      origin_id: batch_id,
      # At most one batch card per user per calendar day even if the sweep
      # is re-triggered.
      dedupe_key: "staleness_triage:#{user_id}:#{Date.to_iso8601(DateTime.to_date(now))}",
      title: "Stale open loops review",
      body: payload.text,
      urgency: 0.2,
      interrupt_now: false,
      digest: true,
      telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
    }

    # `deliver/1`'s return is NOT uniformly message_id-bearing: only
    # "sent_now" carries one. Held/suppressed outcomes are normal (digest
    # cards ride quiet hours) — create no batch row and stamp nothing, so the
    # next sweep tick retries naturally.
    case deliver.(candidate) do
      {:ok, %{decision: "sent_now", message_id: message_id}} ->
        persist_batch(user_id, chat_id, message_id, batch_id, candidates, rationales, now)

      {:ok, %{decision: decision} = result} ->
        {:ok, %{sent: false, decision: decision, reason: Map.get(result, :reason)}}

      {:fallback, reason} ->
        {:skip, {:push_disabled, reason}}

      {:error, reason} ->
        Logger.warning("Staleness triage card send failed",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        {:error, reason}
    end
  end

  defp persist_batch(user_id, chat_id, message_id, batch_id, candidates, rationales, now) do
    now_iso = DateTime.to_iso8601(now)
    todo_ids = Enum.map(candidates, & &1.id)

    case StalenessBatch.create(%{
           id: batch_id,
           user_id: user_id,
           chat_id: chat_id,
           message_id: message_id,
           todo_ids: todo_ids,
           rationales: Map.take(rationales, todo_ids)
         }) do
      {:ok, batch} ->
        Enum.each(candidates, fn todo ->
          stamp_proposed(user_id, todo, Map.get(rationales, todo.id), now_iso)
        end)

        {:ok,
         %{sent: true, decision: "sent_now", batch_id: batch.id, todo_count: length(todo_ids)}}

      {:error, reason} ->
        Logger.warning("Staleness triage could not persist batch state",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        {:error, reason}
    end
  end

  defp stamp_proposed(user_id, %Todo{} = todo, rationale, now_iso) do
    triage =
      case Map.get(todo.metadata || %{}, "staleness_triage") do
        %{} = existing -> existing
        _other -> %{}
      end
      |> Map.put("last_proposed_at", now_iso)
      |> Map.put("rationale", rationale)

    # `update_for_user/3` merges top-level metadata keys, so everything else
    # in the todo's metadata is preserved (never replace the whole map).
    case Todos.update_for_user(user_id, todo.id, %{"metadata" => %{"staleness_triage" => triage}}) do
      {:ok, _todo} ->
        :ok

      {:error, reason} ->
        Logger.warning("Staleness triage could not stamp proposal metadata",
          user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
          todo_reference: Maraithon.Redaction.fingerprint(todo.id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        :ok
    end
  end

  # ── Rendering (initial card + batch re-render) ────────────────────────────

  @doc false
  def card_payload(candidates, rationales, now) do
    blocks =
      candidates
      |> Enum.with_index(1)
      |> Enum.map(fn {todo, index} ->
        candidate_block(index, todo.title, Map.get(rationales, todo.id), age_days(todo, now))
      end)

    %{
      text: Enum.join([header(length(candidates)) | blocks], "\n\n"),
      reply_markup: %{"inline_keyboard" => Enum.map(candidates, &button_row(&1.id))}
    }
  end

  @doc """
  Re-renders the batch card from persisted batch state (SPEC 05 R12):
  resolved items become checked lines with no buttons, pending items keep
  their block + buttons, and a fully-resolved batch collapses to a short
  summary with no keyboard.
  """
  def batch_payload(user_id, %StalenessBatch{} = batch, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    todo_ids = List.wrap(batch.todo_ids)

    if StalenessBatch.all_resolved?(batch) do
      %{
        text: "All set — #{length(todo_ids)} reviewed.",
        reply_markup: %{"inline_keyboard" => []}
      }
    else
      resolved = batch.resolved || %{}
      rationales = batch.rationales || %{}

      {blocks, rows} =
        todo_ids
        |> Enum.with_index(1)
        |> Enum.map(fn {todo_id, index} ->
          todo = Todos.get_for_user(user_id, todo_id)
          title = (todo && todo.title) || "This item"

          case Map.get(resolved, todo_id) do
            %{"action" => action} ->
              {"✅ #{safe(title)} — #{resolved_action_label(action)}", nil}

            _pending ->
              age = todo && age_days(todo, now)

              {candidate_block(index, title, Map.get(rationales, todo_id), age),
               button_row(todo_id)}
          end
        end)
        |> Enum.unzip()

      %{
        text: Enum.join([header(length(todo_ids)) | blocks], "\n\n"),
        reply_markup: %{"inline_keyboard" => Enum.reject(rows, &is_nil/1)}
      }
    end
  end

  defp header(count), do: "These #{count} look stale — still relevant?"

  defp candidate_block(index, title, rationale, age_days) do
    [
      "<b>#{index}. #{safe(title)}</b>",
      safe(presence(rationale) || @fallback_rationale),
      age_days && "Opened #{age_days} days ago."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Same `tgtodo:<id>:<action>` callback format TodoActions already parses —
  # never a new callback prefix or action verb (SPEC 05 R11).
  defp button_row(todo_id) do
    [
      %{"text" => "Keep active", "callback_data" => "tgtodo:#{todo_id}:important"},
      %{"text" => "Done", "callback_data" => "tgtodo:#{todo_id}:done"},
      %{"text" => "Dismiss", "callback_data" => "tgtodo:#{todo_id}:dismiss"}
    ]
  end

  defp resolved_action_label("important"), do: "kept active"
  defp resolved_action_label("done"), do: "done"
  defp resolved_action_label("dismiss"), do: "dismissed"
  defp resolved_action_label(other) when is_binary(other), do: other
  defp resolved_action_label(_other), do: "resolved"

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Same day-diff AttentionRanker already uses (exposed via profile/2) — no
  # hand-rolled day math (SPEC 05 edge cases).
  defp age_days(todo, now) do
    AttentionRanker.profile(todo, now: now)["age_days"]
  end

  defp local_label(%DateTime{} = datetime, timezone_context) do
    offset =
      case timezone_context do
        %{offset_hours: offset} when is_integer(offset) -> offset
        _other -> 0
      end

    local = DateTime.add(datetime, offset, :hour)
    label = if offset >= 0, do: "UTC+#{offset}", else: "UTC#{offset}"

    "#{Calendar.strftime(local, "%Y-%m-%d %H:%M")} local (#{label})"
  end

  defp safe(value) when is_binary(value),
    do: Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()

  defp safe(value), do: value |> to_string() |> safe()

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp bounded_binary(value, max_bytes) when is_binary(value),
    do: PromptBudget.truncate_utf8(value, max_bytes)

  defp bounded_binary(_value, _max_bytes), do: nil

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
