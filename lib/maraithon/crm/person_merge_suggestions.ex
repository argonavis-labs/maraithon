defmodule Maraithon.Crm.PersonMergeSuggestions do
  @moduledoc """
  SPEC 04 R8-R10: non-destructive soft-match merge suggestions.

  `Maraithon.Crm.PersonDeduper` is deliberately precision-first: it only
  auto-merges people sharing a durable identifier or an exact multi-token
  name. The common real split — "Dan" seen via Slack and "Dan Bourke" seen
  via Gmail with no shared identifier — never merges and is never flagged.
  This module fills exactly that gap, and only that gap:

  1. Find each active person's closest other active person by embedding
     cosine similarity (pairwise, mirroring `Crm.do_semantic_find_person/3`'s
     SQL) above a materially higher floor than recall search uses.
  2. Exclude any pair the deduper would already auto-merge, and any pair
     already surfaced through a prior prepared action (rejected, pending, or
     executed) — a "no" is never re-surfaced every cycle.
  3. Batch one model call (never one per pair) to judge sameness with
     evidence and confidence. Two distinct real people at the same
     company/family are a common embedding false positive, so the prompt
     demands evidence of sameness, not name closeness.
  4. A confirmed pair above the confidence floor becomes a confirmable
     Telegram card through the existing PreparedAction flow whose confirmed
     action invokes the existing `merge_people` assistant tool.

  **This module never calls `Crm.merge_people/4`.** A wrong merge is
  destructive and one-directional; a human must tap confirm every time.

  Runs sequenced strictly after `PersonDeduper.run/2` on the same
  `person_dedupe` background-job cadence (see
  `Maraithon.Runtime.BackgroundJobHandler`), so a pair the deduper just
  auto-merged this cycle is naturally gone rather than separately flagged.
  The run summary always reports counts — including zero-candidate cycles —
  so a silently-regressed scan never looks identical to "no duplicates".
  """

  import Ecto.Query

  alias Maraithon.BriefingSchedules
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm.Person
  alias Maraithon.LLM
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.PreparedAction
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramResponder

  require Logger

  @similarity_floor 0.82
  @confidence_floor 0.7
  @default_people_limit 400
  @default_max_pairs 6
  @default_max_tokens 2_500
  @identifier_kinds ~w(apple_contact_ids emails phones slack_ids telegram_ids)

  def run(user_id, opts \\ [])

  def run(user_id, opts) when is_binary(user_id) and is_list(opts) do
    similarity_floor = Keyword.get(opts, :similarity_floor, @similarity_floor)
    confidence_floor = Keyword.get(opts, :confidence_floor, @confidence_floor)
    max_pairs = Keyword.get(opts, :max_pairs, @default_max_pairs)
    people_limit = Keyword.get(opts, :people_limit, @default_people_limit)

    if pgvector_available?() do
      pairs = candidate_pairs(user_id, similarity_floor, people_limit)

      {deduper_pairs, soft_pairs} = Enum.split_with(pairs, &deduper_would_handle?/1)
      {surfaced_pairs, fresh_pairs} = Enum.split_with(soft_pairs, &already_surfaced?(user_id, &1))
      eligible = Enum.take(fresh_pairs, max_pairs)

      judgments = judge_pairs(user_id, eligible, opts)

      {proposed, declined} =
        Enum.reduce(judgments, {0, 0}, fn judgment, {proposed, declined} ->
          if judgment.same_person and judgment.confidence >= confidence_floor and
               is_binary(judgment.evidence) do
            case propose(user_id, judgment) do
              {:ok, _prepared_action} -> {proposed + 1, declined}
              _skip_or_error -> {proposed, declined + 1}
            end
          else
            {proposed, declined + 1}
          end
        end)

      {:ok,
       %{
         source: "person_merge_suggestions",
         pairs_found: length(pairs),
         excluded_deterministic: length(deduper_pairs),
         excluded_previously_surfaced: length(surfaced_pairs),
         judged: length(eligible),
         proposed: proposed,
         declined: declined
       }}
    else
      {:ok,
       %{
         source: "person_merge_suggestions",
         status: "pgvector_unavailable",
         pairs_found: 0,
         judged: 0,
         proposed: 0
       }}
    end
  end

  def run(_user_id, _opts), do: {:error, :invalid_person_merge_suggestions}

  # ---------------------------------------------------------------------------
  # Pair discovery (embedding nearest-neighbor, pairwise)
  # ---------------------------------------------------------------------------

  defp candidate_pairs(user_id, similarity_floor, people_limit) do
    result =
      Repo.query!(
        """
        SELECT a.id, b.id, 1 - (a.embedding <=> b.embedding) AS similarity
        FROM (
          SELECT id, user_id, embedding
          FROM crm_people
          WHERE user_id = $1 AND status = 'active' AND embedding IS NOT NULL
          LIMIT $3
        ) a
        JOIN LATERAL (
          SELECT other.id, other.embedding
          FROM crm_people other
          WHERE other.user_id = a.user_id AND other.status = 'active'
            AND other.embedding IS NOT NULL AND other.id != a.id
          ORDER BY other.embedding <=> a.embedding
          LIMIT 1
        ) b ON TRUE
        WHERE 1 - (a.embedding <=> b.embedding) >= $2
        ORDER BY similarity DESC
        """,
        [user_id, similarity_floor, people_limit]
      )

    pair_rows =
      result.rows
      |> Enum.map(fn [left_bin, right_bin, similarity] ->
        {:ok, left_id} = Ecto.UUID.load(left_bin)
        {:ok, right_id} = Ecto.UUID.load(right_bin)
        {Enum.sort([left_id, right_id]), similarity}
      end)
      |> Enum.uniq_by(fn {pair_ids, _similarity} -> pair_ids end)

    ids =
      pair_rows
      |> Enum.flat_map(fn {pair_ids, _similarity} -> pair_ids end)
      |> Enum.uniq()

    people_by_id =
      Person
      |> where([person], person.user_id == ^user_id and person.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    pair_rows
    |> Enum.flat_map(fn {[left_id, right_id], similarity} ->
      with %Person{} = left <- Map.get(people_by_id, left_id),
           %Person{} = right <- Map.get(people_by_id, right_id) do
        [%{left: left, right: right, similarity: similarity}]
      else
        _missing -> []
      end
    end)
  end

  defp pgvector_available? do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.columns " <>
          "WHERE table_name = 'crm_people' AND column_name = 'embedding'"
      )

    rows != []
  rescue
    _error -> false
  end

  # ---------------------------------------------------------------------------
  # Exclusions
  # ---------------------------------------------------------------------------

  # A pair PersonDeduper would already auto-merge (shared durable identifier
  # or exact multi-token name) is strictly out of scope for this tier.
  defp deduper_would_handle?(%{left: left, right: right}) do
    shares_durable_identifier?(left, right) or exact_multi_token_name?(left, right)
  end

  defp shares_durable_identifier?(%Person{} = left, %Person{} = right) do
    not MapSet.disjoint?(identifier_values(left), identifier_values(right))
  end

  defp identifier_values(%Person{contact_details: contact_details}) do
    (contact_details || %{})
    |> Map.take(@identifier_kinds)
    |> Enum.flat_map(fn {kind, values} ->
      values
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&normalize_identifier(kind, &1))
    end)
    |> MapSet.new()
  end

  defp normalize_identifier("phones", value) do
    digits = String.replace(value, ~r/\D+/, "")

    if byte_size(digits) >= 10 do
      [{"phones", String.slice(digits, -10, 10)}]
    else
      []
    end
  end

  defp normalize_identifier(kind, value) do
    case value |> String.trim() |> String.downcase() do
      "" -> []
      normalized -> [{kind, normalized}]
    end
  end

  defp exact_multi_token_name?(%Person{} = left, %Person{} = right) do
    left_name = normalize_name(left.display_name)
    right_name = normalize_name(right.display_name)

    left_name != "" and left_name == right_name and
      length(String.split(left_name, " ", trim: true)) >= 2
  end

  defp normalize_name(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end

  defp normalize_name(_value), do: ""

  # A pair already surfaced through a prepared action — awaiting, confirmed,
  # executed, or explicitly rejected — is not re-surfaced. Expired cards
  # (the user never answered) may be surfaced again.
  defp already_surfaced?(user_id, %{left: left, right: right}) do
    PreparedAction
    |> where(
      [prepared_action],
      prepared_action.user_id == ^user_id and prepared_action.action_type == "merge_people" and
        prepared_action.status in ["awaiting_confirmation", "confirmed", "executed", "rejected"]
    )
    |> where(
      [prepared_action],
      (prepared_action.payload_surviving_person_id == ^left.id and
         prepared_action.payload_merged_person_id == ^right.id) or
        (prepared_action.payload_surviving_person_id == ^right.id and
           prepared_action.payload_merged_person_id == ^left.id) or
        (is_nil(prepared_action.payload_encryption_version) and
           ((fragment("?->>'surviving_person_id' = ?", prepared_action.legacy_payload, ^left.id) and
               fragment("?->>'merged_person_id' = ?", prepared_action.legacy_payload, ^right.id)) or
              (fragment(
                 "?->>'surviving_person_id' = ?",
                 prepared_action.legacy_payload,
                 ^right.id
               ) and
                 fragment("?->>'merged_person_id' = ?", prepared_action.legacy_payload, ^left.id))))
    )
    |> Repo.exists?()
  end

  # ---------------------------------------------------------------------------
  # Model judgment (R9)
  # ---------------------------------------------------------------------------

  defp judge_pairs(_user_id, [], _opts), do: []

  defp judge_pairs(user_id, pairs, opts) do
    params = %{
      "messages" => [%{"role" => "user", "content" => build_prompt(user_id, pairs)}],
      "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
      "temperature" => 0.0,
      "reasoning_effort" => "none"
    }

    with {:ok, response} <- complete(params, opts),
         {:ok, content} <- response_content(response),
         {:ok, decoded} <- decode_response(content) do
      judgments_by_index =
        decoded
        |> Map.get("judgments", [])
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.reduce(%{}, fn judgment, acc ->
          case Map.get(judgment, "pair_index") do
            index when is_integer(index) -> Map.put(acc, index, judgment)
            _other -> acc
          end
        end)

      pairs
      |> Enum.with_index()
      |> Enum.map(fn {pair, index} ->
        judgment = Map.get(judgments_by_index, index, %{})

        %{
          left: pair.left,
          right: pair.right,
          similarity: pair.similarity,
          same_person: Map.get(judgment, "same_person") == true,
          confidence: read_float(judgment, "confidence"),
          evidence: read_string(judgment, "evidence"),
          rationale: read_string(judgment, "rationale")
        }
      end)
    else
      {:error, reason} ->
        Logger.warning("person_merge_suggestions model judgment failed",
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        []
    end
  end

  defp build_prompt(user_id, pairs) do
    offset_hours = timezone_offset_hours(user_id)

    items =
      pairs
      |> Enum.with_index()
      |> Enum.map(fn {pair, index} ->
        %{
          "pair_index" => index,
          "embedding_similarity" => Float.round(pair.similarity * 1.0, 3),
          "person_a" => serialize_person_for_prompt(pair.left, offset_hours),
          "person_b" => serialize_person_for_prompt(pair.right, offset_hours)
        }
      end)

    """
    PERSON_MERGE_JUDGMENT_JSON_V1

    You judge whether two CRM person records describe the same real person.
    These pairs were flagged only by embedding similarity — semantic
    closeness is NOT evidence of sameness. Two distinct real people at the
    same company or in the same family, with similar names, are a common
    false positive. Look for actual evidence of sameness: shared work
    threads, explicit self-reference, matching secondary details
    (relationship, notes, communication channel history). A partial record
    pair like "Dan" (Slack only) and "Dan Bourke" (email only) is the
    intended catch when the surrounding context clearly describes one
    person.

    Timestamps below are the user's local time.

    Rules:
    - same_person true requires concrete evidence, stated in `evidence`.
    - When the records could plausibly be two different people, answer
      same_person false with low confidence. Do not hedge with medium
      confidence — an uncertain pair must be suppressed, not surfaced.
    - Return ONLY valid JSON. No markdown.

    Return JSON shaped like:
    {"judgments": [{"pair_index": 0, "same_person": false, "confidence": 0.0,
      "evidence": "short concrete evidence", "rationale": "one sentence"}]}

    PAIRS_JSON:
    #{Jason.encode!(items)}
    """
  end

  defp serialize_person_for_prompt(%Person{} = person, offset_hours) do
    %{
      "id" => person.id,
      "display_name" => person.display_name,
      "first_name" => person.first_name,
      "last_name" => person.last_name,
      "relationship" => person.relationship,
      "preferred_communication_method" => person.preferred_communication_method,
      "communication_frequency" => person.communication_frequency,
      "contact_details" =>
        (person.contact_details || %{}) |> Map.take(~w(emails phones slack_ids telegram_ids)),
      "notes" => person.notes,
      "interaction_count" => person.interaction_count,
      "relationship_strength" => person.relationship_strength,
      "last_interaction_at_local" => local_iso(person.last_interaction_at, offset_hours)
    }
  end

  defp timezone_offset_hours(user_id) do
    user_id
    |> BriefingSchedules.summarize_for_prompt()
    |> Map.get(:timezone_offset_hours, -5)
  rescue
    _error -> -5
  end

  defp local_iso(%DateTime{} = datetime, offset_hours) do
    datetime
    |> DateTime.add(offset_hours, :hour)
    |> DateTime.to_iso8601()
  end

  defp local_iso(_datetime, _offset_hours), do: nil

  # ---------------------------------------------------------------------------
  # Proposal (R10) — PreparedAction only, never Crm.merge_people/4
  # ---------------------------------------------------------------------------

  defp propose(user_id, judgment) do
    {survivor, duplicate} = order_pair(judgment.left, judgment.right)

    case ConnectedAccounts.telegram_destination(user_id) do
      nil ->
        Logger.info(
          "person_merge_suggestions skipped proposal (no telegram destination) " <>
            "user_id=#{user_id} surviving=#{survivor.id} merged=#{duplicate.id}"
        )

        {:skip, :no_telegram_destination}

      chat_id ->
        create_prepared_merge(user_id, chat_id, survivor, duplicate, judgment)
    end
  end

  defp create_prepared_merge(user_id, chat_id, survivor, duplicate, judgment) do
    with {:ok, conversation} <-
           TelegramConversations.start_or_continue(user_id, chat_id, %{
             "surface" => "telegram",
             "metadata" => %{"mode" => "assistant"}
           }),
         {:ok, run} <- create_suggestion_run(conversation),
         {:ok, prepared_action} <-
           TelegramAssistant.create_prepared_action(%{
             user_id: user_id,
             chat_id: chat_id,
             conversation_id: conversation.id,
             run_id: run.id,
             surface: "telegram",
             action_type: "merge_people",
             target_type: "crm_person",
             target_id: survivor.id,
             payload: %{
               "user_id" => user_id,
               "surviving_person_id" => survivor.id,
               "merged_person_id" => duplicate.id,
               "evidence" => judgment.evidence,
               "model_rationale" => judgment.rationale || judgment.evidence,
               "performed_by" => "person_merge_suggestions"
             },
             preview_text: preview_text(survivor, duplicate, judgment),
             status: "awaiting_confirmation",
             expires_at:
               DateTime.add(
                 DateTime.utc_now(),
                 TelegramAssistant.confirmation_window_seconds(),
                 :second
               )
           }) do
      _ = TelegramAssistant.mark_conversation_awaiting_action(conversation, prepared_action)
      _ = stamp_suggestion_markers(survivor, duplicate, judgment)
      _ = send_suggestion_card(chat_id, prepared_action)

      Logger.info(
        "person_merge_suggestions proposed merge surviving=#{survivor.id} " <>
          "merged=#{duplicate.id} confidence=#{judgment.confidence}"
      )

      {:ok, prepared_action}
    end
  end

  defp create_suggestion_run(conversation) do
    now = DateTime.utc_now()

    TelegramAssistant.start_run(%{
      user_id: conversation.user_id,
      chat_id: conversation.chat_id,
      conversation_id: conversation.id,
      surface: "telegram",
      trigger_type: "follow_up",
      status: "completed",
      model_provider: "deterministic",
      model_name: "person_merge_suggestion",
      prompt_snapshot: %{},
      result_summary: %{surface: "telegram", message_class: "person_merge_suggestion"},
      started_at: now,
      finished_at: now
    })
  end

  defp preview_text(survivor, duplicate, judgment) do
    """
    <b>Possible duplicate people</b>

    “#{escape_html(duplicate.display_name || duplicate.id)}” looks like the same person as “#{escape_html(survivor.display_name || survivor.id)}”.

    #{escape_html(judgment.evidence || "")}

    Merge them into “#{escape_html(survivor.display_name || survivor.id)}”? Merging is permanent.
    """
    |> String.trim()
  end

  defp escape_html(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_html(value), do: to_string(value)

  # SPEC 04 R11: stamp a pending candidate marker on both people so the
  # get_person/get_relationship_context read path can surface the other
  # half-record ("possible_duplicate") before any merge is confirmed.
  defp stamp_suggestion_markers(survivor, duplicate, judgment) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.each([{survivor, duplicate}, {duplicate, survivor}], fn {person, other} ->
      metadata =
        (person.metadata || %{})
        |> Map.put("merge_suggestion", %{
          "other_person_id" => other.id,
          "other_display_name" => other.display_name,
          "evidence" => judgment.evidence,
          "status" => "pending",
          "suggested_at" => now
        })

      _ =
        person
        |> Ecto.Changeset.change(%{metadata: metadata})
        |> Repo.update()
    end)

    :ok
  end

  defp send_suggestion_card(chat_id, prepared_action) do
    TelegramResponder.send(chat_id, prepared_action.preview_text,
      parse_mode: "HTML",
      reply_markup: TelegramResponder.action_markup(prepared_action.id)
    )
  end

  # Same survivor ordering the deduper uses: keep the stronger record.
  defp order_pair(%Person{} = left, %Person{} = right) do
    if survivor_score(left) >= survivor_score(right) do
      {left, right}
    else
      {right, left}
    end
  end

  defp survivor_score(%Person{} = person) do
    [
      person.relationship_strength || 0,
      person.communication_score || 0,
      person.interaction_count || 0,
      contact_value_count(person.contact_details || %{}),
      datetime_score(person.updated_at),
      person.display_name || ""
    ]
  end

  defp contact_value_count(contact_details) do
    contact_details
    |> Map.take(@identifier_kinds)
    |> Map.values()
    |> List.flatten()
    |> Enum.count(&is_binary/1)
  end

  defp datetime_score(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_score(_datetime), do: 0

  # ---------------------------------------------------------------------------
  # LLM plumbing
  # ---------------------------------------------------------------------------

  defp complete(params, opts) do
    cond do
      is_function(Keyword.get(opts, :llm_complete), 1) ->
        Keyword.fetch!(opts, :llm_complete).(params)

      is_function(configured_llm_complete(), 1) ->
        configured_llm_complete().(params)

      true ->
        LLM.complete(params)
    end
  end

  defp configured_llm_complete do
    :maraithon
    |> Application.get_env(:person_merge_suggestions, [])
    |> Keyword.get(:llm_complete)
  end

  defp response_content(%{content: content}) when is_binary(content), do: {:ok, content}
  defp response_content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  defp response_content(content) when is_binary(content), do: {:ok, content}
  defp response_content(_response), do: {:error, :merge_suggestion_missing_content}

  defp decode_response(content) do
    trimmed =
      content
      |> String.trim()
      |> String.trim_leading("```json")
      |> String.trim_leading("```")
      |> String.trim_trailing("```")
      |> String.trim()

    case Jason.decode(trimmed) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :merge_suggestion_invalid_json}
    end
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp read_float(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      _other -> 0.0
    end
  end
end
