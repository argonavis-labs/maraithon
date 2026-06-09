defmodule Maraithon.Todos.SignalGate do
  @moduledoc """
  Admission gate for durable open-work writes.

  Candidate generators can be broad. This module is deliberately stricter:
  a busy executive should only see saved work items that have source-backed
  action evidence, a clear owner/waiting party, or a concrete consequence.
  """

  alias Maraithon.Insights.Insight

  @closed_insight_statuses ~w(acknowledged dismissed snoozed)
  @closed_completion_statuses ~w(
    already_done canceled cancelled closed completed declined done hired no_action no_longer_needed
    not_needed rejected replied resolved sent completed_or_closed
  )
  @open_completion_statuses ~w(needs_action open pending still_open unresolved waiting_on_user)
  @completion_checked_skill_ids ~w(commitment_tracker followthrough)
  @weak_local_detectors ~w(cold_thread calendar_conflict)
  @drop_importance ~w(drop digest)
  @admission_directions ~w(i_owe asked_of_me pending_reply user_owes waiting_on_user waiting_on_me)
  @admission_obligations ~w(
    direct_request reply_owed asked_of_me i_owe operator_commitment commitment
    deadline deliverable approval_required decision_required payment_blocker blocker
    personal_logistic family_logistic business_obligation
  )
  @high_impact_fyi_classes ~w(
    account_risk security_risk production_risk customer_risk compliance_risk
    app_review_blocker payment_blocker launch_blocker
  )
  @content_terms [
    "article",
    "course",
    "digest",
    "educational",
    "essay",
    "learning material",
    "market commentary",
    "newsletter",
    "podcast",
    "report",
    "video",
    "webinar"
  ]
  @passive_status_terms [
    "completed processing",
    "fyi",
    "has completed processing",
    "informational update",
    "notification",
    "processing completed",
    "status change",
    "status changed",
    "status update"
  ]
  @passive_monitor_terms [
    "acknowledge",
    "keep an eye",
    "monitor",
    "no action required",
    "stay aware",
    "step in only if",
    "watch for"
  ]
  @concrete_status_action_terms [
    "action required",
    "approve",
    "approval required",
    "blocked",
    "deadline",
    "decide",
    "decision required",
    "due ",
    "fix",
    "pay",
    "reply",
    "requires action",
    "resubmit",
    "respond",
    "schedule",
    "submit",
    "unblock"
  ]
  @action_phrases [
    "asked you",
    "awaiting your",
    "blocked on you",
    "can you",
    "could you",
    "deadline",
    "decision from you",
    "due ",
    "needs your approval",
    "needs your decision",
    "please review",
    "please send",
    "reply owed",
    "waiting for you",
    "waiting on you",
    "you committed",
    "you need to",
    "you owe"
  ]

  def partition_candidates(candidates) when is_list(candidates) do
    Enum.reduce(candidates, {[], []}, fn candidate, {allowed, skipped} ->
      case allow_candidate?(candidate) do
        {:ok, normalized} ->
          {[normalized | allowed], skipped}

        {:skip, reason} ->
          {allowed, [%{candidate: candidate, reason: reason} | skipped]}
      end
    end)
    |> then(fn {allowed, skipped} -> {Enum.reverse(allowed), Enum.reverse(skipped)} end)
  end

  def partition_candidates(_candidates), do: {[], []}

  def skip_reason(candidate, proposed_attrs \\ %{}) do
    case allow_candidate?(candidate, proposed_attrs) do
      {:ok, _attrs} -> nil
      {:skip, reason} -> reason
    end
  end

  def allow_candidate?(candidate, proposed_attrs \\ %{})

  def allow_candidate?(candidate, proposed_attrs)
      when is_map(candidate) and is_map(proposed_attrs) do
    attrs =
      candidate
      |> stringify_keys()
      |> deep_merge(proposed_attrs |> stringify_keys())

    cond do
      completed_or_closed?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: source reconciliation says this loop is already done or closed."}

      explicitly_unsurfaceable?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: surface-quality check says this item lacks enough human, source, or action context to be useful."}

      requires_completion_check?(attrs) and not completion_verified_open?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: no explicit source reconciliation proves this loop is still open."}

      weak_local_pattern?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: local pattern detectors stay out of durable work unless promoted by explicit source-backed action evidence."}

      drop_importance?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: candidate is marked digest/drop, not durable open work."}

      content_consumption?(attrs) and not admission_signal?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: content or educational material without a direct obligation."}

      passive_status_monitor?(attrs) and not concrete_status_action?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: passive status/FYI update with no concrete operator action."}

      high_impact_operational_risk?(attrs) ->
        {:ok, attrs}

      admission_signal?(attrs) and executive_grade?(attrs) ->
        {:ok, attrs}

      true ->
        {:skip,
         "Skipped by executive signal gate: missing a direct ask, promise, deadline, waiting counterparty, or concrete consequence."}
    end
  end

  def allow_candidate?(_candidate, _proposed_attrs) do
    {:skip, "Skipped by executive signal gate: invalid candidate."}
  end

  def allow_insight?(%Insight{status: status}) when status in @closed_insight_statuses,
    do: {:ok, :closed_status}

  def allow_insight?(%Insight{} = insight) do
    allow_candidate?(%{
      "source" => insight.source,
      "category" => insight.category,
      "title" => insight.title,
      "summary" => insight.summary,
      "next_action" => insight.recommended_action,
      "recommended_action" => insight.recommended_action,
      "due_at" => insight.due_at,
      "priority" => insight.priority,
      "confidence" => insight.confidence,
      "source_item_id" => insight.source_id,
      "source_occurred_at" => insight.source_occurred_at,
      "dedupe_key" => insight.dedupe_key,
      "tracking_key" => insight.tracking_key,
      "metadata" => insight.metadata || %{}
    })
  end

  def allow_insight?(_insight), do: {:skip, "Skipped by executive signal gate: invalid insight."}

  defp completed_or_closed?(attrs) do
    completion_status(attrs) in @closed_completion_statuses
  end

  defp completion_verified_open?(attrs) do
    completion_status(attrs) in @open_completion_statuses
  end

  defp completion_status(attrs) do
    metadata = read_map(attrs, "metadata")
    check = read_map(metadata, "completion_check")

    [
      read_string(check, "status", nil),
      read_string(metadata, "completion_status", nil),
      read_string(metadata, "status_after_reconciliation", nil)
    ]
    |> Enum.find(&present?/1)
    |> normalize_status()
  end

  defp explicitly_unsurfaceable?(attrs) do
    attrs
    |> read_map("metadata")
    |> read_map("surface_quality")
    |> case do
      quality when quality == %{} -> false
      quality -> read_value(quality, "surfaceable") == false
    end
  end

  defp requires_completion_check?(attrs) do
    metadata = read_map(attrs, "metadata")

    read_string(attrs, "source", nil) == "chief_of_staff_commitment_tracker" or
      read_string(metadata, "origin_skill_id", nil) in @completion_checked_skill_ids or
      read_string(metadata, "origin_cadence", nil) in @completion_checked_skill_ids
  end

  defp weak_local_pattern?(attrs) do
    read_string(attrs, "source", nil) == "local_patterns" and
      read_string(read_map(attrs, "metadata"), "detector", nil) in @weak_local_detectors and
      not promoted_by_explicit_evidence?(attrs)
  end

  defp promoted_by_explicit_evidence?(attrs) do
    metadata = read_map(attrs, "metadata")

    truthy?(read_value(metadata, "force_todo")) or
      read_string(metadata, "work_item_admission", nil) == "explicit_source_obligation"
  end

  defp drop_importance?(attrs) do
    metadata = read_map(attrs, "metadata")

    read_string(metadata, "importance", nil) in @drop_importance or
      read_string(metadata, "importance_hint", nil) in @drop_importance
  end

  defp content_consumption?(attrs) do
    text = text_blob(attrs)
    Enum.any?(@content_terms, &String.contains?(text, &1))
  end

  defp passive_status_monitor?(attrs) do
    text = text_blob(attrs)

    Enum.any?(@passive_status_terms, &String.contains?(text, &1)) and
      Enum.any?(@passive_monitor_terms, &String.contains?(text, &1))
  end

  defp concrete_status_action?(attrs) do
    metadata = read_map(attrs, "metadata")
    fyi_class = read_string(metadata, "fyi_class", nil)
    text = text_blob(attrs)

    strong_metadata_action?(metadata) or
      fyi_class in @high_impact_fyi_classes or
      Enum.any?(@concrete_status_action_terms, &String.contains?(text, &1))
  end

  defp high_impact_operational_risk?(attrs) do
    metadata = read_map(attrs, "metadata")
    fyi_class = read_string(metadata, "fyi_class", nil)
    score = read_float(metadata, "telegram_fit_score", read_float(attrs, "confidence", 0.0))

    fyi_class in @high_impact_fyi_classes and score >= 0.8 and source_backed?(attrs)
  end

  defp admission_signal?(attrs) do
    metadata = read_map(attrs, "metadata")
    record = read_map(metadata, "record")
    conversation = read_map(metadata, "conversation_context")

    truthy?(read_value(metadata, "direct_ask")) or
      truthy?(read_value(metadata, "reply_obligation")) or
      truthy?(read_value(metadata, "explicit_user_commitment")) or
      truthy?(read_value(metadata, "missing_followthrough_evidence")) or
      read_string(metadata, "commitment_direction", nil) in @admission_directions or
      read_string(metadata, "obligation_type", nil) in @admission_obligations or
      (read_string(record, "status", nil) == "unresolved" and
         present?(read_value(record, "commitment"))) or
      (read_string(conversation, "notification_posture", nil) == "interrupt_now" and
         read_string(conversation, "ownership_state", nil) == "user_owner") or
      text_has_action_phrase?(attrs)
  end

  defp strong_metadata_action?(metadata) do
    truthy?(read_value(metadata, "direct_ask")) or
      truthy?(read_value(metadata, "reply_obligation")) or
      truthy?(read_value(metadata, "explicit_user_commitment")) or
      read_string(metadata, "obligation_type", nil) in [
        "approval_required",
        "blocker",
        "deadline",
        "decision_required",
        "deliverable",
        "payment_blocker"
      ]
  end

  defp executive_grade?(attrs) do
    source_backed?(attrs) and
      confidence_ok?(attrs) and
      false_positive_risk_ok?(attrs)
  end

  defp source_backed?(attrs) do
    metadata = read_map(attrs, "metadata")

    present?(read_value(attrs, "source_item_id")) or
      present?(read_value(attrs, "tracking_key")) or
      present?(read_value(attrs, "dedupe_key")) or
      any_present?(
        metadata,
        ~w(body_excerpt checked_evidence evidence quote source_evidence source_ref thread_id)
      ) or
      any_present?(read_map(metadata, "record"), ~w(commitment evidence source))
  end

  defp confidence_ok?(attrs) do
    metadata = read_map(attrs, "metadata")

    case first_float([read_value(attrs, "confidence"), read_value(metadata, "confidence")]) do
      nil -> true
      confidence -> confidence >= 0.65
    end
  end

  defp false_positive_risk_ok?(attrs) do
    metadata = read_map(attrs, "metadata")

    case read_float(metadata, "false_positive_risk", nil) do
      nil -> true
      risk -> risk <= 0.35
    end
  end

  defp text_has_action_phrase?(attrs) do
    text = text_blob(attrs)
    Enum.any?(@action_phrases, &String.contains?(text, &1))
  end

  defp text_blob(attrs) do
    metadata = read_map(attrs, "metadata")
    record = read_map(metadata, "record")

    [
      read_value(attrs, "title"),
      read_value(attrs, "summary"),
      read_value(attrs, "next_action"),
      read_value(attrs, "recommended_action"),
      read_value(attrs, "notes"),
      read_value(attrs, "action_plan"),
      read_value(metadata, "why_now"),
      read_value(metadata, "why_it_matters"),
      read_value(metadata, "body_excerpt"),
      read_value(metadata, "decision_reason"),
      read_value(record, "commitment"),
      read_value(record, "next_action")
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_nested(value) when is_map(value), do: stringify_keys(value)
  defp stringify_nested(value) when is_list(value), do: Enum.map(value, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp read_map(map, key) when is_map(map) do
    case read_value(map, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_string(map, key, default) when is_map(map) do
    case read_value(map, key) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> default
          trimmed -> trimmed
        end

      value when is_atom(value) ->
        Atom.to_string(value)

      _other ->
        default
    end
  end

  defp read_string(_map, _key, default), do: default

  defp read_float(map, key, default) when is_map(map) do
    case read_value(map, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value, default)
      _other -> default
    end
  end

  defp read_float(_map, _key, default), do: default

  defp read_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp read_value(_map, _key), do: nil

  defp first_float(values) do
    Enum.find_value(values, fn
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value, nil)
      _other -> nil
    end)
  end

  defp parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp normalize_status(nil), do: nil

  defp normalize_status(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp any_present?(map, keys) when is_map(map) do
    Enum.any?(keys, &present?(read_value(map, &1)))
  end

  defp any_present?(_map, _keys), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(value), do: not is_nil(value)

  defp blank?(value), do: not present?(value)
end
