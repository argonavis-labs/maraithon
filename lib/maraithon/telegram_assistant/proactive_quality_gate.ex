defmodule Maraithon.TelegramAssistant.ProactiveQualityGate do
  @moduledoc """
  Feedback-driven quality gate for proactive Telegram copy and delivery plans.

  The model still makes the semantic call, but this gate protects the operator
  from known-bad proactive patterns: stale backlog dumps, false urgency, missing
  prioritization, and business framing for personal/family items.
  """

  alias Maraithon.Todos.AttentionRanker

  @max_iterations 2
  @urgent_terms ~w(urgent immediately immediate now high-priority high priority overdue)
  @work_terms ~w(
    artifact business client customer delivery eta follow-up followup intro meeting pricing
    project reply status work
  )
  @familiar_relationship_strength 90
  @familiar_interaction_count 12
  @frequent_communication ~w(daily weekly frequent often)
  @identity_context_terms ~w(
    advisor agency board client colleague customer founder friend investor partner school
    soccer teammate vendor vc
  )
  @context_stop_words ~w(
    a an and are as at be by do for from has have he her him his i if in is it its me my
    next of on or our she so status that the their them they this to update we who why with you
  )
  @person_line_stop_labels ~w(action context eta next note notes owner status summary todo update why)
  @rubric [
    "personal/family before routine work",
    "new or newly changed items during proactive dayparts",
    "stale low-priority work becomes one confirmation item",
    "named people include the right amount of context in the message unless clearly familiar",
    "personal logistics are not framed as business meeting recaps"
  ]

  def verify_proactive_plan(plan, payload, opts \\ [])
      when is_map(plan) and is_map(payload) and is_list(opts) do
    max_iterations = Keyword.get(opts, :quality_gate_iterations, @max_iterations)
    verify_proactive_plan(plan, payload, 1, max_iterations)
  end

  def verify_delivery_plan(plan, payload, opts \\ [])
      when is_map(plan) and is_map(payload) and is_list(opts) do
    max_iterations = Keyword.get(opts, :quality_gate_iterations, @max_iterations)
    verify_delivery_plan(plan, payload, 1, max_iterations)
  end

  defp verify_proactive_plan(plan, payload, iteration, max_iterations) do
    verify_proactive_plan(plan, payload, iteration, max_iterations, [])
  end

  defp verify_proactive_plan(plan, payload, iteration, max_iterations, prior_findings) do
    findings = proactive_findings(plan, payload)

    cond do
      findings == [] ->
        status = if prior_findings == [], do: "passed", else: "revised"
        put_verification(plan, status, [], iteration, 10, prior_findings)

      iteration >= max_iterations ->
        hold_plan(plan, prior_findings ++ findings, iteration)

      true ->
        revised = revise_proactive_plan(plan, findings, payload)

        if read_field(revised, "decision") == "hold" do
          revised
        else
          verify_proactive_plan(
            revised,
            payload,
            iteration + 1,
            max_iterations,
            prior_findings ++ findings
          )
        end
    end
  end

  defp proactive_findings(plan, payload) do
    decision = read_field(plan, "decision")
    message = read_field(plan, "assistant_message") || ""

    if decision == "send_now" do
      []
      |> maybe_add(:backlog_dump, backlog_dump?(message))
      |> maybe_add(:personal_as_business, personal_as_business?(message))
      |> maybe_add(:stale_urgency_overclaim, stale_urgency_overclaim?(message, payload, plan))
      |> maybe_add(:weekend_work_dump, weekend?(payload) and backlog_dump?(message))
      |> maybe_add(:too_many_stale_confirmations, too_many_stale_confirmations?(payload, plan))
      |> maybe_add(:wrong_order, wrong_todo_order?(payload, plan))
      |> maybe_add(:ignored_personal_calendar, ignored_personal_calendar?(message, payload, plan))
      |> maybe_add(:missing_person_context, missing_person_context?(message, payload, plan))
    else
      []
    end
  end

  defp revise_proactive_plan(plan, findings, payload) do
    stale_todos = stale_confirmation_todos(payload, plan)
    personal_calendar_events = personal_calendar_events(payload)

    cond do
      :ignored_personal_calendar in findings and personal_calendar_events != [] ->
        top_event = List.first(personal_calendar_events)

        plan
        |> Map.put("assistant_message", personal_calendar_message(top_event))
        |> Map.put("message_class", "assistant_push")
        |> Map.put("todo_ids", [])
        |> Map.put("interrupt_now", false)
        |> Map.put("urgency", max(read_float(plan, "urgency", 0.0), 0.62))
        |> Map.put(
          "summary",
          "Feedback verification prioritized a near-term personal calendar event over stale work."
        )

      stale_todos != [] and revision_allowed?(findings) ->
        top_todo = List.first(stale_todos)

        plan
        |> Map.put("assistant_message", stale_confirmation_message(top_todo, length(stale_todos)))
        |> Map.put("message_class", "todo_digest")
        |> Map.put("todo_ids", [todo_id(top_todo)])
        |> Map.put("interrupt_now", false)
        |> Map.put("urgency", min(read_float(plan, "urgency", 0.0), 0.45))
        |> Map.put(
          "summary",
          "Feedback verification rewrote stale backlog into one confirmation."
        )

      :wrong_order in findings and read_field(plan, "message_class") == "todo_digest" ->
        plan
        |> Map.put("todo_ids", ranked_plan_todo_ids(payload, plan))
        |> Map.put("summary", "Feedback verification restored attention-ranked digest order.")

      true ->
        hold_plan(plan, findings, 1)
    end
  end

  defp revision_allowed?(findings) do
    Enum.any?(
      findings,
      &(&1 in [
          :backlog_dump,
          :stale_urgency_overclaim,
          :weekend_work_dump,
          :too_many_stale_confirmations,
          :wrong_order,
          :ignored_personal_calendar,
          :missing_person_context
        ])
    )
  end

  defp verify_delivery_plan(plan, payload, iteration, max_iterations) do
    verify_delivery_plan(plan, payload, iteration, max_iterations, [])
  end

  defp verify_delivery_plan(plan, payload, iteration, max_iterations, prior_findings) do
    {revised_plan, findings} = revise_delivery_plan_once(plan, payload)

    cond do
      findings == [] ->
        status = if prior_findings == [], do: "passed", else: "revised"
        put_verification(revised_plan, status, [], iteration, 10, prior_findings)

      iteration >= max_iterations ->
        all_findings = prior_findings ++ findings

        put_verification(
          revised_plan,
          "revised",
          findings,
          iteration,
          score(all_findings),
          prior_findings
        )

      true ->
        verify_delivery_plan(
          revised_plan,
          payload,
          iteration + 1,
          max_iterations,
          prior_findings ++ findings
        )
    end
  end

  defp revise_delivery_plan_once(plan, payload) do
    candidates_by_id = candidates_by_id(payload)

    {dispositions, findings} =
      plan
      |> read_field("dispositions")
      |> List.wrap()
      |> Enum.map_reduce([], fn disposition, findings ->
        candidate = Map.get(candidates_by_id, read_field(disposition, "candidate_id"))

        {revised, candidate_findings} =
          verify_delivery_disposition(disposition, candidate, payload)

        {revised, findings ++ candidate_findings}
      end)

    {dispositions, findings} =
      protect_attention_order(dispositions, candidates_by_id, findings)

    {dispositions, findings} =
      limit_stale_confirmation_digest(dispositions, candidates_by_id, findings)

    plan =
      plan
      |> Map.put("dispositions", dispositions)
      |> maybe_clear_digest_intro(dispositions)
      |> maybe_neutralize_bad_digest_intro(dispositions, candidates_by_id)

    {plan, findings}
  end

  defp verify_delivery_disposition(disposition, nil, _payload), do: {disposition, []}

  defp verify_delivery_disposition(disposition, candidate, payload) do
    value = read_field(disposition, "disposition")
    body = read_field(candidate, "body") || ""
    profile = read_field(candidate, "attention_profile") || %{}

    cond do
      value in ["interrupt_now", "digest"] and personal_as_business?(body) ->
        {hold_disposition(
           disposition,
           "Feedback verification: personal/family item was framed like a business follow-up."
         ), [:personal_as_business]}

      value in ["interrupt_now", "digest"] and backlog_dump?(body) ->
        {hold_disposition(
           disposition,
           "Feedback verification: held backlog dump instead of sending stale work as urgent."
         ), [:backlog_dump]}

      value in ["interrupt_now", "digest"] and missing_candidate_context?(candidate, payload) ->
        {hold_disposition(
           disposition,
           "Feedback verification: named person needed company, relationship, or why-it-matters context."
         ), [:missing_person_context]}

      value == "interrupt_now" and stale_unprotected?(profile) ->
        revise_stale_delivery_disposition(disposition, body)

      true ->
        {disposition, []}
    end
  end

  defp revise_stale_delivery_disposition(disposition, body) do
    if confirmation_style?(body) do
      {
        disposition
        |> Map.put("disposition", "digest")
        |> Map.put(
          "reason",
          "Feedback verification: stale item should be a confirmation card, not an interruption."
        ),
        [:stale_interrupt]
      }
    else
      {hold_disposition(
         disposition,
         "Feedback verification: stale item lacked confirmation-style copy."
       ), [:stale_interrupt]}
    end
  end

  defp protect_attention_order(dispositions, candidates_by_id, findings) do
    stale_sent =
      dispositions
      |> Enum.filter(&deliverable_disposition?/1)
      |> Enum.filter(fn disposition ->
        candidate = Map.get(candidates_by_id, read_field(disposition, "candidate_id"))
        candidate |> candidate_profile() |> stale_unprotected?()
      end)

    priority_held =
      dispositions
      |> Enum.filter(&(read_field(&1, "disposition") == "hold"))
      |> Enum.filter(fn disposition ->
        candidate = Map.get(candidates_by_id, read_field(disposition, "candidate_id"))
        priority_candidate?(candidate)
      end)
      |> Enum.sort_by(fn disposition ->
        candidate = Map.get(candidates_by_id, read_field(disposition, "candidate_id"))
        priority_candidate_sort_key(candidate)
      end)

    if stale_sent != [] and priority_held != [] do
      promoted_id = priority_held |> List.first() |> read_field("candidate_id")
      stale_ids = MapSet.new(Enum.map(stale_sent, &read_field(&1, "candidate_id")))

      dispositions =
        Enum.map(dispositions, fn disposition ->
          candidate_id = read_field(disposition, "candidate_id")

          cond do
            candidate_id == promoted_id ->
              disposition
              |> Map.put("disposition", "digest")
              |> Map.put(
                "reason",
                "Feedback verification: personal/family or close-relationship item outranks stale work in this cycle."
              )

            MapSet.member?(stale_ids, candidate_id) ->
              hold_disposition(
                disposition,
                "Feedback verification: held stale work because higher-priority personal/family or close-relationship context exists."
              )

            true ->
              disposition
          end
        end)

      {dispositions, findings ++ [:wrong_order]}
    else
      {dispositions, findings}
    end
  end

  defp deliverable_disposition?(disposition) do
    read_field(disposition, "disposition") in ["interrupt_now", "digest"]
  end

  defp priority_candidate?(candidate) when is_map(candidate) do
    bucket =
      candidate
      |> candidate_profile()
      |> read_field("bucket")

    bucket in ["personal_family", "strong_relationship_waiting"]
  end

  defp priority_candidate?(_candidate), do: false

  defp priority_candidate_sort_key(candidate) when is_map(candidate) do
    profile = candidate_profile(candidate)

    {
      read_integer(profile, "bucket_rank", 99),
      -read_integer(profile, "score", 0),
      read_field(candidate, "planning_rank") || 999_999
    }
  end

  defp priority_candidate_sort_key(_candidate), do: {99, 0, 999_999}

  defp candidate_profile(candidate) when is_map(candidate) do
    case read_field(candidate, "attention_profile") do
      profile when is_map(profile) -> profile
      _other -> %{}
    end
  end

  defp candidate_profile(_candidate), do: %{}

  defp limit_stale_confirmation_digest(dispositions, candidates_by_id, findings) do
    {limited, _seen, findings} =
      Enum.reduce(dispositions, {[], false, findings}, fn disposition, {acc, seen?, findings} ->
        candidate = Map.get(candidates_by_id, read_field(disposition, "candidate_id"))

        if read_field(disposition, "disposition") == "digest" and
             stale_unprotected?(read_field(candidate || %{}, "attention_profile") || %{}) do
          if seen? do
            revised =
              hold_disposition(
                disposition,
                "Feedback verification: keep stale backlog to one confirmation item."
              )

            {[revised | acc], seen?, findings ++ [:too_many_stale_confirmations]}
          else
            {[disposition | acc], true, findings}
          end
        else
          {[disposition | acc], seen?, findings}
        end
      end)

    {Enum.reverse(limited), findings}
  end

  defp maybe_clear_digest_intro(plan, dispositions) do
    if Enum.any?(dispositions, &(read_field(&1, "disposition") == "digest")) do
      plan
    else
      Map.put(plan, "digest_intro", "")
    end
  end

  defp maybe_neutralize_bad_digest_intro(plan, dispositions, candidates_by_id) do
    intro = read_field(plan, "digest_intro") || ""

    if backlog_dump?(intro) or personal_as_business?(intro) or
         stale_intro_without_stale_digest?(intro, dispositions, candidates_by_id) do
      Map.put(
        plan,
        "digest_intro",
        replacement_digest_intro(dispositions, candidates_by_id)
      )
    else
      plan
    end
  end

  defp stale_intro_without_stale_digest?(intro, dispositions, candidates_by_id) do
    contains_any?(intro, ~w(overdue stale older follow-up followups follow-ups)) and
      not Enum.any?(dispositions, fn disposition ->
        read_field(disposition, "disposition") == "digest" and
          disposition
          |> read_field("candidate_id")
          |> then(&Map.get(candidates_by_id, &1))
          |> candidate_profile()
          |> stale_unprotected?()
      end)
  end

  defp replacement_digest_intro(dispositions, candidates_by_id) do
    has_personal? =
      Enum.any?(dispositions, fn disposition ->
        read_field(disposition, "disposition") == "digest" and
          disposition
          |> read_field("candidate_id")
          |> then(&Map.get(candidates_by_id, &1))
          |> candidate_profile()
          |> read_field("bucket")
          |> Kernel.==("personal_family")
      end)

    if has_personal? do
      "I grouped the personal/family item that looks worth attention now."
    else
      "I grouped only the item that still looks worth attention now."
    end
  end

  defp hold_disposition(disposition, reason) do
    disposition
    |> Map.put("disposition", "hold")
    |> Map.put("reason", reason)
  end

  defp hold_plan(plan, findings, iteration) do
    plan
    |> Map.put("decision", "hold")
    |> Map.put("assistant_message", "")
    |> Map.put("interrupt_now", false)
    |> Map.put(
      "summary",
      "Feedback verification held this proactive message: #{finding_text(findings)}."
    )
    |> put_verification("held", findings, iteration, score(findings))
  end

  defp stale_confirmation_message(todo, stale_count) do
    context = todo_context(todo)

    if stale_count > 1 do
      [
        "I found older work follow-ups still open, but they look stale rather than urgent.",
        context && "The top one is #{context}.",
        "Mark it important if it still matters, or dismiss it."
      ]
    else
      [
        "This older follow-up has been sitting a while, so I’m not treating it as urgent.",
        context && "It’s #{context}.",
        "Mark it important if it still matters, or dismiss it."
      ]
    end
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp todo_context(todo) do
    profile = AttentionRanker.profile(todo)
    context = read_field(profile, "context") || %{}
    person = read_field(context, "person")

    identity =
      [
        read_field(context, "company"),
        read_field(context, "relationship")
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.uniq()

    label =
      cond do
        blank?(person) ->
          nil

        identity == [] ->
          person

        true ->
          "#{person} (#{Enum.join(identity, "; ")})"
      end

    focus = todo_focus(todo, context)

    cond do
      present?(label) and present?(focus) -> "#{label} about #{focus}"
      present?(label) -> label
      present?(focus) -> focus
      true -> read_field(todo, "title")
    end
  end

  defp todo_focus(todo, context) do
    todo
    |> todo_metadata()
    |> then(fn metadata ->
      [
        read_field(context, "why"),
        read_metadata(metadata, "why_it_matters"),
        read_metadata(metadata, "context_brief"),
        read_metadata(metadata, "context"),
        metadata |> read_metadata("record") |> read_metadata("ask"),
        metadata |> read_metadata("record") |> read_metadata("commitment"),
        metadata |> read_metadata("record") |> read_metadata("summary"),
        read_field(todo, "next_action"),
        read_field(todo, "summary"),
        read_field(todo, "title")
      ]
    end)
    |> Enum.find(&present?/1)
    |> one_line()
    |> truncate(160)
  end

  defp personal_calendar_message(event) do
    summary = event_summary(event)

    [
      "You have #{summary}#{event_source_text(event)}#{event_when_text(event)}.",
      "Anything I should help prep, confirm, or catch before then?"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp stale_confirmation_todos(payload, plan) do
    plan_ids =
      plan
      |> read_field("todo_ids")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    payload
    |> context_todos()
    |> Enum.filter(fn todo ->
      id = todo_id(todo)

      (MapSet.size(plan_ids) == 0 or MapSet.member?(plan_ids, id)) and
        read_field(AttentionRanker.profile(todo), "stale_confirmation_candidate") == true
    end)
    |> AttentionRanker.sort()
  end

  defp plan_todos(payload, plan) do
    plan_ids =
      plan
      |> read_field("todo_ids")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    payload
    |> context_todos()
    |> Enum.filter(fn todo ->
      MapSet.size(plan_ids) > 0 and MapSet.member?(plan_ids, todo_id(todo))
    end)
    |> AttentionRanker.sort()
  end

  defp too_many_stale_confirmations?(payload, plan) do
    read_field(plan, "message_class") == "todo_digest" and
      length(stale_confirmation_todos(payload, plan)) > 1
  end

  defp wrong_todo_order?(payload, plan) do
    plan_ids =
      plan
      |> read_field("todo_ids")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    ranked_ids = ranked_plan_todo_ids(payload, plan)

    length(plan_ids) > 1 and length(ranked_ids) == length(plan_ids) and ranked_ids != plan_ids
  end

  defp ranked_plan_todo_ids(payload, plan) do
    plan_ids =
      plan
      |> read_field("todo_ids")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    payload
    |> context_todos()
    |> Enum.filter(&MapSet.member?(plan_ids, todo_id(&1)))
    |> AttentionRanker.sort()
    |> Enum.map(&todo_id/1)
  end

  defp stale_urgency_overclaim?(message, payload, plan) do
    stale_confirmation_todos(payload, plan) != [] and contains_any?(message, @urgent_terms) and
      not Regex.match?(~r/(not treating it as urgent|not urgent|rather than urgent)/i, message)
  end

  defp ignored_personal_calendar?(message, payload, plan) do
    personal_events = personal_calendar_events(payload)

    personal_events != [] and not mentions_any_calendar_event?(message, personal_events) and
      work_followup_message?(message, payload, plan)
  end

  defp personal_calendar_events(payload) do
    context = read_field(payload, "context") || %{}
    calendar = read_field(context, "calendar") || %{}

    direct =
      calendar
      |> read_field("personal_events")
      |> List.wrap()

    fallback =
      calendar
      |> read_field("upcoming_events")
      |> List.wrap()
      |> Enum.filter(&personal_calendar_event?/1)

    (direct ++ fallback)
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&event_key/1)
    |> Enum.sort_by(&event_sort_value/1)
  end

  defp personal_calendar_event?(event) when is_map(event) do
    profile = read_field(event, "attention_profile") || %{}
    read_field(profile, "personal_family") == true
  end

  defp personal_calendar_event?(_event), do: false

  defp mentions_any_calendar_event?(message, events) when is_binary(message) do
    normalized = normalize_for_match(message)

    Enum.any?(events, fn event ->
      summary = event |> event_summary() |> normalize_for_match()
      summary != "" and String.contains?(normalized, summary)
    end)
  end

  defp mentions_any_calendar_event?(_message, _events), do: false

  defp work_followup_message?(message, payload, plan) do
    stale_confirmation_todos(payload, plan) != [] or contains_any?(message, @work_terms)
  end

  defp stale_unprotected?(profile) when is_map(profile) do
    read_field(profile, "stale_confirmation_candidate") == true and
      read_field(profile, "bucket") not in ["personal_family", "strong_relationship_waiting"]
  end

  defp stale_unprotected?(_profile), do: false

  defp confirmation_style?(text) when is_binary(text) do
    downcased = String.downcase(text)

    String.contains?(downcased, "still important") or
      String.contains?(downcased, "still matters") or
      String.contains?(downcased, "mark it important") or
      String.contains?(downcased, "dismiss")
  end

  defp confirmation_style?(_text), do: false

  defp backlog_dump?(text) when is_binary(text) do
    normalized = String.downcase(text)

    pattern_hit? =
      Regex.match?(~r/several overdue follow[- ]?ups/i, text) or
        Regex.match?(~r/overdue follow[- ]?ups.*need your attention/is, text) or
        Regex.match?(~r/prioritize sending (these )?follow[- ]?ups now/i, text) or
        Regex.match?(~r/maintain (your )?(relationships|professional momentum|reputation)/i, text) or
        Regex.match?(~r/several recent meetings need a follow[- ]?up recap/i, text)

    item_count = bullet_count(text) + colon_name_count(text)

    pattern_hit? and item_count >= 3 and
      (String.contains?(normalized, "overdue") or String.contains?(normalized, "follow"))
  end

  defp backlog_dump?(_text), do: false

  defp missing_person_context?(text, payload, plan) when is_binary(text) do
    thin_named_lines? =
      text
      |> person_lines()
      |> Enum.any?(fn {name, line} ->
        not familiar_person?(payload, name) and not adequate_identity_context?(line)
      end)

    thin_todo_context? =
      payload
      |> plan_todos(plan)
      |> Enum.any?(fn todo ->
        person = todo_person(todo)

        present?(person) and not familiar_todo_person?(todo, payload, person) and
          not message_has_todo_context?(text, todo)
      end)

    thin_named_lines? or thin_todo_context?
  end

  defp missing_person_context?(_text, _payload, _plan), do: false

  defp missing_candidate_context?(candidate, payload) when is_map(candidate) do
    body = read_field(candidate, "body") || ""

    body_missing? =
      body
      |> person_lines()
      |> Enum.any?(fn {name, line} ->
        not familiar_candidate_person?(candidate, payload, name) and
          not adequate_identity_context?(line)
      end)

    related_missing? =
      candidate
      |> read_field("related_todos")
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.any?(fn todo ->
        person = todo_person(todo)

        present?(person) and not familiar_candidate_person?(candidate, payload, person) and
          not message_has_todo_context?(body, todo)
      end)

    body_missing? or related_missing?
  end

  defp missing_candidate_context?(_candidate, _payload), do: false

  defp person_lines(text) when is_binary(text) do
    ~r/(?:^|\n)\s*(?:[-*•]|\d+[.)])?\s*([A-Z][A-Za-z'@.-]+(?:\s+[A-Z][A-Za-z'.-]+){0,3})\s*:\s*([^\n]+)/u
    |> Regex.scan(text)
    |> Enum.map(fn [full, name, _rest] -> {String.trim(name), String.trim(full)} end)
    |> Enum.reject(fn {name, _line} ->
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_ -]/, "")
      |> String.trim()
      |> then(&(&1 in @person_line_stop_labels or &1 in @context_stop_words))
    end)
  end

  defp person_lines(_text), do: []

  defp adequate_identity_context?(line) when is_binary(line) do
    normalized = String.downcase(line)

    Regex.match?(~r/\([^)]+\)/, line) or
      Regex.match?(~r/\b(at|from)\s+[A-Z0-9][A-Za-z0-9&'.-]+/, line) or
      contains_any?(normalized, @identity_context_terms)
  end

  defp adequate_identity_context?(_line), do: false

  defp message_has_todo_context?(message, todo) when is_binary(message) and is_map(todo) do
    person = todo_person(todo)
    signals = todo_context_signals(todo)

    cond do
      blank?(person) ->
        true

      not text_mentions?(message, person) ->
        false

      signals == [] ->
        false

      adequate_identity_context?(person_window(message, person)) ->
        true

      true ->
        Enum.any?(signals, &signal_mentioned?(message, &1))
    end
  end

  defp message_has_todo_context?(_message, _todo), do: false

  defp todo_context_signals(todo) when is_map(todo) do
    metadata = todo_metadata(todo)
    profile = AttentionRanker.profile(todo)
    context = read_field(profile, "context") || %{}

    [
      read_field(context, "company"),
      read_field(context, "relationship"),
      read_field(context, "why"),
      read_metadata(metadata, "company"),
      read_metadata(metadata, "organization"),
      read_metadata(metadata, "relationship"),
      read_metadata(metadata, "relationship_context"),
      read_metadata(metadata, "why_it_matters"),
      read_metadata(metadata, "context"),
      read_metadata(metadata, "context_brief"),
      metadata |> read_metadata("record") |> read_metadata("company"),
      metadata |> read_metadata("record") |> read_metadata("organization"),
      metadata |> read_metadata("record") |> read_metadata("relationship"),
      metadata |> read_metadata("record") |> read_metadata("relationship_context"),
      metadata |> read_metadata("record") |> read_metadata("summary"),
      metadata |> read_metadata("record") |> read_metadata("ask"),
      metadata |> read_metadata("record") |> read_metadata("commitment")
    ]
    |> Enum.filter(&present?/1)
    |> Enum.map(&one_line/1)
    |> Enum.reject(&(context_signal_tokens(&1) == []))
    |> Enum.uniq()
  end

  defp todo_context_signals(_todo), do: []

  defp person_window(message, person) do
    normalized_message = normalize_for_match(message)
    normalized_person = normalize_for_match(person)

    case :binary.match(normalized_message, normalized_person) do
      {index, length} ->
        start = max(index - 80, 0)
        finish = min(index + length + 160, byte_size(normalized_message))
        binary_part(normalized_message, start, finish - start)

      :nomatch ->
        message
    end
  end

  defp text_mentions?(text, value) when is_binary(text) and is_binary(value) do
    normalized_value = normalize_for_match(value)

    normalized_value != "" and
      String.contains?(normalize_for_match(text), normalized_value)
  end

  defp text_mentions?(_text, _value), do: false

  defp signal_mentioned?(message, signal) when is_binary(message) and is_binary(signal) do
    normalized_message = normalize_for_match(message)
    normalized_signal = normalize_for_match(signal)

    cond do
      normalized_signal == "" ->
        false

      String.contains?(normalized_message, normalized_signal) ->
        true

      true ->
        signal
        |> context_signal_phrases()
        |> Enum.any?(&String.contains?(normalized_message, &1))
    end
  end

  defp signal_mentioned?(_message, _signal), do: false

  defp context_signal_phrases(signal) do
    tokens = context_signal_tokens(signal)

    tokens
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&Enum.join(&1, " "))
    |> Enum.reject(&(String.length(&1) < 7))
  end

  defp context_signal_tokens(value) when is_binary(value) do
    value
    |> normalize_for_match()
    |> String.split(" ", trim: true)
    |> Enum.reject(&(&1 in @context_stop_words))
    |> Enum.reject(&(String.length(&1) < 3))
  end

  defp context_signal_tokens(_value), do: []

  defp normalize_for_match(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp normalize_for_match(_value), do: ""

  defp event_summary(event) when is_map(event) do
    read_field(event, "summary") || read_field(event, "title") || "calendar event"
  end

  defp event_summary(_event), do: "calendar event"

  defp event_when_text(event) when is_map(event) do
    [
      read_field(event, "display_start"),
      event_time_label(read_field(event, "start"))
    ]
    |> Enum.find(&present?/1)
    |> case do
      nil -> ""
      value -> " at #{value}"
    end
  end

  defp event_when_text(_event), do: ""

  defp event_source_text(event) when is_map(event) do
    [
      read_field(event, "account"),
      read_field(event, "google_account_email"),
      read_field(event, "calendar_name")
    ]
    |> Enum.find(&present?/1)
    |> case do
      nil -> ""
      value -> " on #{value}"
    end
  end

  defp event_source_text(_event), do: ""

  defp event_key(event) when is_map(event) do
    [
      event_summary(event),
      event_time_label(read_field(event, "start")),
      read_field(event, "account") || read_field(event, "calendar_name")
    ]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.join("|")
    |> String.downcase()
  end

  defp event_key(event), do: inspect(event)

  defp event_sort_value(event) when is_map(event) do
    event
    |> read_field("start")
    |> event_time_sort_value()
  end

  defp event_sort_value(_event), do: 9_999_999_999

  defp event_time_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp event_time_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> 9_999_999_999
    end
  end

  defp event_time_sort_value(%{"date" => date}) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> Date.to_gregorian_days(parsed) * 86_400
      _ -> 9_999_999_999
    end
  end

  defp event_time_sort_value(%{date: date}) when is_binary(date),
    do: event_time_sort_value(%{"date" => date})

  defp event_time_sort_value(_value), do: 9_999_999_999

  defp event_time_label(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp event_time_label(value) when is_binary(value), do: value
  defp event_time_label(%{"date" => date}) when is_binary(date), do: date
  defp event_time_label(%{date: date}) when is_binary(date), do: date
  defp event_time_label(_value), do: nil

  defp familiar_candidate_person?(candidate, payload, name) do
    profile = read_field(candidate, "attention_profile") || %{}

    familiar_profile?(profile) or familiar_person?(payload, name)
  end

  defp familiar_todo_person?(todo, payload, name) do
    metadata = todo_metadata(todo)

    familiar_profile?(AttentionRanker.profile(todo)) or
      familiar_person?(payload, name) or
      read_integer(metadata, "interaction_count", 0) >= @familiar_interaction_count or
      frequent_communication?(read_metadata(metadata, "communication_frequency")) or
      frequent_communication?(
        metadata
        |> read_metadata("record")
        |> read_metadata("communication_frequency")
      )
  end

  defp familiar_person?(payload, name) when is_binary(name) do
    payload
    |> read_field("context")
    |> read_field("relationships")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.any?(fn relationship ->
      same_person?(name, relationship) and familiar_relationship?(relationship)
    end)
  end

  defp familiar_person?(_payload, _name), do: false

  defp familiar_profile?(profile) when is_map(profile) do
    read_integer(profile, "relationship_strength", 0) >= @familiar_relationship_strength or
      read_integer(profile, "interaction_count", 0) >= @familiar_interaction_count or
      frequent_communication?(read_field(profile, "communication_frequency"))
  end

  defp familiar_profile?(_profile), do: false

  defp familiar_relationship?(relationship) do
    read_integer(relationship, "interaction_count", 0) >= @familiar_interaction_count or
      read_integer(relationship, "relationship_strength", 0) >= @familiar_relationship_strength or
      frequent_communication?(read_field(relationship, "communication_frequency"))
  end

  defp frequent_communication?(value) when is_binary(value) do
    normalized = String.downcase(value)
    Enum.any?(@frequent_communication, &String.contains?(normalized, &1))
  end

  defp frequent_communication?(_value), do: false

  defp same_person?(name, relationship) when is_map(relationship) do
    target = normalize_person_name(name)

    [
      read_field(relationship, "display_name"),
      [read_field(relationship, "first_name"), read_field(relationship, "last_name")]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    ]
    |> Enum.map(&normalize_person_name/1)
    |> Enum.any?(&(&1 == target and &1 != ""))
  end

  defp same_person?(_name, _relationship), do: false

  defp normalize_person_name(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.trim()
  end

  defp normalize_person_name(_value), do: ""

  defp personal_as_business?(text) when is_binary(text) do
    personal? =
      Regex.match?(~r/\b(soccer practice|school|family|child|kid|daughter|son)\b/i, text)

    business_framing? =
      Regex.match?(
        ~r/\b(follow[- ]?up recap|owners? and next steps|keep everyone aligned|business objective|project momentum)\b/i,
        text
      )

    personal? and business_framing?
  end

  defp personal_as_business?(_text), do: false

  defp bullet_count(text) do
    ~r/(?:^|\n)\s*(?:[-*•]|\d+[.)])\s+/u
    |> Regex.scan(text)
    |> length()
  end

  defp colon_name_count(text) do
    ~r/(?:^|\n)\s*(?:[-*•]|\d+[.)])?\s*[A-Z][A-Za-z'@.-]+(?:\s+[A-Z][A-Za-z'.-]+){0,3}\s*:/
    |> Regex.scan(text)
    |> length()
  end

  defp weekend?(payload) do
    payload
    |> read_field("trigger")
    |> read_field("local_time")
    |> read_field("weekend")
    |> Kernel.==(true)
  end

  defp context_todos(payload) do
    context = read_field(payload, "context") || %{}
    direct_todos = read_field(context, "todos") || []
    open_loops = read_field(context, "open_loops") || %{}
    buckets = read_field(open_loops, "buckets") || %{}

    bucket_todos =
      if is_map(buckets) do
        buckets
        |> Map.values()
        |> Enum.flat_map(fn
          todos when is_list(todos) -> todos
          _other -> []
        end)
      else
        []
      end

    (direct_todos ++ bucket_todos)
    |> Enum.filter(&is_map/1)
    |> Enum.uniq_by(&todo_id/1)
  end

  defp candidates_by_id(payload) do
    payload
    |> read_field("candidates")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Map.new(&{read_field(&1, "id"), &1})
  end

  defp put_verification(plan, status, findings, iteration, score, prior_findings \\ []) do
    Map.put(plan, "_quality_verification", %{
      "status" => status,
      "score" => score,
      "iterations" => iteration,
      "findings" => Enum.map(findings, &to_string/1),
      "prior_findings" => Enum.map(Enum.uniq(prior_findings), &to_string/1),
      "rubric" => @rubric
    })
  end

  defp score([]), do: 10

  defp score(findings) do
    penalty =
      findings
      |> Enum.uniq()
      |> Enum.map(&finding_penalty/1)
      |> Enum.sum()

    max(0, 10 - penalty)
  end

  defp finding_penalty(:missing_person_context), do: 3
  defp finding_penalty(:personal_as_business), do: 3
  defp finding_penalty(:backlog_dump), do: 3
  defp finding_penalty(:ignored_personal_calendar), do: 3
  defp finding_penalty(:too_many_stale_confirmations), do: 2
  defp finding_penalty(:wrong_order), do: 2
  defp finding_penalty(:weekend_work_dump), do: 2
  defp finding_penalty(:stale_urgency_overclaim), do: 2
  defp finding_penalty(_finding), do: 2

  defp finding_text(findings) do
    findings
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end

  defp maybe_add(findings, finding, true), do: [finding | findings]
  defp maybe_add(findings, _finding, _condition), do: findings

  defp contains_any?(text, terms) when is_binary(text) do
    downcased = String.downcase(text)
    Enum.any?(terms, &String.contains?(downcased, &1))
  end

  defp contains_any?(_text, _terms), do: false

  defp todo_person(todo) when is_map(todo) do
    profile = AttentionRanker.profile(todo)
    context = read_field(profile, "context") || %{}

    read_field(context, "person") ||
      read_metadata(todo_metadata(todo), "person") ||
      todo_metadata(todo) |> read_metadata("record") |> read_metadata("person")
  end

  defp todo_person(_todo), do: nil

  defp todo_metadata(todo) when is_map(todo) do
    case read_field(todo, "metadata") do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  defp read_metadata(nil, _key), do: nil
  defp read_metadata(value, _key) when not is_map(value), do: nil
  defp read_metadata(map, key), do: read_field(map, key)

  defp read_float(map, key, default) do
    case read_field(map, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      _value -> default
    end
  end

  defp read_integer(map, key, default) do
    case read_field(map, key) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        round(value)

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _other -> default
        end

      _other ->
        default
    end
  end

  defp todo_id(todo), do: read_field(todo, "id")

  defp read_field(nil, _key), do: nil
  defp read_field(%_{} = struct, key), do: read_field(Map.from_struct(struct), key)

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {map_key, value} when is_atom(map_key) ->
          if Atom.to_string(map_key) == key, do: value

        _other ->
          nil
      end)
  end

  defp read_field(_map, _key), do: nil

  defp blank?(value), do: value in [nil, ""]

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp one_line(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp one_line(value), do: value

  defp truncate(value, max_length) when is_binary(value) do
    if String.length(value) > max_length do
      value
      |> String.slice(0, max_length)
      |> String.trim()
      |> Kernel.<>("...")
    else
      value
    end
  end

  defp truncate(value, _max_length), do: value
end
