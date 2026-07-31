defmodule Maraithon.TelegramAssistant.ProactiveQueue do
  @moduledoc """
  Persistence boundary for proactive delivery candidates.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.Normalization
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.ProactiveCandidate

  require Logger

  @default_candidate_ttl_minutes 120
  @default_due_user_limit 25
  @live_statuses ~w(pending planned)
  # SPEC 02 R7: a "held" candidate has no expires_at-based owner (its
  # original expires_at is stale pre-hold data); age is measured from
  # updated_at (when it was held). 7 days.
  @default_held_ttl_minutes 10_080

  def enqueue(attrs) when is_map(attrs) do
    normalized = normalize_attrs(attrs)

    %ProactiveCandidate{}
    |> ProactiveCandidate.enqueue_changeset(normalized)
    |> Repo.insert()
    |> case do
      {:ok, candidate} ->
        {:ok, candidate}

      {:error, changeset} = error ->
        if live_dedupe_error?(changeset) do
          case get_live(normalized["user_id"], normalized["dedupe_key"]) do
            %ProactiveCandidate{} = candidate -> {:ok, candidate}
            nil -> error
          end
        else
          error
        end
    end
  end

  def enqueue(_attrs), do: {:error, :invalid_proactive_candidate}

  def list_pending_for_user(user_id, opts \\ [])

  def list_pending_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    ProactiveCandidate
    |> where([candidate], candidate.user_id == ^user_id)
    |> where([candidate], candidate.status == "pending")
    |> where([candidate], candidate.expires_at > ^now)
    |> order_by([candidate], desc: candidate.urgency, asc: candidate.inserted_at)
    |> Repo.all()
  end

  def list_pending_for_user(_user_id, _opts), do: []

  @default_held_limit 25

  @doc """
  Held candidates (model-chosen hold, or downgraded by quiet hours/the
  interruption budget at send time) that still need to reach the operator.
  Callers that surface these (for example the morning briefing) are
  expected to mark them delivered once included so they do not repeat
  forever — see `mark_delivered/1`.
  """
  def list_held_for_user(user_id, opts \\ [])

  def list_held_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_held_limit) |> positive_integer()

    ProactiveCandidate
    |> where([candidate], candidate.user_id == ^user_id)
    |> where([candidate], candidate.status == "held")
    |> order_by([candidate], desc: candidate.urgency, asc: candidate.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_held_for_user(_user_id, _opts), do: []

  @doc """
  Held candidates mapped to the prompt shape shared by the morning briefing
  and the calendar check-in (SPEC 02 R8). Kept here so both skills read one
  field mapping instead of duplicating it.
  """
  def held_interruptions_for_prompt(user_id, opts \\ []) do
    user_id
    |> list_held_for_user(opts)
    |> Enum.map(fn candidate ->
      %{
        "id" => candidate.id,
        "source" => candidate.source,
        "title" => candidate.title,
        "body" => candidate.body,
        "why_now" => candidate.why_now,
        "urgency" => candidate.urgency,
        "hold_reason" => candidate.plan_reason,
        "held_since" => held_since(candidate.updated_at)
      }
    end)
  end

  defp held_since(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp held_since(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp held_since(_value), do: nil

  def pending_user_ids(opts \\ [])

  def pending_user_ids(limit) when is_integer(limit), do: pending_user_ids(limit: limit)

  def pending_user_ids(opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = opts |> Keyword.get(:limit, @default_due_user_limit) |> positive_integer()

    ProactiveCandidate
    |> where([candidate], candidate.status == "pending")
    |> where([candidate], candidate.expires_at > ^now)
    |> group_by([candidate], candidate.user_id)
    |> order_by([candidate], asc: min(candidate.inserted_at))
    |> limit(^limit)
    |> select([candidate], candidate.user_id)
    |> Repo.all()
  end

  def mark_planned(candidate_or_id, disposition, reason) do
    with %ProactiveCandidate{} = candidate <- get_candidate(candidate_or_id) do
      candidate
      |> ProactiveCandidate.plan_changeset(disposition, reason)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  def mark_delivered(candidate_or_id), do: update_status(candidate_or_id, "delivered")
  def mark_held(candidate_or_id), do: update_status(candidate_or_id, "held")

  @doc """
  Returns a candidate whose dispatch failed to "pending" so the next planner
  cycle retries it. "planned" is not a resting state — nothing re-reads it —
  so leaving a failed dispatch there strands the candidate (and, through the
  live-dedupe index, blocks its source from re-enqueueing) until the TTL
  sweep expires it. Retries stay bounded by `expires_at`.
  """
  def mark_pending(candidate_or_id), do: update_status(candidate_or_id, "pending")

  def expire_stale(now \\ DateTime.utc_now()) do
    {count, _rows} =
      ProactiveCandidate
      |> where([candidate], candidate.status in ^@live_statuses)
      |> where([candidate], candidate.expires_at <= ^now)
      |> Repo.update_all(set: [status: "expired", updated_at: DateTime.utc_now()])

    count
  end

  @doc """
  Expires "held" candidates that have sat unreviewed past the held TTL
  (SPEC 02 R7). Age is measured from `updated_at` (when the candidate was
  held) — never from `expires_at`, which reflects the stale pre-hold TTL,
  and never in `list_held_for_user/2`'s urgency-ordered display window,
  which would hide the low-urgency stale tail from the sweep.

  Only touches `status == "held"` rows, so re-running is a no-op for rows
  already expired. Each expired row gets one `ActionLedger` entry
  (`held_interruption_expired`) so the drop is auditable, never silent.

  Returns the list of expired rows as `%{id:, user_id:, title:, held_since:}`
  maps so the caller (the stuck-state watchdog) can narrate the self-heal.
  """
  def expire_stale_held(now \\ DateTime.utc_now(), ttl_minutes \\ @default_held_ttl_minutes) do
    cutoff = DateTime.add(now, -ttl_minutes * 60, :second)

    stale =
      ProactiveCandidate
      |> where([candidate], candidate.status == "held")
      |> where([candidate], candidate.updated_at <= ^cutoff)
      |> select([candidate], %{
        id: candidate.id,
        user_id: candidate.user_id,
        title: candidate.title,
        held_since: candidate.updated_at
      })
      |> Repo.all()

    case stale do
      [] ->
        []

      rows ->
        ids = Enum.map(rows, & &1.id)

        {_count, expired_ids} =
          ProactiveCandidate
          |> where([candidate], candidate.id in ^ids)
          |> where([candidate], candidate.status == "held")
          |> select([candidate], candidate.id)
          |> Repo.update_all(set: [status: "expired", updated_at: now])

        expired_ids = MapSet.new(expired_ids || [])
        expired = Enum.filter(rows, &MapSet.member?(expired_ids, &1.id))
        Enum.each(expired, &record_held_expiry/1)
        expired
    end
  end

  defp record_held_expiry(row) do
    _ =
      ActionLedger.record(%{
        user_id: row.user_id,
        surface: "runtime",
        event_type: "held_interruption_expired",
        status: "completed",
        metadata: %{
          "candidate_id" => row.id,
          "held_since" => held_since(row.held_since)
        }
      })

    :ok
  rescue
    error ->
      Logger.warning("Failed to record held interruption expiry",
        candidate_id: row.id,
        reason: Exception.message(error)
      )

      :ok
  end

  def default_held_ttl_minutes, do: @default_held_ttl_minutes

  def candidate_ttl_minutes do
    :maraithon
    |> Application.get_env(:telegram_assistant, [])
    |> Keyword.get(:proactive_candidate_ttl_minutes, @default_candidate_ttl_minutes)
    |> normalize_ttl_minutes()
  end

  defp update_status(candidate_or_id, status) do
    with %ProactiveCandidate{} = candidate <- get_candidate(candidate_or_id) do
      candidate
      |> ProactiveCandidate.status_changeset(status)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  defp get_candidate(%ProactiveCandidate{} = candidate), do: candidate
  defp get_candidate(id) when is_binary(id), do: Repo.get(ProactiveCandidate, id)
  defp get_candidate(_candidate_or_id), do: nil

  defp get_live(user_id, dedupe_key) when is_binary(user_id) and is_binary(dedupe_key) do
    ProactiveCandidate
    |> where([candidate], candidate.user_id == ^user_id)
    |> where([candidate], candidate.dedupe_key == ^dedupe_key)
    |> where([candidate], candidate.status in ^@live_statuses)
    |> order_by([candidate], desc: candidate.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp get_live(_user_id, _dedupe_key), do: nil

  defp live_dedupe_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:user_id, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "proactive_candidates_live_dedupe_index"

      {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == "proactive_candidates_live_dedupe_index"
    end)
  end

  defp normalize_attrs(attrs) do
    attrs = Normalization.stringify_keys(attrs)

    attrs
    |> Map.put_new("status", "pending")
    |> Map.put_new("expires_at", default_expires_at())
    |> Map.update("structured_data", %{}, &normalize_map/1)
    |> Map.update("telegram_opts", %{}, &normalize_map/1)
    |> Map.update("urgency", 0.0, &normalize_urgency/1)
  end

  defp normalize_map(value) when is_map(value), do: normalize_json_value(value)

  defp normalize_map(value) when is_list(value) do
    Map.new(value, fn {key, nested} ->
      {to_string(key), normalize_json_value(nested)}
    end)
  rescue
    _error -> %{}
  end

  defp normalize_map(_value), do: %{}

  defp normalize_json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_json_value(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_json_value(value) when is_boolean(value), do: value
  defp normalize_json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_json_value(value) when is_list(value),
    do: Enum.map(value, &normalize_json_value/1)

  defp normalize_json_value(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_json_value()
  end

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize_json_value(nested)} end)
  end

  defp normalize_json_value(value), do: value

  defp normalize_urgency(value) when is_float(value), do: min(max(value, 0.0), 1.0)
  defp normalize_urgency(value) when is_integer(value), do: normalize_urgency(value / 1)

  defp normalize_urgency(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> normalize_urgency(parsed)
      _other -> 0.0
    end
  end

  defp normalize_urgency(_value), do: 0.0

  defp default_expires_at do
    DateTime.utc_now()
    |> DateTime.add(candidate_ttl_minutes() * 60, :second)
    |> DateTime.truncate(:second)
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_due_user_limit
    end
  end

  defp positive_integer(_value), do: @default_due_user_limit

  defp normalize_ttl_minutes(value) when is_integer(value) and value > 0, do: value

  defp normalize_ttl_minutes(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_candidate_ttl_minutes
    end
  end

  defp normalize_ttl_minutes(_value), do: @default_candidate_ttl_minutes
end
