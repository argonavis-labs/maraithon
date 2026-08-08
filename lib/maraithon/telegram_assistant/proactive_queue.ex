defmodule Maraithon.TelegramAssistant.ProactiveQueue do
  @moduledoc """
  Persistence boundary for proactive delivery candidates.
  """

  import Ecto.Query

  alias Maraithon.Accounts.User
  alias Maraithon.ActionLedger
  alias Maraithon.Push.Device
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.ProactiveCandidate

  require Logger

  @default_candidate_ttl_minutes 120
  @default_due_user_limit 25
  @default_pending_candidate_limit 25
  @max_required_candidate_share 12
  @max_query_limit 100
  @live_statuses ~w(pending planned)
  @expirable_live_statuses ~w(pending planned)
  # SPEC 02 R7: a "held" candidate has no expires_at-based owner (its
  # original expires_at is stale pre-hold data); age is measured from
  # updated_at (when it was held). 7 days.
  @default_held_ttl_minutes 10_080
  @enqueue_attr_keys ~w(
    user_id source source_id dedupe_key title body urgency expires_at why_now structured_data
    telegram_opts status disposition plan_reason planned_at delivered_at
  )
  @enqueue_string_byte_caps %{
    "user_id" => 1_280,
    "source" => 100,
    "source_id" => 1_020,
    "dedupe_key" => 1_020,
    "title" => 1_020,
    "body" => 40_000,
    "why_now" => 8_000,
    "status" => 100,
    "disposition" => 100,
    "plan_reason" => 8_000
  }

  def enqueue(attrs) when is_map(attrs) do
    if enqueue_json_safe?(attrs) do
      do_enqueue(attrs)
    else
      {:error, :invalid_proactive_candidate}
    end
  end

  def enqueue(_attrs), do: {:error, :invalid_proactive_candidate}

  defp do_enqueue(attrs) do
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

  defp enqueue_json_safe?(attrs) do
    structured_data = Map.get(attrs, :structured_data, Map.get(attrs, "structured_data", %{}))
    telegram_opts = Map.get(attrs, :telegram_opts, Map.get(attrs, "telegram_opts", %{}))

    raw_json_safe?(structured_data, 256_000) and raw_json_safe?(telegram_opts, 32_000) and
      enqueue_scalars_safe?(attrs)
  end

  defp enqueue_scalars_safe?(attrs) do
    strings_safe? =
      Enum.all?(@enqueue_string_byte_caps, fn {key, max_bytes} ->
        case raw_attr(attrs, key) do
          :missing -> true
          value when is_binary(value) -> String.valid?(value) and byte_size(value) <= max_bytes
          nil -> true
          _invalid -> false
        end
      end)

    urgency_safe? =
      case raw_attr(attrs, "urgency") do
        :missing ->
          true

        value when is_integer(value) ->
          value >= 0 and value <= 1

        value when is_float(value) ->
          value >= 0.0 and value <= 1.0

        value when is_binary(value) and byte_size(value) <= 32 ->
          if not String.valid?(value) do
            false
          else
            case Float.parse(String.trim(value)) do
              {parsed, ""} -> parsed >= 0.0 and parsed <= 1.0
              _invalid -> false
            end
          end

        _invalid ->
          false
      end

    times_safe? =
      Enum.all?(~w(expires_at planned_at delivered_at), fn key ->
        case raw_attr(attrs, key) do
          :missing -> true
          nil -> true
          %DateTime{} -> true
          %NaiveDateTime{} -> true
          value when is_binary(value) -> String.valid?(value) and byte_size(value) <= 100
          _invalid -> false
        end
      end)

    strings_safe? and urgency_safe? and times_safe?
  end

  defp raw_json_safe?(value, max_bytes) when is_map(value),
    do: ProactiveCandidate.safe_json_shape?(value, max_bytes)

  defp raw_json_safe?(value, max_bytes) when is_list(value) do
    try do
      prefix = Enum.take(value, 2_001)

      if length(prefix) > 2_000 do
        false
      else
        entries = Enum.map(prefix, fn {key, nested} -> %{key => nested} end)
        ProactiveCandidate.safe_json_shape?(entries, max_bytes)
      end
    rescue
      _error -> false
    end
  end

  defp raw_json_safe?(_value, _max_bytes), do: false

  def list_pending_for_user(user_id, opts \\ [])

  def list_pending_for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    pending_query =
      ProactiveCandidate
      |> where([candidate], candidate.user_id == ^user_id)
      |> where([candidate], candidate.status == "pending")
      |> where([candidate], candidate.expires_at > ^now)

    case Keyword.fetch(opts, :candidate_limit) do
      :error ->
        pending_query
        |> order_by([candidate],
          desc: candidate.urgency,
          asc: candidate.inserted_at,
          asc: candidate.id
        )
        |> Repo.all()

      {:ok, value} ->
        candidate_limit = positive_integer(value, @default_pending_candidate_limit)
        list_bounded_pending(pending_query, candidate_limit)
    end
  end

  def list_pending_for_user(_user_id, _opts), do: []

  defp list_bounded_pending(pending_query, candidate_limit) do
    required_limit = min(candidate_limit, @max_required_candidate_share)

    required =
      pending_query
      |> where([candidate], candidate.source == "brief")
      |> order_by([candidate], asc: candidate.inserted_at, asc: candidate.id)
      |> limit(^required_limit)
      |> Repo.all()

    remaining = max(candidate_limit - length(required), 0)
    rotation_quota = div(remaining, 3)
    priority_quota = remaining - rotation_quota
    required_ids = Enum.map(required, & &1.id)

    priority =
      pending_query
      |> where([candidate], candidate.source != "brief")
      |> exclude_candidate_ids(required_ids)
      |> order_by([candidate],
        desc: candidate.urgency,
        asc: candidate.inserted_at,
        asc: candidate.id
      )
      |> limit(^priority_quota)
      |> Repo.all()

    selected_ids = required_ids ++ Enum.map(priority, & &1.id)
    rotation_limit = max(candidate_limit - length(selected_ids), 0)

    rotation =
      pending_query
      |> where([candidate], candidate.source != "brief")
      |> exclude_candidate_ids(selected_ids)
      |> order_by([candidate], asc: candidate.inserted_at, asc: candidate.id)
      |> limit(^rotation_limit)
      |> Repo.all()

    (required ++ priority ++ rotation)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(fn candidate ->
      {-1 * (candidate.urgency || 0.0), candidate.inserted_at, candidate.id}
    end)
  end

  defp exclude_candidate_ids(query, []), do: query

  defp exclude_candidate_ids(query, candidate_ids) do
    where(query, [candidate], candidate.id not in ^candidate_ids)
  end

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
    limit =
      opts |> Keyword.get(:limit, @default_held_limit) |> positive_integer(@default_held_limit)

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

    limit =
      opts
      |> Keyword.get(:limit, @default_due_user_limit)
      |> positive_integer(@default_due_user_limit)

    ProactiveCandidate
    |> where([candidate], candidate.status == "pending")
    |> where([candidate], candidate.expires_at > ^now)
    |> group_by([candidate], candidate.user_id)
    |> order_by([candidate], asc: min(candidate.inserted_at), asc: candidate.user_id)
    |> limit(^limit)
    |> select([candidate], candidate.user_id)
    |> Repo.all()
  end

  @doc """
  Returns pending users who currently have at least one active push device.

  Device-less users are deliberately filtered before the batch limit so they
  cannot indefinitely occupy every planner slot while their candidates wait
  for expiry or a future device registration.
  """
  def pending_deliverable_user_ids(opts \\ [])

  def pending_deliverable_user_ids(limit) when is_integer(limit),
    do: pending_deliverable_user_ids(limit: limit)

  def pending_deliverable_user_ids(opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    limit =
      opts
      |> Keyword.get(:limit, @default_due_user_limit)
      |> positive_integer(@default_due_user_limit)

    ProactiveCandidate
    |> join(:inner, [candidate], device in Device,
      on: device.user_id == candidate.user_id and device.status == "active"
    )
    |> join(:left, [candidate, _device], cursor in "proactive_planner_user_cursors",
      on: field(cursor, :user_id) == candidate.user_id
    )
    |> where([candidate, _device, _cursor], candidate.status == "pending")
    |> where([candidate, _device, _cursor], candidate.expires_at > ^now)
    |> group_by(
      [candidate, _device, cursor],
      [candidate.user_id, field(cursor, :last_attempted_at)]
    )
    |> order_by(
      [candidate, _device, cursor],
      asc_nulls_first: field(cursor, :last_attempted_at),
      asc: candidate.user_id
    )
    |> limit(^limit)
    |> select([candidate, _device, _cursor], candidate.user_id)
    |> Repo.all()
  end

  def pending_deliverable_user_ids(_opts), do: []

  @doc """
  Advance a pending user's durable planner watermark after a defer or failed
  attempt so the same user cannot occupy a fixed due-user batch forever.
  Candidate insertion timestamps remain unchanged for evidence-age ranking.
  """
  def rotate_pending_user(user_id, now \\ DateTime.utc_now())

  def rotate_pending_user(user_id, %DateTime{} = now)
      when is_binary(user_id) and byte_size(user_id) <= 1_280 do
    timestamp = DateTime.truncate(now, :microsecond)

    {count, _rows} =
      Repo.insert_all(
        "proactive_planner_user_cursors",
        [
          %{
            user_id: user_id,
            last_attempted_at: timestamp,
            inserted_at: timestamp,
            updated_at: timestamp
          }
        ],
        on_conflict: [set: [last_attempted_at: timestamp, updated_at: timestamp]],
        conflict_target: [:user_id]
      )

    {:ok, count}
  end

  def rotate_pending_user(_user_id, _now), do: {:ok, 0}

  @doc """
  Atomically claims pending rows for one planner invocation.

  Competing workers receive only the rows they changed. The claim uses the
  existing planned lease, so a killed worker is recovered by
  `recover_stale_planned/2`.
  """
  def claim_pending(candidates, now \\ DateTime.utc_now())

  def claim_pending(candidates, now) when is_list(candidates) and is_struct(now, DateTime) do
    ids =
      candidates
      |> Enum.take(12)
      |> Enum.map(fn
        %ProactiveCandidate{id: id} -> id
        id when is_binary(id) and byte_size(id) <= 64 -> id
        _other -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    user_ids =
      ProactiveCandidate
      |> where([candidate], candidate.id in ^ids)
      |> distinct([candidate], candidate.user_id)
      |> limit(2)
      |> select([candidate], candidate.user_id)
      |> Repo.all()

    case user_ids do
      [user_id] -> claim_pending_for_user(user_id, ids, now)
      [] -> {:ok, %{token: nil, ids: MapSet.new()}}
      _multiple_users -> {:error, :mixed_candidate_users}
    end
  end

  def claim_pending(_candidates, _now), do: {:error, :invalid_candidates}

  defp claim_pending_for_user(user_id, ids, now) do
    lease_cutoff = DateTime.add(now, -15 * 60, :second)

    Repo.transaction(fn ->
      _locked_user =
        User
        |> where([user], user.id == ^user_id)
        |> lock("FOR UPDATE")
        |> select([user], user.id)
        |> Repo.one()

      active_claim? =
        ProactiveCandidate
        |> where([candidate], candidate.user_id == ^user_id)
        |> where([candidate], candidate.status == "planned")
        |> where([candidate], like(candidate.plan_reason, "claim:%"))
        |> where([candidate], candidate.planned_at > ^lease_cutoff)
        |> Repo.exists?()

      if active_claim? do
        Repo.rollback(:user_claim_busy)
      else
        token = "claim:" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

        {_count, claimed_ids} =
          ProactiveCandidate
          |> where([candidate], candidate.id in ^ids)
          |> where([candidate], candidate.user_id == ^user_id)
          |> where([candidate], candidate.status == "pending")
          |> where([candidate], candidate.expires_at > ^now)
          |> select([candidate], candidate.id)
          |> Repo.update_all(
            set: [
              status: "planned",
              disposition: nil,
              plan_reason: token,
              planned_at: now,
              updated_at: now
            ]
          )

        %{token: token, ids: MapSet.new(claimed_ids || [])}
      end
    end)
    |> case do
      {:ok, claim} -> {:ok, claim}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def release_claim(token, now \\ DateTime.utc_now())

  def release_claim(token, now) when is_binary(token) do
    {count, _rows} =
      ProactiveCandidate
      |> where([candidate], candidate.status == "planned")
      |> where([candidate], candidate.plan_reason == ^token)
      |> Repo.update_all(
        set: [
          status: "pending",
          disposition: nil,
          plan_reason: nil,
          planned_at: nil,
          delivered_at: nil,
          updated_at: now
        ]
      )

    count
  end

  def release_claim(_token, _now), do: 0

  def finalize_claim(candidate_or_id, token, disposition, now \\ DateTime.utc_now())

  def finalize_claim(candidate_or_id, token, disposition, %DateTime{} = now)
      when is_binary(token) and disposition in ["interrupt_now", "digest", "hold"] do
    id = candidate_id(candidate_or_id)

    {count, _rows} =
      ProactiveCandidate
      |> where([candidate], candidate.id == ^id)
      |> where([candidate], candidate.status == "planned")
      |> where([candidate], candidate.plan_reason == ^token)
      |> where([candidate], candidate.expires_at > ^now)
      |> Repo.update_all(set: [disposition: disposition, planned_at: now, updated_at: now])

    if count == 1, do: {:ok, Repo.get!(ProactiveCandidate, id)}, else: {:error, :claim_lost}
  end

  def finalize_claim(_candidate_or_id, _token, _disposition, _now),
    do: {:error, :invalid_claim}

  def relinquish_claim(candidate_or_id, token, disposition, reason, now \\ DateTime.utc_now())

  def relinquish_claim(candidate_or_id, token, disposition, reason, %DateTime{} = now)
      when is_binary(token) and disposition in ["interrupt_now", "digest", "hold"] do
    id = candidate_id(candidate_or_id)

    {count, _rows} =
      ProactiveCandidate
      |> where([candidate], candidate.id == ^id)
      |> where([candidate], candidate.status == "planned")
      |> where([candidate], candidate.plan_reason == ^token)
      |> where([candidate], candidate.expires_at > ^now)
      |> Repo.update_all(
        set: [
          disposition: disposition,
          plan_reason: bounded_plan_reason(reason),
          planned_at: now,
          updated_at: now
        ]
      )

    if count == 1, do: {:ok, Repo.get!(ProactiveCandidate, id)}, else: {:error, :claim_lost}
  end

  def relinquish_claim(_candidate_or_id, _token, _disposition, _reason, _now),
    do: {:error, :invalid_claim}

  def authorize_dispatch(candidate_or_id, token, now \\ DateTime.utc_now())

  def authorize_dispatch(candidate_or_id, token, %DateTime{} = now) when is_binary(token) do
    id = candidate_id(candidate_or_id)

    {count, _rows} =
      ProactiveCandidate
      |> where([candidate], candidate.id == ^id)
      |> where([candidate], candidate.status == "planned")
      |> where([candidate], candidate.plan_reason == ^token)
      |> where([candidate], candidate.expires_at > ^now)
      # Keep the persisted state backward-compatible with the deployed
      # release. This CAS refreshes the claim lease and proves ownership
      # without introducing a status an older binary cannot recover.
      |> Repo.update_all(set: [planned_at: now, updated_at: now])

    if count == 1, do: {:ok, Repo.get!(ProactiveCandidate, id)}, else: {:error, :claim_lost}
  end

  def authorize_dispatch(_candidate_or_id, _token, _now), do: {:error, :invalid_claim}

  def complete_claim(candidate_or_id, token, status, reason \\ nil, now \\ DateTime.utc_now())

  def complete_claim(candidate_or_id, token, status, reason, %DateTime{} = now)
      when is_binary(token) and status in ["delivered", "held", "pending"] do
    id = candidate_id(candidate_or_id)
    final_status = if status == "pending" and expired_id?(id, now), do: "expired", else: status
    plan_reason = if final_status == "held", do: bounded_plan_reason(reason), else: nil
    delivered_at = if final_status == "delivered", do: now, else: nil

    disposition =
      if final_status in ["pending", "expired"],
        do: nil,
        else: current_disposition(id)

    {count, _rows} =
      ProactiveCandidate
      |> where([candidate], candidate.id == ^id)
      |> where([candidate], candidate.status == "planned")
      |> where([candidate], candidate.plan_reason == ^token)
      |> Repo.update_all(
        set: [
          status: final_status,
          disposition: disposition,
          plan_reason: plan_reason,
          planned_at: nil,
          delivered_at: delivered_at,
          updated_at: now
        ]
      )

    if count == 1, do: {:ok, Repo.get!(ProactiveCandidate, id)}, else: {:error, :claim_lost}
  end

  def complete_claim(_candidate_or_id, _token, _status, _reason, _now),
    do: {:error, :invalid_claim}

  def mark_planned(candidate_or_id, disposition, reason) do
    with %ProactiveCandidate{} = candidate <- get_candidate(candidate_or_id) do
      candidate
      |> ProactiveCandidate.plan_changeset(disposition, reason)
      |> Repo.update()
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Return stale `planned` rows to `pending` after a dispatch-crash lease expires.

  A successful send remains safe to retry because PushBroker's durable receipt
  dedupe converts it to a duplicate suppression and marks the candidate
  delivered. Evidence age (`inserted_at`) is never changed.
  """
  def recover_stale_planned(now \\ DateTime.utc_now(), lease_minutes \\ 15)

  def recover_stale_planned(%DateTime{} = now, lease_minutes)
      when is_integer(lease_minutes) and lease_minutes > 0 do
    cutoff = DateTime.add(now, -lease_minutes * 60, :second)

    {count, _rows} =
      ProactiveCandidate
      |> where([candidate], candidate.status == "planned")
      |> where(
        [candidate],
        candidate.planned_at <= ^cutoff or
          (is_nil(candidate.planned_at) and candidate.updated_at <= ^cutoff)
      )
      |> where([candidate], candidate.expires_at > ^now)
      |> Repo.update_all(
        set: [
          status: "pending",
          disposition: nil,
          plan_reason: nil,
          planned_at: nil,
          updated_at: now
        ]
      )

    {expired_count, _rows} =
      ProactiveCandidate
      |> where([candidate], candidate.status == "planned")
      |> where(
        [candidate],
        candidate.planned_at <= ^cutoff or
          (is_nil(candidate.planned_at) and candidate.updated_at <= ^cutoff)
      )
      |> where([candidate], candidate.expires_at <= ^now)
      |> Repo.update_all(
        set: [
          status: "expired",
          disposition: nil,
          plan_reason: nil,
          planned_at: nil,
          updated_at: now
        ]
      )

    count + expired_count
  end

  def recover_stale_planned(_now, _lease_minutes), do: 0

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
      |> where([candidate], candidate.status in ^@expirable_live_statuses)
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
        candidate_reference: Maraithon.Redaction.fingerprint(row.id),
        failure_code: Maraithon.Redaction.error_class(error)
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

  defp candidate_id(%ProactiveCandidate{id: id}), do: id
  defp candidate_id(id) when is_binary(id), do: id
  defp candidate_id(_value), do: nil

  defp current_disposition(id) do
    case Repo.get(ProactiveCandidate, id) do
      %ProactiveCandidate{disposition: disposition} -> disposition
      _candidate -> nil
    end
  end

  defp expired_id?(id, now) do
    ProactiveCandidate
    |> where([candidate], candidate.id == ^id and candidate.expires_at <= ^now)
    |> Repo.exists?()
  end

  defp bounded_plan_reason(value) when is_binary(value),
    do: Maraithon.PromptBudget.truncate_utf8(value, 2_000)

  defp bounded_plan_reason(_value), do: nil

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

  defp raw_attr(attrs, key) when is_map(attrs) and is_binary(key) do
    case Map.fetch(attrs, key) do
      {:ok, value} ->
        value

      :error ->
        case existing_atom_key(key) do
          nil -> :missing
          atom_key -> Map.get(attrs, atom_key, :missing)
        end
    end
  end

  defp existing_atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp normalize_attrs(attrs) do
    attrs =
      Enum.reduce(@enqueue_attr_keys, %{}, fn key, acc ->
        case raw_attr(attrs, key) do
          :missing -> acc
          value -> Map.put(acc, key, value)
        end
      end)

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

  defp positive_integer(value, _default) when is_integer(value) and value > 0,
    do: min(value, @max_query_limit)

  defp positive_integer(value, default)
       when is_binary(value) and byte_size(value) <= 16 do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> min(parsed, @max_query_limit)
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp normalize_ttl_minutes(value) when is_integer(value) and value > 0, do: value

  defp normalize_ttl_minutes(value) when is_binary(value) and byte_size(value) <= 16 do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_candidate_ttl_minutes
    end
  end

  defp normalize_ttl_minutes(_value), do: @default_candidate_ttl_minutes
end
