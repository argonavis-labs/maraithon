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
  @local_message_sources ~w(imessage messages local_messages)
  @drop_importance ~w(drop digest)
  @high_impact_fyi_classes ~w(
    account_risk security_risk production_risk customer_risk compliance_risk
    app_review_blocker payment_blocker launch_blocker
  )
  # Unambiguous consumption vocabulary only. Bare "report"/"video"/
  # "course"/"article" vetoed real deliverable work ("prepare the board
  # report", "edit the launch video", "of course", "Article 5").
  @content_terms [
    "blog post",
    "digest",
    "educational",
    "essay",
    "learning material",
    "market commentary",
    "newsletter",
    "online course",
    "podcast",
    "read this article",
    "watch this video",
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
  @ephemeral_credential_terms [
    "activation code",
    "authentication code",
    "confirmation code",
    "download code",
    "gift code",
    "login code",
    "one-time code",
    "one time code",
    "one-time passcode",
    "one time passcode",
    "one-time password",
    "one time password",
    "otp",
    "passcode",
    "recovery code",
    "redeem code",
    "security code",
    "sign-in code",
    "signin code",
    "temporary passcode",
    "verification code"
  ]
  @ephemeral_delivery_terms [
    "code expires",
    "do not share this code",
    "don't share this code",
    "enter the code below",
    "enter this code",
    "expires in",
    "never share this code",
    "use this code",
    "valid for",
    "your authentication code",
    "your confirmation code",
    "your login code",
    "your security code",
    "your sign-in code",
    "your verification code"
  ]
  @security_incident_terms [
    "account compromised",
    "account locked",
    "password change you did not request",
    "password changed without your permission",
    "suspicious login",
    "suspicious sign-in",
    "unauthorized login",
    "unauthorized password change",
    "unauthorized sign-in",
    "unrecognized login",
    "unrecognized sign-in"
  ]
  @credential_system_work_terms [
    "bug",
    "broken",
    "delivery",
    "feature",
    "flow",
    "implementation",
    "integration",
    "issue",
    "support ticket",
    "test",
    "testing"
  ]
  @no_action_notification_terms [
    "for informational purposes",
    "for your reference",
    "for your records",
    "no action is needed",
    "no action is required",
    "no action needed",
    "no action required",
    "no further action",
    "nothing you need to do",
    "you do not need to do anything",
    "you don't need to do anything"
  ]
  @completed_transaction_terms [
    "booking confirmation",
    "booking confirmed",
    "invoice attached",
    "monthly statement",
    "order confirmation",
    "order confirmed",
    "payment confirmation",
    "payment received",
    "payment successful",
    "payment was successful",
    "purchase confirmation",
    "purchase confirmed",
    "receipt attached",
    "receipt for your",
    "refund issued",
    "refund processed",
    "registration confirmed",
    "renewal confirmation",
    "reservation confirmed",
    "statement is ready",
    "subscription renewed",
    "we received your payment"
  ]
  @routine_delivery_terms [
    "arriving today",
    "arriving tomorrow",
    "delivery update",
    "has been delivered",
    "has shipped",
    "order delivered",
    "order shipped",
    "out for delivery",
    "package delivered",
    "tracking update",
    "was delivered",
    "was shipped"
  ]
  @routine_engagement_terms [
    "liked your post",
    "liked your update",
    "new connection suggestion",
    "new follower",
    "people you may know",
    "reacted to your message",
    "reacted to your post",
    "recommended for you",
    "started following you",
    "viewed your profile"
  ]
  @routine_marketing_terms [
    "limited time offer",
    "limited-time offer",
    "new arrivals",
    "rate your experience",
    "shop now",
    "special offer",
    "tell us how we did",
    "upgrade now"
  ]
  @routine_calendar_terms [
    "event reminder",
    "meeting reminder",
    "reminder: your event",
    "starts in 10 minutes",
    "starts in 15 minutes",
    "starts in 30 minutes",
    "starting soon"
  ]
  @material_action_phrases [
    "action required",
    "are you able to",
    "asked you",
    "blocked on you",
    "can you",
    "cannot proceed",
    "can't proceed",
    "confirm your address",
    "confirm your identity",
    "corrected receipt",
    "could you",
    "due by",
    "due on",
    "needs your approval",
    "needs your decision",
    "past due",
    "payment declined",
    "payment failed",
    "please approve",
    "please dm",
    "please pay",
    "please reply",
    "please review",
    "please send",
    "please sign",
    "please submit",
    "requires action",
    "respond by",
    "reply by",
    "approve by",
    "decide by",
    "fix by",
    "pay by",
    "rebook by",
    "register by",
    "reschedule by",
    "return by",
    "rsvp by",
    "send by",
    "sign by",
    "submit by",
    "upload by",
    "update your payment",
    "verify your identity",
    "waiting for you",
    "waiting on you",
    "will be disabled",
    "will be frozen",
    "will be suspended",
    "you committed",
    "you owe"
  ]
  @self_commitment_phrases [
    "i am going to",
    "i promised",
    "i will",
    "i'll",
    "i’m going to",
    "i’ll"
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
  @local_source_action_phrases [
    "are you able to",
    "asked if you can",
    "asked whether you can",
    "asked you",
    "can you",
    "could you",
    "for you to",
    "if you can",
    "i can",
    "i will",
    "i'll",
    "i’ll",
    "need you to",
    "needs you to",
    "please",
    "waiting for you",
    "waiting on you",
    "will you",
    "would you",
    "you need to",
    "you promised",
    "you said you would"
  ]
  @local_source_action_terms ~w(
    approve book deadline decide due pay register reply reschedule return rsvp schedule send sign
    submit unblock
  )

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
    source_attrs = stringify_keys(candidate)
    attrs = deep_merge(source_attrs, stringify_keys(proposed_attrs))

    cond do
      completed_or_closed?(source_attrs) ->
        {:skip,
         "Skipped by executive signal gate: source reconciliation says this loop is already done or closed."}

      explicitly_unsurfaceable?(source_attrs) or explicitly_unsurfaceable?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: surface-quality check says this item lacks enough human, source, or action context to be useful."}

      requires_completion_check?(source_attrs) and not completion_verified_open?(source_attrs) ->
        {:skip,
         "Skipped by executive signal gate: no explicit source reconciliation proves this loop is still open."}

      weak_local_message_chatter?(source_attrs) ->
        {:skip,
         "Skipped by executive signal gate: local-message source evidence does not contain an explicit operator ask, promise, deadline, or concrete logistics action."}

      weak_local_pattern?(source_attrs) ->
        {:skip,
         "Skipped by executive signal gate: local pattern detectors stay out of durable work unless promoted by explicit source-backed action evidence."}

      drop_importance?(source_attrs) or drop_importance?(attrs) ->
        {:skip,
         "Skipped by executive signal gate: candidate is marked digest/drop, not durable open work."}

      ephemeral_credential_notification?(source_attrs) ->
        {:skip,
         "Skipped by executive signal gate: one-time authentication credentials are transient notifications, not durable open work."}

      routine_noise_notification?(source_attrs) ->
        {:skip,
         "Skipped by executive signal gate: routine transactional, delivery, engagement, or reminder notification with no important action."}

      content_consumption?(source_attrs) and not protected_source_action?(source_attrs) ->
        {:skip,
         "Skipped by executive signal gate: content or educational material without a direct obligation."}

      passive_status_monitor?(source_attrs) and not protected_source_action?(source_attrs) ->
        {:skip,
         "Skipped by executive signal gate: passive status/FYI update with no concrete operator action."}

      high_impact_operational_risk?(source_attrs) ->
        {:ok, attrs}

      source_requires_action?(source_attrs) and executive_grade?(attrs, source_attrs) ->
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

  def allow_insight?(%Insight{status: "candidate"}) do
    {:skip, "Skipped by executive signal gate: heuristic insight awaits model promotion."}
  end

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

  defp weak_local_message_chatter?(attrs) do
    read_string(attrs, "source", nil) in @local_message_sources and
      present?(source_evidence_text(attrs)) and
      not strong_local_source_action_evidence?(attrs)
  end

  defp strong_local_source_action_evidence?(attrs) do
    metadata = read_map(attrs, "metadata")

    truthy?(read_value(metadata, "force_todo")) or
      read_string(metadata, "work_item_admission", nil) == "explicit_source_obligation" or
      local_source_text_has_action?(source_evidence_text(attrs))
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

  defp ephemeral_credential_notification?(attrs) do
    evidence =
      [read_string(attrs, "title", nil), trusted_source_text(attrs)]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
      |> String.downcase()

    credential? = Enum.any?(@ephemeral_credential_terms, &gate_term_present?(evidence, &1))
    delivery? = Enum.any?(@ephemeral_delivery_terms, &String.contains?(evidence, &1))
    short_lived? = Regex.match?(~r/(?<!\d)\d{4,8}(?!\d)/u, evidence)
    source = read_string(attrs, "source", nil)
    human_work_request? = local_source_text_has_action?(evidence)

    system_work? =
      human_work_request? and
        Enum.any?(@credential_system_work_terms, &gate_term_present?(evidence, &1))

    intrinsically_ephemeral? =
      Enum.any?(
        [
          "one-time code",
          "one time code",
          "one-time passcode",
          "one time passcode",
          "one-time password",
          "one time password",
          "otp"
        ],
        &gate_term_present?(evidence, &1)
      )

    automated_email_shape? =
      source in ["email", "gmail"] and not human_work_request?

    credential? and not security_incident?(evidence) and not system_work? and
      (intrinsically_ephemeral? or short_lived? or delivery? or automated_email_shape?)
  end

  defp security_incident?(text) when is_binary(text) do
    Enum.any?(@security_incident_terms, &String.contains?(text, &1))
  end

  defp routine_noise_notification?(attrs) do
    text = trusted_source_text(attrs)

    routine? =
      Enum.any?(@no_action_notification_terms, &String.contains?(text, &1)) or
        Enum.any?(@completed_transaction_terms, &String.contains?(text, &1)) or
        Enum.any?(@routine_delivery_terms, &String.contains?(text, &1)) or
        Enum.any?(@routine_engagement_terms, &String.contains?(text, &1)) or
        Enum.any?(@routine_marketing_terms, &String.contains?(text, &1)) or
        Enum.any?(@routine_calendar_terms, &String.contains?(text, &1))

    routine? and not material_source_action?(text)
  end

  defp protected_source_action?(attrs) do
    user_requested_reminder?(attrs) or material_source_action?(trusted_source_text(attrs))
  end

  defp source_requires_action?(attrs) do
    text = trusted_source_text(attrs)

    user_requested_reminder?(attrs) or trusted_specialized_action?(attrs) or
      self_authored_commitment?(attrs, text) or material_source_action?(text)
  end

  defp self_authored_commitment?(attrs, text) do
    metadata = read_map(attrs, "metadata")
    check = read_map(metadata, "completion_check")

    self_authored? =
      truthy?(read_value(metadata, "is_from_me")) or
        read_string(metadata, "source_direction", nil) in ["outbound", "sent"] or
        (read_string(metadata, "origin_skill_id", nil) == "commitment_tracker" and
           truthy?(read_value(metadata, "explicit_user_commitment")) and
           read_string(check, "status", nil) in @open_completion_statuses)

    self_authored? and Enum.any?(@self_commitment_phrases, &String.contains?(text, &1))
  end

  defp material_source_action?(text) when is_binary(text) do
    action_text =
      text
      |> strip_no_action_phrases()
      |> strip_routine_boilerplate()

    security_incident?(action_text) or
      Enum.any?(@material_action_phrases, &String.contains?(action_text, &1)) or
      Regex.match?(
        ~r/\b(?:due|needed|required|must be (?:sent|submitted|signed|paid|returned|confirmed))\s+(?:today|tomorrow|this (?:week|month)|monday|tuesday|wednesday|thursday|friday|saturday|sunday|by \d{1,2}(?:[:\/]\d{1,2})?)\b/iu,
        action_text
      )
  end

  defp strip_no_action_phrases(text) do
    Enum.reduce(@no_action_notification_terms, text, fn term, acc ->
      String.replace(acc, term, "")
    end)
  end

  defp strip_routine_boilerplate(text) do
    text
    |> String.replace(
      ~r/\b(?:do not|don['’]t) reply(?: to this (?:message|email))?[^.\n]*/iu,
      ""
    )
    |> String.replace(
      ~r/\breply (?:to |with )?(?:this (?:message|email) )?to unsubscribe[^.\n]*/iu,
      ""
    )
    |> String.replace(
      ~r/\b(?:unsubscribe|manage (?:email )?preferences|view (?:this email )?in (?:your )?browser|click here)[^.\n]*/iu,
      ""
    )
  end

  defp trusted_source_text(attrs) do
    primary_evidence = primary_source_evidence_text(attrs)

    case primary_evidence do
      "" -> source_evidence_text(attrs)
      text -> text
    end
    |> String.downcase()
  end

  defp primary_source_evidence_text(attrs) do
    metadata = read_map(attrs, "metadata")

    [
      read_value(metadata, "body_excerpt"),
      read_value(metadata, "source_excerpt"),
      read_value(metadata, "source_body"),
      read_value(metadata, "matching_message_excerpt"),
      read_value(metadata, "last_meaningful_message"),
      read_value(metadata, "quote"),
      read_value(metadata, "source_quote"),
      provider_source_record_evidence(metadata)
    ]
    |> Enum.flat_map(&evidence_strings/1)
    |> Enum.take(16)
    |> Enum.join(" ")
    |> String.slice(0, 12_000)
    |> String.downcase()
  end

  defp content_consumption?(attrs) do
    text = trusted_source_text(attrs)
    Enum.any?(@content_terms, &gate_term_present?(text, &1))
  end

  defp passive_status_monitor?(attrs) do
    text = trusted_source_text(attrs)

    Enum.any?(@passive_status_terms, &gate_term_present?(text, &1)) and
      Enum.any?(@passive_monitor_terms, &gate_term_present?(text, &1))
  end

  defp gate_term_present?(text, term) do
    Regex.match?(~r/(?<![\p{L}\p{N}])#{Regex.escape(term)}(?![\p{L}\p{N}])/iu, text)
  end

  defp high_impact_operational_risk?(attrs) do
    metadata = read_map(attrs, "metadata")
    fyi_class = read_string(metadata, "fyi_class", nil)
    score = read_float(metadata, "telegram_fit_score", read_float(attrs, "confidence", 0.0))

    fyi_class in @high_impact_fyi_classes and score >= 0.8 and source_backed?(attrs) and
      protected_source_action?(attrs)
  end

  defp user_requested_reminder?(attrs) do
    metadata = read_map(attrs, "metadata")
    source = read_string(attrs, "source", nil)

    source in ["assistant", "mcp", "telegram", "telegram_assistant", "user"] and
      (truthy?(read_value(metadata, "user_requested")) or
         truthy?(read_value(metadata, "explicit_user_request")))
  end

  defp trusted_specialized_action?(attrs) do
    metadata = read_map(attrs, "metadata")
    source = read_string(attrs, "source", nil)
    priority = read_float(attrs, "priority", 0.0)

    (source == "goals" and
       present?(read_value(attrs, "source_item_id")) and
       present?(read_value(metadata, "goal_review_run_id")) and
       present?(read_value(metadata, "source_refs")) and priority >= 80.0) or
      (source == "chief_of_staff_holiday" and
         present?(read_value(attrs, "source_item_id")) and
         present?(read_value(metadata, "holiday_id")) and
         present?(read_value(metadata, "holiday_date")) and
         read_float(metadata, "holiday_confidence", 0.0) >= 0.85 and priority >= 80.0)
  end

  defp executive_grade?(attrs, source_attrs) do
    source_backed?(source_attrs) and
      confidence_ok?(attrs, source_attrs) and
      false_positive_risk_ok?(source_attrs)
  end

  defp source_backed?(attrs) do
    metadata = read_map(attrs, "metadata")

    present?(read_value(attrs, "source_item_id")) or user_requested_reminder?(attrs) or
      any_present?(
        metadata,
        ~w(
          body_excerpt calendar_event_id holiday_id last_meaningful_message matching_message_excerpt
          message_id quote slack_thread_ts source_body source_excerpt source_quote source_ref
          telegram_message_id thread_id
        )
      )
  end

  defp confidence_ok?(attrs, source_attrs) do
    source_metadata = read_map(source_attrs, "metadata")
    metadata = read_map(attrs, "metadata")

    source_confidence =
      first_float([
        read_value(source_attrs, "confidence"),
        read_value(source_metadata, "confidence"),
        read_value(source_metadata, "holiday_confidence")
      ])

    confidence =
      source_confidence ||
        first_float([read_value(attrs, "confidence"), read_value(metadata, "confidence")])

    is_nil(confidence) or confidence >= 0.65
  end

  defp false_positive_risk_ok?(attrs) do
    metadata = read_map(attrs, "metadata")

    case read_float(metadata, "false_positive_risk", nil) do
      nil -> true
      risk -> risk <= 0.35
    end
  end

  defp source_evidence_text(attrs) do
    metadata = read_map(attrs, "metadata")

    [
      read_value(metadata, "quote"),
      read_value(metadata, "source_quote"),
      read_value(metadata, "source_excerpt"),
      read_value(metadata, "body_excerpt"),
      read_value(metadata, "source_body"),
      read_value(metadata, "matching_message_excerpt"),
      read_value(metadata, "last_meaningful_message"),
      provider_source_record_evidence(metadata)
    ]
    |> Enum.flat_map(&evidence_strings/1)
    |> Enum.take(32)
    |> Enum.join(" ")
    |> String.slice(0, 12_000)
    |> String.downcase()
  end

  # The exact source-account fan-out keeps lossless provider evidence under
  # metadata.source_record so it can hand small sealed partitions between
  # durable jobs without copying an email body or Slack thread into every
  # top-level candidate field. Treat that internal record as trusted source
  # evidence at the final deterministic admission boundary. Without this,
  # valid model create/update decisions are downgraded to skip because the gate
  # cannot see the direct ask that the model just evaluated.
  defp provider_source_record_evidence(metadata) do
    source_record = read_map(metadata, "source_record")

    [
      read_value(source_record, "subject"),
      read_value(source_record, "snippet"),
      read_value(source_record, "body"),
      read_value(source_record, "text"),
      read_value(source_record, "thread_context")
    ]
  end

  defp evidence_strings(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      text -> [String.slice(text, 0, 2_400)]
    end
  end

  defp evidence_strings(value) when is_list(value) do
    value
    |> Enum.take(16)
    |> Enum.flat_map(&evidence_strings/1)
  end

  defp evidence_strings(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.take(16)
    |> Enum.flat_map(&evidence_strings/1)
  end

  defp evidence_strings(_value), do: []

  defp local_source_text_has_action?(text) when is_binary(text) do
    Enum.any?(@local_source_action_phrases, &String.contains?(text, &1)) or
      Enum.any?(@local_source_action_terms, &gate_term_present?(text, &1))
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

      value when is_atom(value) and not is_nil(value) ->
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
