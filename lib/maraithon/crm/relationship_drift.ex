defmodule Maraithon.Crm.RelationshipDrift do
  @moduledoc """
  Turns the CRM's relationship-drift signal into proactive nudge
  *candidates* (SPEC 03 / GOALS #4: "You usually talk to Charlie weekly,
  but it has been 18 days").

  `Maraithon.Crm.CommunicationScore` already computes overdue cadences and
  `Maraithon.Crm.ReconnectSuggestions` already ranks and phrases them — but
  until now only pull surfaces (the People tab) read that output. This
  module is a candidate producer mirroring `Maraithon.Proactive.LocalPatterns`:
  on every Chief of Staff wakeup (`Maraithon.ChiefOfStaff.Skills.LocalPatternReview`)
  it reads the `:overdue` / `:going_quiet` reconnect suggestions and records
  the top few as `status: "candidate"` insights via
  `Maraithon.Insights.record_many/4`, so a model relevance decision — not
  the heuristic — decides what reaches the user, through the unmodified
  Insights -> InsightNotifications -> DeliveryPlanner -> PushBroker pipeline
  (score threshold, memory gate, interruption budget, quiet hours, receipts).
  Drift candidates get no budget bypass of any kind.

  Durability invariants (SPEC 03 — all cooldown/dedupe state lives in the
  `insights` table, never in GenServer state):

    * **One row per person, forever.** `dedupe_key == tracking_key ==
      "relationship_drift:<person_id>"` — never date-bucketed (unlike
      `LocalPatterns`), so rollover can never orphan unreviewed candidate
      rows or create two live insights for the same person.
    * **Per-person cooldown.** A person whose row is `"acknowledged"` /
      `"dismissed"` is *skipped entirely* (no `record_many` call) until
      `@cooldown_days` have passed since that row's `updated_at`. The gate
      must be this application-level skip: the upsert's `source_occurred_at`
      "newer detection" semantics would otherwise reopen the row on every
      cycle.
    * **Auto-clear on resumed contact.** When a person stops qualifying,
      their open (`"new"`/`"snoozed"`) drift insight is resolved via
      `Insights.resolve_many_from_source/2` with a `contact_resumed`
      auto-resolution, and a never-reviewed `"candidate"` row is dismissed
      directly (`resolve_many_from_source` only matches open statuses).
    * The person's name is always in `title`/`summary` plain text so
      `MemoryGate` semantic recall can honor "never remind me about X".
  """

  import Ecto.Query

  require Logger

  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Crm.Person
  alias Maraithon.Crm.ReconnectSuggestions
  alias Maraithon.Insights
  alias Maraithon.Insights.Insight
  alias Maraithon.Repo
  alias Maraithon.UserIdentity

  @system_behavior "prompt_agent"
  @system_config_marker %{"system" => "relationship_drift"}

  @drift_categories [:overdue, :going_quiet]
  @max_candidates_per_cycle 3
  @cooldown_days 7
  @suggestion_pool 50

  # R4: communication_signals are only refreshed when communication_score_refresh
  # runs; past this age the specific day-count is treated as unreliable and
  # confidence degrades (the copy already comes verbatim from
  # ReconnectSuggestions, which never asserts numbers it cannot stand behind).
  @signal_staleness_days 14
  @base_confidence %{overdue: 0.65, going_quiet: 0.55}
  @stale_confidence_penalty 0.15
  @confidence_floor 0.2

  @pending_statuses ["new", "candidate", "snoozed"]
  @reviewed_statuses ["acknowledged", "dismissed"]

  @doc """
  Gathers relationship-drift candidates for a single user.

  Options: `:now` (for tests), `:cooldown_days` (default #{@cooldown_days}).

  Returns `{:ok, %{recorded: n, cleared: n}}`, or `{:error, reason}` when the
  system agent cannot be ensured (logged, never raised — the CoS wakeup must
  proceed regardless).
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    cooldown_days = Keyword.get(opts, :cooldown_days, @cooldown_days)

    case ensure_system_agent(user_id) do
      {:ok, %Agent{id: agent_id}} ->
        drifted = drifted_suggestions(user_id, now)

        # R5's qualifying set is every still-drifted person (before the
        # per-cycle top-N cut and before the cooldown filter): a person who
        # merely ranked below this cycle's slots has not "resumed contact"
        # and must not have their open insight resolved.
        qualifying_ids = MapSet.new(drifted, & &1.person.id)
        cleared = auto_clear_resumed(user_id, qualifying_ids, now)

        attrs =
          drifted
          |> Enum.take(@max_candidates_per_cycle)
          |> Enum.filter(&outside_cooldown?(user_id, &1.person.id, now, cooldown_days))
          |> Enum.map(&insight_attrs(&1, now))

        {:ok, recorded} = Insights.record_many(user_id, agent_id, attrs, status: "candidate")

        {:ok, %{recorded: length(recorded), cleared: cleared}}

      {:error, reason} ->
        Logger.warning("RelationshipDrift could not ensure system agent",
          user_id: user_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------
  # Gathering (pure reuse of ReconnectSuggestions — no re-derived math)
  # ---------------------------------------------------------------------

  defp drifted_suggestions(user_id, now) do
    own_handles = UserIdentity.handle_set(user_id)

    # goal_slots: 0 so all pool slots are available to the categories this
    # module actually reads (suggestions/2 would otherwise reserve slots for
    # :goal_aligned entries we discard anyway).
    user_id
    |> ReconnectSuggestions.suggestions(limit: @suggestion_pool, goal_slots: 0, now: now)
    |> Enum.filter(&(&1.category in @drift_categories))
    |> Enum.reject(&self_person?(own_handles, &1.person))
  end

  # Defensive self re-check: CommunicationScore zeroes self-people's score,
  # but :going_quiet can fire on relationship_strength/network_rank alone,
  # which is not zeroed the same way.
  defp self_person?(own_handles, %Person{contact_details: details}) do
    details
    |> contact_handles()
    |> Enum.any?(fn handle ->
      case UserIdentity.normalize_handle(handle) do
        nil -> false
        normalized -> MapSet.member?(own_handles, normalized)
      end
    end)
  end

  defp contact_handles(details) when is_map(details) do
    [Map.get(details, "emails"), Map.get(details, "phones")]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.filter(&is_binary/1)
  end

  defp contact_handles(_details), do: []

  # ---------------------------------------------------------------------
  # R3 — durable per-person cooldown (application-level gate; never rely
  # on the upsert's on_conflict semantics to enforce it)
  # ---------------------------------------------------------------------

  defp outside_cooldown?(user_id, person_id, now, cooldown_days) do
    case Repo.get_by(Insight, user_id: user_id, dedupe_key: insight_key(person_id)) do
      %Insight{status: status, updated_at: updated_at} when status in @reviewed_statuses ->
        DateTime.diff(now, updated_at, :day) >= cooldown_days

      # No row yet, or a still-open/pending row ("new"/"candidate"/"snoozed"):
      # always safe to re-include — the upsert is an idempotent refresh.
      _missing_or_pending ->
        true
    end
  end

  # ---------------------------------------------------------------------
  # R6 — insight field mapping
  # ---------------------------------------------------------------------

  defp insight_attrs(suggestion, now) do
    person = suggestion.person
    name = first_name(person)
    key = insight_key(person.id)

    %{
      "source" => "relationship_drift",
      "category" => "relationship_drift",
      "title" => "Reconnect with #{name}",
      "summary" => suggestion.reason,
      "recommended_action" => suggestion.suggested_action,
      "priority" => round(suggestion.priority),
      "confidence" => confidence(suggestion.category, stale_signals?(person, now)),
      "source_id" => person.id,
      # Only ever set for people that survived the R3 cooldown gate — setting
      # this on every attempt would flip resolved rows back to "candidate"
      # at the database layer (on_conflict "newer detection" CASE).
      "source_occurred_at" => now,
      "tracking_key" => key,
      "dedupe_key" => key,
      "metadata" => %{
        "detector" => "relationship_drift",
        "drift_category" => to_string(suggestion.category),
        "person_id" => person.id,
        "person_name" => name,
        "days_since_last" => suggestion.days_since_last,
        "cadence_days" => suggestion.cadence_days
      }
    }
  end

  defp confidence(category, stale?) do
    base = Map.fetch!(@base_confidence, category)

    if stale? do
      max(base - @stale_confidence_penalty, @confidence_floor)
    else
      base
    end
  end

  # R4: missing, unparsable, or >14-day-old computed_at means the day-count
  # frozen inside communication_signals may under-count real elapsed time.
  defp stale_signals?(%Person{metadata: metadata}, now) when is_map(metadata) do
    signals = Map.get(metadata, "communication_signals")
    computed_at = if is_map(signals), do: Map.get(signals, "computed_at")

    case computed_at do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, at, _offset} -> DateTime.diff(now, at, :day) > @signal_staleness_days
          _ -> true
        end

      _ ->
        true
    end
  end

  defp stale_signals?(_person, _now), do: true

  # ---------------------------------------------------------------------
  # R5 — auto-clear when contact resumes
  # ---------------------------------------------------------------------

  defp auto_clear_resumed(user_id, qualifying_ids, now) do
    Insight
    |> where([i], i.user_id == ^user_id and i.category == "relationship_drift")
    |> where([i], i.status in ^@pending_statuses)
    |> Repo.all()
    |> Enum.reject(fn insight ->
      case person_id_from_key(insight.tracking_key) do
        nil -> false
        person_id -> MapSet.member?(qualifying_ids, person_id)
      end
    end)
    |> Enum.reduce(0, fn insight, cleared ->
      case clear_insight(user_id, insight, now) do
        :ok -> cleared + 1
        :error -> cleared
      end
    end)
  end

  # A "candidate" never reached the user; resolve_many_from_source only
  # matches open statuses ("new"/"snoozed") and would silently no-op on it.
  defp clear_insight(user_id, %Insight{status: "candidate"} = insight, _now) do
    case Insights.dismiss(user_id, insight.id) do
      {:ok, _insight} -> :ok
      _error -> :error
    end
  end

  defp clear_insight(user_id, %Insight{} = insight, now) do
    resolution = %{
      "tracking_key" => insight.tracking_key,
      "dedupe_key" => insight.tracking_key,
      "source" => "relationship_drift",
      "source_occurred_at" => now,
      "metadata" => %{"auto_resolution" => %{"reason" => "contact_resumed"}}
    }

    case Insights.resolve_many_from_source(user_id, [resolution]) do
      {:ok, _insights} -> :ok
      _error -> :error
    end
  end

  # ---------------------------------------------------------------------
  # Keys
  # ---------------------------------------------------------------------

  defp insight_key(person_id), do: "relationship_drift:#{person_id}"

  defp person_id_from_key("relationship_drift:" <> person_id), do: person_id
  defp person_id_from_key(_key), do: nil

  # ---------------------------------------------------------------------
  # System agent (same pattern as LocalPatterns.ensure_system_agent/1 —
  # duplicated because that helper is private there)
  # ---------------------------------------------------------------------

  defp ensure_system_agent(user_id) do
    case Repo.one(
           from agent in Agent,
             where:
               agent.user_id == ^user_id and agent.behavior == ^@system_behavior and
                 fragment("?->>'system' = ?", agent.config, "relationship_drift"),
             order_by: [asc: agent.inserted_at],
             limit: 1
         ) do
      %Agent{} = agent ->
        {:ok, agent}

      nil ->
        case Agents.create_agent(%{
               user_id: user_id,
               behavior: @system_behavior,
               config: @system_config_marker,
               install_status: "enabled",
               status: "stopped"
             }) do
          {:ok, agent} -> {:ok, agent}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ---------------------------------------------------------------------
  # Naming (mirrors ReconnectSuggestions' private first_name/1 so the title
  # always carries the same plain-text name as the summary copy)
  # ---------------------------------------------------------------------

  defp first_name(%Person{first_name: first}) when is_binary(first) do
    case String.trim(first) do
      "" -> "them"
      value -> value
    end
  end

  defp first_name(%Person{display_name: display}) when is_binary(display) do
    display
    |> String.trim()
    |> String.split(" ", trim: true)
    |> List.first()
    |> case do
      nil -> "them"
      value -> value
    end
  end

  defp first_name(_person), do: "them"
end
