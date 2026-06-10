defmodule Maraithon.Todos.CrossSourceCompletion do
  @moduledoc """
  LLM-backed completion pass that closes open todos when later activity in a
  DIFFERENT channel shows the work was already handled.

  The deterministic `CompletionSweep` only sees same-source evidence (a Gmail
  reply closes a Gmail todo). This pass looks across channels: a Gmail
  "pay Vendor X" todo closes when a Slack message says "just paid Vendor X",
  an outgoing iMessage confirms an RSVP, and so on.

  Evidence comes exclusively from data already persisted server-side — CRM
  observations (Gmail in/outbound and Slack excerpts) and outgoing companion
  iMessages — so the pass makes no connector API calls. The bar for closing
  is strict and the LLM must quote the evidence; ambiguous matches stay open,
  because wrongly closing real work is worse than showing a finished item.
  """

  import Ecto.Query

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
  @evidence_window_days 7
  @min_todo_age_minutes 30
  @min_confidence 0.8
  @max_excerpt 280
  @default_max_tokens 2_048
  @default_timeout_ms 60_000

  @doc """
  Runs the cross-source pass for every user with open todos.
  """
  def run_for_all_users(opts \\ []) do
    user_limit = positive_integer(Keyword.get(opts, :user_limit), 100)

    user_ids =
      Repo.all(
        from(t in Todo,
          where: t.status in @open_statuses,
          distinct: true,
          select: t.user_id,
          limit: ^user_limit
        )
      )

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
        case collect_evidence(user_id, now) do
          [] -> {:skip, :no_evidence}
          evidence -> evaluate(user_id, todos, evidence, now, opts)
        end
    end
  end

  # ── Candidates ────────────────────────────────────────────────────────────

  defp candidate_todos(user_id, now) do
    age_cutoff = DateTime.add(now, -@min_todo_age_minutes * 60, :second)

    user_id
    |> Todos.list_for_user(statuses: @open_statuses, limit: @max_todos, sort_by: "updated", sort_dir: "asc")
    |> Enum.filter(fn todo ->
      DateTime.compare(todo.inserted_at, age_cutoff) == :lt
    end)
  end

  # ── Evidence ──────────────────────────────────────────────────────────────

  defp collect_evidence(user_id, now) do
    cutoff = DateTime.add(now, -@evidence_window_days * 24 * 3600, :second)
    observation_evidence(user_id, cutoff) ++ outgoing_message_evidence(user_id, cutoff)
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
          "captured_at" =>
            DateTime.to_iso8601(todo.source_occurred_at || todo.inserted_at)
        }
      end)
      |> Jason.encode!()

    evidence_json = Jason.encode!(evidence)

    """
    You are the completion checker for a chief-of-staff product. The user has
    saved open work items. Below is their recent activity across OTHER
    channels (email excerpts, Slack messages, iMessages the user sent).

    Decide which open work items the user has ALREADY COMPLETED, judged only
    from this activity.

    Strict rules:
    - Close an item only when the evidence explicitly shows that the specific
      work was done: a past-tense completion statement by the user ("paid",
      "sent it", "booked", "submitted", "done", "renewed", "shipped"), or a
      counterparty confirming receipt/closure ("got it, thanks", a receipt or
      confirmation message), about the SAME counterparty/object as the item.
    - Evidence must be AFTER the item's captured_at timestamp.
    - Topic overlap alone is NOT completion. Future intent ("will pay
      tomorrow"), questions, reminders, or partial progress are NOT
      completion.
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
          "evidence_channel": "slack | gmail | imessage",
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
  defp evidence_channel_label("imessage"), do: "a message you sent"
  defp evidence_channel_label(other) when is_binary(other), do: "your #{other} activity"
  defp evidence_channel_label(_other), do: "your recent activity"

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
