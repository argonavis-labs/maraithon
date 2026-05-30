defmodule Maraithon.ActionCards do
  @moduledoc """
  Product-level decision cards for the chief-of-staff surfaces.

  Cards are projections over existing durable objects. The first supported
  projection is a todo, because todos already represent the open-loop source of
  truth used by Telegram, briefings, dashboard, and mobile surfaces.
  """

  alias Maraithon.SourceFreshness
  alias Maraithon.SourceLabels
  alias Maraithon.Todos
  alias Maraithon.Todos.{AttentionRanker, PublicMetadata, SurfaceQuality, Todo, UserFacingCopy}

  @open_statuses ~w(open snoozed)
  @assistant_sources ~w(
    chief_of_staff_morning_briefing
    chief_of_staff_commitment_tracker
    chief_of_staff_holiday
    chief_of_staff_weekend
  )

  @source_evidence_keys ~w(
    source_quote quote source_excerpt body_excerpt excerpt evidence source_body source_evidence
    checked_evidence body ask commitment summary
  )

  @unsafe_source_gap_markers ~w(
    <redacted
    authorization
    bearer
    dbconnection
    ecto.
    http_status
    internal
    password
    phoenix.
    postgrex
    private_key
    stacktrace
    token
  )

  @doc """
  Returns ranked action cards for open todos.
  """
  def list_for_user(user_id, opts \\ [])

  def list_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 20)
    opts = put_source_health_snapshots(user_id, opts)

    user_id
    |> Todos.list_for_user(limit: limit, statuses: @open_statuses)
    |> AttentionRanker.sort()
    |> Enum.map(&for_todo(&1, opts))
  end

  def list_for_user(_user_id, _opts), do: []

  @doc """
  Builds a decision card projection for a todo.
  """
  def for_todo(todo, opts \\ [])

  def for_todo(%Todo{} = todo, opts) when is_list(opts) do
    todo = polish_todo_copy(todo)
    metadata = todo.metadata || %{}
    profile = AttentionRanker.profile(todo)
    quality = SurfaceQuality.assess(todo)
    context_pack = context_pack(todo, metadata, profile)
    attention_mode = card_attention_mode(todo, profile)
    source_health = source_health_snapshot(todo.user_id, todo.source, opts)

    card =
      %{
        "id" => "todo:#{todo.id}",
        "kind" => todo_kind(todo, profile),
        "source_object_type" => "todo",
        "source_object_id" => todo.id,
        "headline" => headline(todo, context_pack, attention_mode),
        "decision_prompt" => decision_prompt(todo, context_pack, attention_mode),
        "rank_reason" => rank_reason(profile),
        "why_now" => why_now(todo, metadata, profile, attention_mode),
        "context_pack" => context_pack,
        "next_best_action" => next_best_action(todo, attention_mode),
        "prepared_actions" => prepared_actions(todo),
        "available_buttons" => available_buttons(todo, attention_mode),
        "estimated_effort" => estimated_effort(todo),
        "attention_mode" => attention_mode,
        "confidence" => confidence(metadata, quality, source_health),
        "source_health" => source_health,
        "created_from" => created_from(metadata),
        "quality" => quality
      }

    Map.put(card, "product_score", product_score(card))
  end

  def for_todo(todo, opts) when is_map(todo) and is_list(opts) do
    todo
    |> map_to_todo()
    |> for_todo(opts)
  end

  @doc """
  Scores a card against the product bar from the spec.

  The score is intentionally strict. A card should not score 10/10 unless it
  gives the user enough context to decide, explains source confidence, and
  offers a concrete next move.
  """
  def product_score(card) when is_map(card) do
    checks = product_checks(card)
    passed = Enum.count(checks, fn {_name, passed?} -> passed? end)

    %{
      "score" => passed,
      "max_score" => length(checks),
      "passed" => passed == length(checks),
      "missing" =>
        checks
        |> Enum.reject(fn {_name, passed?} -> passed? end)
        |> Enum.map(fn {name, _passed?} -> name end)
    }
  end

  def product_score(_card) do
    %{"score" => 0, "max_score" => 10, "passed" => false, "missing" => ["card"]}
  end

  @doc """
  Renders a todo card for Telegram.
  """
  def render_telegram_todo(todo, opts \\ []) do
    card = for_todo(todo, opts)
    prefix_text = Keyword.get(opts, :prefix_text)

    [
      html_line(prefix_text),
      "<b>#{safe(card["headline"])}</b>",
      telegram_context_line(card),
      telegram_decision_line(card),
      telegram_why_line(card),
      telegram_thread_line(card),
      telegram_next_line(card),
      telegram_prepared_line(card),
      telegram_evidence_line(card),
      source_health_note(card),
      telegram_learning_line(card)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  @doc """
  Renders source freshness as executive-facing copy.

  Source freshness metadata can contain connector identifiers or transport
  errors. Product surfaces only need the user-level confidence boundary.
  """
  def source_health_note(card) when is_map(card) do
    source_health = read_map(card, "source_health")
    blocking = read_field(source_health, "blocking_gaps") |> List.wrap() |> Enum.reject(&blank?/1)

    checked =
      read_field(source_health, "checked_sources") |> List.wrap() |> Enum.reject(&blank?/1)

    cond do
      blocking != [] ->
        blocked_sources = source_gap_sources(blocking)

        checked_without_blockers =
          Enum.reject(checked, &(normalize_source(&1) in blocked_sources))

        [
          if(checked_without_blockers != [],
            do: "Checked #{source_list(checked_without_blockers)}."
          ),
          source_gap_note(blocking, blocked_sources),
          source_setup_action(blocked_sources)
        ]
        |> Enum.reject(&blank?/1)
        |> Enum.join(" ")

      checked != [] ->
        "Checked #{source_list(checked)}."

      true ->
        nil
    end
  end

  def source_health_note(_card), do: nil

  def context_items(card_or_todo) do
    card = ensure_card(card_or_todo)
    context = read_map(card, "context_pack")

    [
      %{label: "Person", value: people_label(read_field(context, "people"))},
      %{label: "Project", value: read_field(context, "project_or_topic")},
      %{label: "Relationship", value: read_field(context, "relationship_context")},
      %{label: "Thread state", value: humanize(read_field(context, "thread_state"))},
      %{label: "Owed", value: humanize(read_field(context, "owed_direction"))}
    ]
    |> Enum.reject(fn item -> blank?(item.value) end)
  end

  def evidence_excerpt(card_or_todo) do
    card = ensure_card(card_or_todo)

    card
    |> get_in(["context_pack", "source_evidence"])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"excerpt" => excerpt} when is_binary(excerpt) -> excerpt
      _other -> nil
    end)
  end

  def prepared_action_hint(card_or_todo) do
    card = ensure_card(card_or_todo)

    case read_field(card, "prepared_actions") do
      [%{"label" => label} | _] when is_binary(label) -> label
      _other -> nil
    end
  end

  defp product_checks(card) do
    context = read_map(card, "context_pack")
    source_health = read_map(card, "source_health")

    [
      {"personalized_copy", personalized_copy?(card)},
      {"decision_prompt", present?(read_field(card, "decision_prompt"))},
      {"why_now", present?(read_field(card, "why_now"))},
      {"person_or_explicit_unknown",
       people_present?(read_field(context, "people")) or
         present?(read_field(context, "missing_context"))},
      {"project_or_topic",
       present?(read_field(context, "project_or_topic")) or
         present?(read_field(context, "summary"))},
      {"thread_or_owed_state",
       present?(read_field(context, "thread_state")) or
         present?(read_field(context, "owed_direction"))},
      {"source_evidence", source_evidence_present?(context)},
      {"source_health", source_health_present?(source_health)},
      {"next_best_action", present?(read_field(card, "next_best_action"))},
      {"safe_actions", read_field(card, "available_buttons") |> List.wrap() |> Enum.any?()}
    ]
  end

  defp ensure_card(%Todo{} = todo), do: for_todo(todo)
  defp ensure_card(%{"context_pack" => _context} = card), do: card
  defp ensure_card(%{context_pack: _context} = card), do: stringify_keys(card)
  defp ensure_card(map) when is_map(map), do: for_todo(map)

  defp polish_todo_copy(%Todo{} = todo) do
    attrs =
      %{
        "title" => todo.title,
        "summary" => todo.summary,
        "next_action" => todo.next_action,
        "metadata" => todo.metadata || %{}
      }
      |> UserFacingCopy.polish_attrs()

    %Todo{
      todo
      | title: read_string(attrs, "title") || todo.title,
        summary: read_string(attrs, "summary") || todo.summary,
        next_action: read_string(attrs, "next_action") || todo.next_action
    }
  end

  defp context_pack(%Todo{} = todo, metadata, profile) do
    record = read_map(metadata, "record")
    person_context = first_person_context(metadata)

    person =
      first_present([
        read_string(record, "person"),
        read_string(metadata, "person"),
        read_string(person_context, "display_name"),
        read_string(person_context, "name"),
        read_string(metadata, "contact"),
        read_string(metadata, "requested_by"),
        read_string(metadata, "sender_name")
      ])

    company =
      first_present([
        read_string(record, "company"),
        read_string(metadata, "company"),
        read_string(person_context, "company"),
        read_string(record, "organization"),
        read_string(metadata, "organization"),
        read_string(person_context, "organization"),
        read_string(metadata, "account_name")
      ])

    relationship =
      first_present([
        read_string(record, "relationship_context"),
        read_string(metadata, "relationship_context"),
        read_string(person_context, "relationship_context"),
        read_string(record, "relationship"),
        read_string(metadata, "relationship"),
        read_string(person_context, "relationship"),
        read_string(metadata, "context_brief")
      ])

    project =
      first_present([
        read_string(metadata, "project"),
        read_string(metadata, "project_name"),
        read_string(metadata, "omni_project"),
        read_string(metadata, "topic"),
        read_string(metadata, "subject"),
        read_string(metadata, "thread_subject"),
        read_string(record, "project"),
        company
      ]) || source_label(todo.source)

    %{
      "summary" => context_summary(todo, metadata, record, person, company, relationship),
      "people" => people_context(person, company, relationship, profile),
      "project_or_topic" => project,
      "relationship_context" => relationship,
      "thread_state" => thread_state(metadata, profile),
      "owed_direction" => owed_direction(metadata, profile),
      "source_evidence" => source_evidence(todo, metadata, record),
      "related_open_loops" => [],
      "last_interaction" => last_interaction(todo, metadata),
      "confidence_reason" => confidence_reason(metadata),
      "missing_context" => missing_context(todo, metadata, person)
    }
  end

  defp headline(_todo, context, "stale_check") do
    person = primary_person_name(context)

    cond do
      present?(person) -> "Should this older follow-up with #{person} stay active?"
      true -> "Should this older work item stay active?"
    end
  end

  defp headline(todo, context, _attention_mode) do
    person = primary_person_name(context)
    title = clean_title(todo.title || todo.next_action || "Review this item")

    cond do
      present?(person) and title_mentions_person?(title, person) ->
        title

      present?(person) ->
        "#{person}: #{title}"

      true ->
        title
    end
  end

  defp decision_prompt(_todo, _context, "stale_check") do
    "Keep it active if it still matters, or dismiss it so it stops resurfacing."
  end

  defp decision_prompt(_todo, context, _attention_mode) do
    person = primary_person_name(context)

    if present?(person) do
      "Choose the next move with #{person}."
    else
      "Handle this now, snooze it, or dismiss it."
    end
  end

  defp why_now(_todo, _metadata, profile, "stale_check") do
    age_days = read_field(profile, "age_days")

    if is_integer(age_days) do
      "This item is #{age_days} days old with no handled evidence. It is not urgent, but it needs a keep-or-close decision."
    else
      "This has been open long enough to need a keep-or-close decision."
    end
  end

  defp why_now(todo, metadata, profile, _attention_mode) do
    public_metadata = PublicMetadata.todo(metadata)

    first_present([
      read_string(public_metadata, "why_now"),
      read_string(public_metadata, "why_it_matters"),
      due_sentence(todo),
      profile_why_now(profile),
      "This is still open and needs a clear next decision."
    ])
  end

  defp next_best_action(_todo, "stale_check") do
    "Keep it active only if it still matters; otherwise dismiss it so future briefings stay focused."
  end

  defp next_best_action(todo, _attention_mode) do
    first_present([
      todo.next_action,
      read_string(todo.metadata || %{}, "next_action"),
      "Open the source item, confirm the real ask, and decide whether this still matters."
    ])
    |> naturalize_action_copy()
  end

  defp card_attention_mode(todo, profile) do
    cond do
      read_field(profile, "stale_confirmation_candidate") == true -> "stale_check"
      todo.attention_mode == "monitor" -> "monitor"
      true -> "review"
    end
  end

  defp todo_kind(todo, profile) do
    cond do
      read_field(profile, "personal_family") == true -> "personal_logistics"
      read_field(profile, "meeting_request") == true -> "meeting_prep"
      todo.source in ["gmail", "slack"] -> "reply_debt"
      true -> "todo"
    end
  end

  defp rank_reason(profile) do
    case read_field(profile, "bucket") do
      "personal_family" -> "Personal or family logistics are ranked first."
      "strong_relationship_waiting" -> "A close relationship appears to be waiting on you."
      "business_project_waiting" -> "An active business objective may be waiting on you."
      "intro_request" -> "This looks like relationship-capital work."
      "meeting_request" -> "This appears to be meeting or scheduling work."
      _ -> "This remains open and reviewable."
    end
  end

  defp prepared_actions(todo) do
    next_action = String.downcase(todo.next_action || "")
    source = todo.source

    cond do
      action_draft_present?(todo.action_draft) ->
        [%{"type" => "review_draft", "label" => "Draft material is ready for approval."}]

      source == "gmail" and String.contains?(next_action, ["reply", "email"]) ->
        [%{"type" => "draft_email", "label" => "Maraithon can draft the reply for approval."}]

      source == "slack" and String.contains?(next_action, ["reply", "respond", "message"]) ->
        [
          %{
            "type" => "draft_slack",
            "label" => "Maraithon can draft the Slack response for approval."
          }
        ]

      true ->
        []
    end
  end

  defp available_buttons(%Todo{status: status}, _attention_mode)
       when status not in @open_statuses,
       do: ["open_dashboard"]

  defp available_buttons(_todo, "stale_check"),
    do: ["keep_active", "important", "dismiss", "see_less", "more_context"]

  defp available_buttons(_todo, _attention_mode),
    do: ["done", "dismiss", "snooze", "important", "not_helpful", "see_less", "more_context"]

  defp estimated_effort(todo) do
    action = String.downcase(todo.next_action || "")

    cond do
      String.contains?(action, ["draft", "reply", "respond", "confirm"]) -> "under_2_min"
      String.contains?(action, ["research", "prep", "prepare"]) -> "deep_work"
      true -> "5_min"
    end
  end

  defp confidence(metadata, quality, source_health) do
    explicit = read_string(metadata, "confidence") || read_string(metadata, "scope_confidence")
    source_issue? = read_field(source_health, "blocking_gaps") |> List.wrap() |> Enum.any?()

    level =
      cond do
        present?(explicit) -> explicit_confidence_level(explicit)
        source_issue? -> "medium"
        quality["score"] >= 85 -> "high"
        quality["score"] >= 65 -> "medium"
        true -> "low"
      end

    %{
      "level" => level,
      "reason" =>
        confidence_reason(metadata) ||
          "Based on saved-work context, evidence, and source freshness."
    }
  end

  defp source_health_snapshot(nil, _source, _opts), do: empty_source_health()

  defp source_health_snapshot(user_id, source, opts) do
    include_disconnected? = Keyword.get(opts, :include_disconnected, true)

    snapshots =
      Keyword.get_lazy(opts, :source_health_snapshots, fn ->
        SourceFreshness.compact_for_prompt(user_id)
      end)

    checked_sources = checked_sources(source, snapshots)
    relevant = filter_source_snapshots(snapshots, source)
    fresh = Enum.filter(relevant, &(read_field(&1, "status") == "fresh"))

    stale =
      Enum.filter(
        relevant,
        &(read_field(&1, "status") in ~w(stale error reauth_required never_synced))
      )

    missing = missing_relevant_sources(source, snapshots, include_disconnected?)

    %{
      "checked_sources" => checked_sources,
      "fresh_sources" => Enum.map(fresh, &read_field(&1, "provider")),
      "stale_sources" => Enum.map(stale, &read_field(&1, "provider")),
      "missing_sources" => missing,
      "last_success_at_by_source" =>
        Map.new(relevant, fn snapshot ->
          {read_field(snapshot, "provider"), read_field(snapshot, "last_successful_sync")}
        end),
      "blocking_gaps" => blocking_gaps(stale, missing),
      "setup_suggestion" => setup_suggestion(missing)
    }
  end

  defp empty_source_health do
    %{
      "checked_sources" => [],
      "fresh_sources" => [],
      "stale_sources" => [],
      "missing_sources" => [],
      "last_success_at_by_source" => %{},
      "blocking_gaps" => [],
      "setup_suggestion" => nil
    }
  end

  defp put_source_health_snapshots(user_id, opts) do
    if Keyword.has_key?(opts, :source_health_snapshots) do
      opts
    else
      Keyword.put(opts, :source_health_snapshots, SourceFreshness.compact_for_prompt(user_id))
    end
  end

  defp source_evidence(todo, metadata, record) do
    values =
      []
      |> Kernel.++(source_evidence_values(metadata))
      |> Kernel.++(source_evidence_values(record))
      |> Kernel.++([todo.summary, todo.notes])
      |> Enum.reject(&blank?/1)
      |> Enum.map(&externalize_copy/1)
      |> Enum.filter(&public_card_text?/1)
      |> Enum.uniq()
      |> Enum.take(3)

    source = todo.source || "todo"

    Enum.map(values, fn value ->
      %{
        "source" => source,
        "source_account_label" => todo.source_account_label,
        "source_ref" => todo.source_item_id || todo.dedupe_key,
        "occurred_at" => datetime_iso(todo.source_occurred_at || todo.inserted_at),
        "excerpt" => truncate(value, 240),
        "evidence_type" => evidence_type(value)
      }
    end)
  end

  defp source_evidence_values(map) when is_map(map) do
    Enum.flat_map(@source_evidence_keys, fn key ->
      value = read_field(map, key)

      cond do
        is_binary(value) -> [value]
        is_list(value) -> Enum.flat_map(value, &source_evidence_item/1)
        is_map(value) -> source_evidence_values(value)
        true -> []
      end
    end)
  end

  defp source_evidence_values(_map), do: []

  defp source_evidence_item(value) when is_binary(value), do: [value]

  defp source_evidence_item(value) when is_map(value) do
    [
      read_string(value, "detail"),
      read_string(value, "excerpt"),
      read_string(value, "quote"),
      read_string(value, "text")
    ]
    |> Enum.reject(&blank?/1)
  end

  defp source_evidence_item(_value), do: []

  defp first_person_context(metadata) when is_map(metadata) do
    case read_field(metadata, "people") || read_field(metadata, "crm_people") do
      [%{} = person | _] -> stringify_keys(person)
      %{} = person -> stringify_keys(person)
      _ -> %{}
    end
  end

  defp first_person_context(_metadata), do: %{}

  defp context_summary(todo, metadata, record, person, company, relationship) do
    commitment = read_string(record, "commitment")

    summary =
      first_present([
        read_string(metadata, "context"),
        todo.summary,
        read_string(record, "summary")
      ])

    identity = identity_label(person, company, relationship)

    cond do
      present?(person) and present?(summary) and title_mentions_person?(summary, person) ->
        externalize_copy(summary)

      present?(identity) and present?(summary) ->
        "#{identity}. #{externalize_copy(summary)}"

      present?(identity) and present?(commitment) ->
        "#{identity} is tied to this open commitment: #{externalize_copy(commitment)}"

      present?(summary) ->
        externalize_copy(summary)

      true ->
        "This is an open #{source_label(todo.source)} item."
    end
    |> truncate(360)
  end

  defp people_context(nil, _company, _relationship, _profile), do: []

  defp people_context(person, company, relationship, profile) do
    [
      %{
        "name" => person,
        "company" => company,
        "relationship" => relationship,
        "familiarity" => familiarity(profile),
        "relationship_strength" => read_field(profile, "relationship_strength")
      }
    ]
  end

  defp thread_state(metadata, profile) do
    conversation_context = read_map(metadata, "conversation_context")

    first_present([
      read_string(conversation_context, "momentum_state"),
      read_string(conversation_context, "notification_posture"),
      read_string(metadata, "thread_state"),
      if(read_field(profile, "stale_confirmation_candidate") == true, do: "stale"),
      "unknown"
    ])
  end

  defp owed_direction(metadata, profile) do
    first_present([
      read_string(metadata, "commitment_direction"),
      read_string(read_map(metadata, "record"), "commitment_direction"),
      if(read_field(profile, "actively_waiting") == true, do: "user_owes"),
      "unclear"
    ])
  end

  defp last_interaction(todo, metadata) do
    first_present([
      read_string(metadata, "last_interaction_at"),
      datetime_iso(todo.source_occurred_at),
      datetime_iso(todo.updated_at)
    ])
  end

  defp confidence_reason(metadata) do
    public_metadata = PublicMetadata.todo(metadata)

    first_present([
      read_string(public_metadata, "why_it_matters"),
      read_string(public_metadata, "why_now")
    ])
  end

  defp public_card_text?(value) when is_binary(value), do: PublicMetadata.public_text?(value)
  defp public_card_text?(_value), do: false

  defp missing_context(todo, metadata, person) do
    cond do
      blank?(person) ->
        "No confirmed CRM person is attached yet."

      read_field(metadata, "source_health_missing") ->
        read_string(metadata, "source_health_missing")

      todo.source in ["gmail", "calendar"] ->
        nil

      true ->
        nil
    end
  end

  defp checked_sources(source, snapshots) do
    base =
      snapshots
      |> Enum.map(&read_field(&1, "provider"))
      |> Enum.reject(&blank?/1)

    [source | base]
    |> Enum.reject(&blank?/1)
    |> Enum.map(&normalize_source/1)
    |> Enum.uniq()
  end

  defp filter_source_snapshots(snapshots, source) do
    normalized_source = normalize_source(source)

    Enum.filter(snapshots, fn snapshot ->
      normalize_source(read_field(snapshot, "provider")) == normalized_source
    end)
  end

  defp missing_relevant_sources(source, snapshots, include_disconnected?) do
    providers =
      snapshots
      |> Enum.map(&normalize_source(read_field(&1, "provider")))
      |> Enum.reject(&blank?/1)
      |> MapSet.new()

    relevant =
      cond do
        source in ["gmail", "calendar"] -> ["desktop"]
        source in ["manual", "telegram"] -> []
        true -> []
      end

    if include_disconnected? do
      Enum.reject(relevant, &MapSet.member?(providers, &1))
    else
      []
    end
  end

  defp blocking_gaps(stale, missing) do
    stale_gaps =
      Enum.map(stale, fn snapshot ->
        provider = read_field(snapshot, "provider")
        reason = read_field(snapshot, "stale_reason") || read_field(snapshot, "last_error")
        "#{provider}: #{reason || "not fresh"}"
      end)

    missing_gaps = Enum.map(missing, &"#{&1}: not connected")
    stale_gaps ++ missing_gaps
  end

  defp setup_suggestion(missing) do
    if "desktop" in missing do
      "Connect the Maraithon Desktop App to include iMessage, Apple Notes, files, reminders, and local context securely."
    end
  end

  defp telegram_context_line(card) do
    context = read_map(card, "context_pack")
    summary = read_field(context, "summary")

    if present?(summary), do: "Context: #{safe(summary)}"
  end

  defp telegram_decision_line(card) do
    decision = read_field(card, "decision_prompt")

    if present?(decision), do: "Decision: #{safe(decision)}"
  end

  defp telegram_why_line(card) do
    why_now = read_field(card, "why_now")

    if present?(why_now), do: "Why now: #{safe(why_now)}"
  end

  defp telegram_thread_line(card) do
    context = read_map(card, "context_pack")
    thread_state = humanize(read_field(context, "thread_state"))
    owed = humanize(read_field(context, "owed_direction"))

    cond do
      present?(thread_state) and present?(owed) ->
        "State: #{safe(thread_state)} · #{safe(owed)}"

      present?(thread_state) ->
        "State: #{safe(thread_state)}"

      true ->
        nil
    end
  end

  defp telegram_next_line(card) do
    next = read_field(card, "next_best_action")
    if present?(next), do: "Next: #{safe(next)}"
  end

  defp telegram_prepared_line(card) do
    case read_field(card, "prepared_actions") do
      [%{"label" => label} | _] when is_binary(label) -> "Prepared: #{safe(label)}"
      _other -> nil
    end
  end

  defp telegram_evidence_line(card) do
    case evidence_excerpt(card) do
      value when is_binary(value) -> "Evidence: #{safe(truncate(value, 180))}"
      _ -> nil
    end
  end

  defp telegram_learning_line(card) do
    case read_field(card, "attention_mode") do
      "stale_check" ->
        "Your choice will teach Maraithon whether to keep surfacing items like this."

      _ ->
        nil
    end
  end

  defp source_health_present?(source_health) do
    checked =
      read_field(source_health, "checked_sources") |> List.wrap() |> Enum.reject(&blank?/1)

    fresh = read_field(source_health, "fresh_sources") |> List.wrap() |> Enum.reject(&blank?/1)
    stale = read_field(source_health, "stale_sources") |> List.wrap() |> Enum.reject(&blank?/1)

    checked != [] or fresh != [] or stale != []
  end

  defp source_evidence_present?(context) do
    context
    |> read_field("source_evidence")
    |> List.wrap()
    |> Enum.any?(fn
      %{"excerpt" => excerpt} -> present?(excerpt)
      _ -> false
    end)
  end

  defp people_present?(people) when is_list(people) do
    Enum.any?(people, fn
      %{"name" => name} -> present?(name)
      _ -> false
    end)
  end

  defp people_present?(_people), do: false

  defp personalized_copy?(card) do
    card
    |> user_visible_card_text()
    |> Enum.reject(&blank?/1)
    |> then(fn values ->
      values != [] and Enum.all?(values, &(not generic_user_facing_copy?(&1)))
    end)
  end

  defp user_visible_card_text(card) do
    context = read_map(card, "context_pack")

    [
      read_field(card, "headline"),
      read_field(card, "decision_prompt"),
      read_field(card, "why_now"),
      read_field(card, "next_best_action"),
      read_field(context, "summary"),
      read_field(context, "relationship_context"),
      read_field(context, "project_or_topic")
    ]
  end

  defp generic_user_facing_copy?(value) when is_binary(value) do
    text = String.downcase(value)

    Enum.any?(
      [
        "user committed",
        "the user committed",
        "follow-up not yet sent",
        "no later reply or follow-through",
        "reply now with owner",
        "owner, eta",
        "owner and eta",
        "exact artifact or update",
        "confirm artifact status",
        "review and decide the next step",
        "decide whether this needs action now",
        "this appears to be waiting on you"
      ],
      &String.contains?(text, &1)
    )
  end

  defp generic_user_facing_copy?(_value), do: false

  defp primary_person_name(context) do
    case read_field(context, "people") do
      [%{"name" => name} | _] when is_binary(name) -> name
      _other -> nil
    end
  end

  defp people_label([%{"name" => name} = person | _]) do
    details =
      [read_field(person, "company"), read_field(person, "relationship")]
      |> Enum.reject(&blank?/1)

    if details == [], do: name, else: "#{name} (#{Enum.join(details, "; ")})"
  end

  defp people_label(_people), do: nil

  defp identity_label(person, company, relationship) do
    details = [company, relationship] |> Enum.reject(&blank?/1)

    cond do
      blank?(person) -> nil
      details == [] -> person
      true -> "#{person} (#{Enum.join(details, "; ")})"
    end
  end

  defp profile_why_now(profile) do
    cond do
      read_field(profile, "personal_family") == true ->
        "Personal or family logistics are ranked first."

      read_field(profile, "actively_waiting") == true ->
        "Someone appears to be waiting on a reply or commitment from you."

      read_field(profile, "business_project") == true ->
        "This is tied to an active business objective."

      true ->
        nil
    end
  end

  defp due_sentence(%Todo{due_at: %DateTime{} = due_at}) do
    "Due #{Calendar.strftime(due_at, "%b %-d at %-I:%M %p UTC")}."
  end

  defp due_sentence(_todo), do: nil

  defp created_from(metadata) do
    first_present([
      read_string(metadata, "created_from"),
      read_string(metadata, "origin"),
      read_string(metadata, "source_skill"),
      "todo"
    ])
  end

  defp familiarity(profile) do
    strength = read_field(profile, "relationship_strength") || 0
    count = read_field(profile, "interaction_count") || 0

    cond do
      strength >= 70 or count >= 20 -> "close"
      strength >= 35 or count >= 5 -> "known"
      true -> "unknown"
    end
  end

  defp explicit_confidence_level(value) when is_binary(value) do
    value = String.downcase(String.trim(value))

    cond do
      value in ["high", "strong"] -> "high"
      value in ["medium", "med", "moderate"] -> "medium"
      value in ["low", "weak"] -> "low"
      true -> value
    end
  end

  defp action_draft_present?(value) when is_binary(value), do: String.trim(value) != ""

  defp action_draft_present?(values) when is_list(values),
    do: Enum.any?(values, &action_draft_present?/1)

  defp action_draft_present?(value) when is_map(value),
    do: value |> Map.values() |> Enum.any?(&action_draft_present?/1)

  defp action_draft_present?(value), do: not is_nil(value)

  defp evidence_type(value) when is_binary(value) do
    value = String.downcase(value)

    cond do
      String.contains?(value, ["due", "deadline", "by "]) -> "deadline"
      String.contains?(value, ["asked", "request"]) -> "request"
      String.contains?(value, ["commit", "promise"]) -> "commitment"
      String.contains?(value, ["reply", "respond"]) -> "reply"
      true -> "source_context"
    end
  end

  defp normalize_source("google_calendar"), do: "calendar"
  defp normalize_source("calendar_local"), do: "desktop"
  defp normalize_source("imessage"), do: "desktop"
  defp normalize_source("notes"), do: "desktop"
  defp normalize_source(source) when is_binary(source), do: source
  defp normalize_source(_source), do: nil

  defp source_gap_labels(gaps) do
    gaps
    |> Enum.take(2)
    |> Enum.map(&source_gap_label/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "the source"
      labels -> source_list(labels)
    end
  end

  defp source_gap_label(value) when is_binary(value) do
    [source | _reason] = String.split(value, ":", parts: 2)

    case safe_source_name(source) do
      nil -> nil
      safe_source -> source_label(safe_source)
    end
  end

  defp source_gap_label(_value), do: nil

  defp source_gap_note(gaps, blocked_sources) do
    other_gaps =
      Enum.reject(gaps, fn gap ->
        source_gap_source(gap) == "desktop"
      end)

    [
      if(MapSet.member?(blocked_sources, "desktop"),
        do: "Local context from the Mac companion was not checked."
      ),
      if(other_gaps != [],
        do: "Could not fully check #{source_gap_labels(other_gaps)} before sending this."
      )
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp source_gap_sources(gaps) do
    gaps
    |> Enum.map(&source_gap_source/1)
    |> Enum.reject(&blank?/1)
    |> MapSet.new()
  end

  defp source_gap_source(value) when is_binary(value) do
    [source | _reason] = String.split(value, ":", parts: 2)

    case safe_source_name(source) do
      nil -> nil
      safe_source -> normalize_source(safe_source)
    end
  end

  defp source_gap_source(_value), do: nil

  defp source_setup_action(blocked_sources) do
    if MapSet.member?(blocked_sources, "desktop") do
      "Open the Mac companion app to reconnect it."
    end
  end

  defp source_list(sources) do
    sources
    |> Enum.take(4)
    |> Enum.map(&source_list_label/1)
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "the source"
      labels -> safe(Enum.join(labels, ", "))
    end
  end

  defp source_list_label(source) when is_binary(source) do
    case safe_source_name(source) do
      nil -> nil
      safe_source -> source_label(safe_source)
    end
  end

  defp source_list_label(_source), do: nil

  defp safe_source_name(value) when is_binary(value) do
    trimmed = String.trim(value)
    lower = String.downcase(trimmed)

    if trimmed == "" or Enum.any?(@unsafe_source_gap_markers, &String.contains?(lower, &1)),
      do: nil,
      else: trimmed
  end

  defp safe_source_name(_value), do: nil

  defp source_label(source) when source in @assistant_sources, do: "Maraithon"
  defp source_label("system"), do: "Maraithon"
  defp source_label("desktop"), do: "Desktop App"
  defp source_label(source) when is_binary(source), do: SourceLabels.label(source)
  defp source_label(_source), do: "Maraithon"

  defp humanize(nil), do: nil
  defp humanize(""), do: nil

  defp humanize(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
  end

  defp humanize(value), do: to_string(value)

  defp naturalize_action_copy(value) when is_binary(value) do
    value
    |> UserFacingCopy.polish_text()
    |> String.replace(
      ~r/\s+for a one-line status update covering current state, owner, fix window if still open, and any user or customer impact\.?/i,
      ": is it resolved, who owns it, and were any users or customers affected?"
    )
    |> String.replace(
      ~r/\s+for a one-line status update covering current state, fix window if still open, and any user or customer impact\.?/i,
      ": is it resolved, who owns it, and were any users or customers affected?"
    )
    |> single_line()
  end

  defp naturalize_action_copy(value), do: value

  defp externalize_copy(value) when is_binary(value) do
    value
    |> UserFacingCopy.polish_text()
    |> strip_internal_lines()
    |> replace_internal_language()
    |> naturalize_action_copy()
  end

  defp externalize_copy(value), do: value

  defp strip_internal_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reject(fn line ->
      String.match?(line, ~r/^\s*(open|title|priority|status|source|from)\s*:/i)
    end)
    |> Enum.join("\n")
  end

  defp replace_internal_language(text) do
    text
    |> String.replace(~r/\bthe user wants\b/i, "You want")
    |> String.replace(~r/\bthe user needs\b/i, "You need")
    |> String.replace(~r/\bthe user has\b/i, "You have")
    |> String.replace(~r/\bthe user is\b/i, "You are")
    |> String.replace(~r/\bthe user should\b/i, "You should")
    |> String.replace(~r/\bKent needs\b/i, "you need")
    |> String.replace(~r/\bKent has\b/i, "you have")
    |> String.replace(~r/\bKent should\b/i, "you should")
    |> String.replace(~r/\bKent is\b/i, "you are")
    |> String.replace(~r/\bthe user\b/i, "you")
    |> String.replace(
      ~r/\bquick status check on whether the issue is resolved, who owns it, and whether users or customers were affected\b/i,
      "quick answer on whether it is fixed, who owns the follow-up, and whether any users or customers were affected"
    )
    |> String.replace(~r/\bChief_of_staff_morning_briefing\b/i, "my morning briefing")
    |> String.replace(~r/\bchief_of_staff_morning_briefing\b/i, "my morning briefing")
    |> String.replace(~r/\bChief_of_staff_commitment_tracker\b/i, "my commitment tracker")
    |> String.replace(~r/\bchief_of_staff_commitment_tracker\b/i, "my commitment tracker")
  end

  defp clean_title(value) when is_binary(value) do
    value
    |> UserFacingCopy.polish_text()
    |> String.replace(~r/^\s*(todo|action|next)\s*:\s*/i, "")
    |> single_line()
    |> truncate(120)
  end

  defp clean_title(_value), do: "Review this item"

  defp title_mentions_person?(title, person) when is_binary(title) and is_binary(person) do
    title = String.downcase(title)

    person
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> case do
      [] -> false
      parts -> Enum.all?(parts, &String.contains?(title, &1))
    end
  end

  defp title_mentions_person?(_title, _person), do: false

  defp map_to_todo(map) do
    metadata = read_map(map, "metadata")

    %Todo{
      id: read_string(map, "id") || "preview",
      user_id: read_string(map, "user_id"),
      source: read_string(map, "source") || "manual",
      source_account_label: read_string(map, "source_account_label"),
      kind: read_string(map, "kind") || "general",
      attention_mode: read_string(map, "attention_mode") || "act_now",
      title: read_string(map, "title") || read_string(map, "next_action") || "Review this item",
      summary: read_string(map, "summary") || "Review this item.",
      next_action:
        read_string(map, "next_action") ||
          "Open the source item, confirm the real ask, then choose done, dismiss, or a short reply.",
      due_at: read_datetime(map, "due_at"),
      notes: read_string(map, "notes"),
      action_draft: read_map(map, "action_draft"),
      priority: read_integer(map, "priority", 50),
      status: read_string(map, "status") || "open",
      source_item_id: read_string(map, "source_item_id"),
      source_occurred_at: read_datetime(map, "source_occurred_at"),
      dedupe_key: read_string(map, "dedupe_key") || "preview",
      metadata: metadata,
      inserted_at: read_datetime(map, "inserted_at") || DateTime.utc_now(),
      updated_at: read_datetime(map, "updated_at") || DateTime.utc_now()
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = if is_atom(key), do: Atom.to_string(key), else: key
      value = if is_map(value), do: stringify_keys(value), else: value
      {key, value}
    end)
  end

  defp read_map(map, key) when is_map(map) do
    case read_field(map, key) do
      value when is_map(value) -> stringify_keys(value)
      _other -> %{}
    end
  end

  defp read_map(_map, _key), do: %{}

  defp read_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, safe_existing_atom(key))
  end

  defp read_field(_map, _key), do: nil

  defp read_string(map, key) when is_map(map) do
    case read_field(map, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_integer(value) ->
        Integer.to_string(value)

      value when is_float(value) ->
        Float.to_string(value)

      _other ->
        nil
    end
  end

  defp read_string(_map, _key), do: nil

  defp read_integer(map, key, default) when is_map(map) do
    case read_field(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end

  defp read_integer(_map, _key, default), do: default

  defp read_datetime(map, key) when is_map(map) do
    case read_field(map, key) do
      %DateTime{} = value ->
        value

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp read_datetime(_map, _key), do: nil

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp first_present(values), do: Enum.find(values, &present?/1)
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(value), do: not is_nil(value)
  defp blank?(value), do: not present?(value)

  defp single_line(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      text
      |> String.slice(0, max_length)
      |> String.trim()
      |> Kernel.<>("...")
    else
      text
    end
  end

  defp datetime_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_iso(_datetime), do: nil

  defp html_line(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: safe(value)
  end

  defp html_line(_value), do: nil

  defp safe(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp safe(value), do: value |> to_string() |> safe()
end
