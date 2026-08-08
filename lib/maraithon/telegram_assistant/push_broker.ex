defmodule Maraithon.TelegramAssistant.PushBroker do
  @moduledoc """
  Unified Telegram push broker for insights, briefs, and future agent pushes.
  """

  import Ecto.Query

  alias Maraithon.Accounts.User
  alias Maraithon.BriefingSchedules
  alias Maraithon.Briefs
  alias Maraithon.Briefs.Brief
  alias Maraithon.DeliveryErrorCopy
  alias Maraithon.InsightNotifications.Actions
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Push.Notifier, as: MobilePush
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.TelegramAssistant.PushReceipt

  @default_push_limit_per_hour 3

  # Model-declared interrupt_now can still be forced through the hard
  # send-time budget gate below when it reflects genuine urgency; anything
  # under this threshold is subject to the hourly cap and quiet hours.
  @urgency_exempt_threshold 0.9

  @doc """
  Urgency at or above which an interrupt candidate bypasses quiet hours and
  the hourly cap at send time. Public so the DeliveryPlanner's quiet-hours
  planning deferral uses the same bar as the send-time gate.
  """
  def urgency_exempt_threshold, do: @urgency_exempt_threshold

  def deliver_insight(%Delivery{} = delivery) do
    cond do
      not TelegramAssistant.unified_push_enabled?() ->
        {:fallback, :disabled}

      TelegramAssistant.proactive_delivery_planner_enabled?() ->
        enqueue_insight_candidate(delivery)

      true ->
        deliver_insight_now(delivery)
    end
  end

  defp deliver_insight_now(%Delivery{} = delivery) do
    delivery = Repo.preload(delivery, :insight)
    payload = Actions.telegram_payload(delivery)

    case deliver(%{
           user_id: delivery.user_id,
           chat_id: delivery.destination,
           origin_type: "insight",
           origin_id: delivery.id,
           linked_delivery_id: delivery.id,
           linked_insight_id: delivery.insight_id,
           dedupe_key: "insight_delivery:#{delivery.id}",
           title: delivery.insight && delivery.insight.title,
           body: payload.text,
           urgency: delivery.score || 0.0,
           interrupt_now: true,
           why_now: delivery.insight && delivery.insight.summary,
           telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
         }) do
      {:ok, %{decision: "sent_now", message_id: message_id}} ->
        mark_insight_delivery_sent(delivery, message_id)
        :ok

      {:ok, %{decision: decision}} when decision in ["merged", "queued_digest"] ->
        mark_insight_delivery_delivered_elsewhere(delivery)
        :ok

      {:ok, %{decision: "suppressed", reason: "duplicate"}} ->
        mark_insight_delivery_delivered_elsewhere(delivery)
        :ok

      {:ok, %{decision: "held_rate_limit"}} ->
        # Interruption budget or quiet hours held this insight. The delivery
        # stays "pending" so the periodic Telegram batch retries it once the
        # hold clears instead of it vanishing silently.
        :ok

      {:error, reason} ->
        delivery
        |> Ecto.Changeset.change(%{
          status: "failed",
          error_message: DeliveryErrorCopy.storage_message(reason)
        })
        |> Repo.update()

        {:error, reason}
    end
  end

  @doc """
  Marks an insight `Delivery` "sent" when its content reached the operator
  through another confirmed path (merged into a digest, or suppressed as a
  duplicate of an already-sent push).

  Public because `DeliveryPlanner.maybe_mark_insight_delivery_sent/1` (the
  planner-confirmed-delivery path, SPEC 02 R6) needs the same
  implementation as this module's legacy direct-send path — without it the
  `Delivery` row stays "pending" forever and `InsightNotifier` re-mints a
  fresh `ProactiveCandidate` (and a `plan_delivery` model call) every tick.
  """
  def mark_insight_delivery_delivered_elsewhere(%Delivery{} = delivery) do
    delivery
    |> Ecto.Changeset.change(%{status: "sent", sent_at: delivery.sent_at || DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Marks an insight `Delivery` "sent" with the Telegram message id of the
  push that carried it — the insight-side sibling of `mark_brief_sent/2`
  (SPEC 02 R6).
  """
  def mark_insight_delivery_sent(%Delivery{} = delivery, message_id) do
    message_id = normalize_id(message_id)

    delivery
    |> Ecto.Changeset.change(%{
      status: "sent",
      sent_at: DateTime.utc_now(),
      provider_message_id: message_id,
      metadata: Map.merge(delivery.metadata || %{}, %{"telegram_message_id" => message_id})
    })
    |> Repo.update()
  end

  def deliver_brief(%Brief{} = brief) do
    cond do
      not TelegramAssistant.unified_push_enabled?() ->
        {:fallback, :disabled}

      TelegramAssistant.proactive_delivery_planner_enabled?() ->
        enqueue_brief_candidate(brief)

      true ->
        deliver_brief_now(brief)
    end
  end

  defp deliver_brief_now(%Brief{} = brief) do
    todos = todo_digest_delivery_todos(brief)

    if todos != [] do
      deliver_todo_digest_brief(brief, todos)
    else
      deliver_standard_brief(brief)
    end
  end

  def deliver(candidate) when is_map(candidate) do
    if TelegramAssistant.unified_push_enabled?() do
      candidate = normalize_candidate(candidate)

      case reserve_delivery(candidate) do
        {:ok, {:duplicate, %PushReceipt{decision: "delivery_unknown"}}} ->
          {:error, :delivery_unknown}

        {:ok, {:duplicate, _receipt}} ->
          {:ok, %{decision: "suppressed", reason: "duplicate"}}

        {:ok, {:held, hold_reason}} ->
          {:ok, %{decision: "held_rate_limit", reason: hold_reason}}

        {:ok, {:reserved, receipt}} ->
          send_candidate(candidate, receipt)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:fallback, :disabled}
    end
  end

  defp reserve_delivery(candidate) do
    stale_cutoff = DateTime.add(DateTime.utc_now(), -15 * 60, :second)

    Repo.transaction(fn ->
      _locked_user =
        User
        |> where([user], user.id == ^candidate.user_id)
        |> lock("FOR UPDATE")
        |> select([user], user.id)
        |> Repo.one()

      stale_reservation_ids =
        PushReceipt
        |> where([receipt], receipt.user_id == ^candidate.user_id)
        |> where([receipt], receipt.decision == "reserved")
        |> where([receipt], receipt.inserted_at < ^stale_cutoff)
        |> order_by([receipt], asc: receipt.inserted_at, asc: receipt.id)
        |> limit(100)
        |> select([receipt], receipt.id)
        |> Repo.all()

      if stale_reservation_ids != [] do
        # `reserved` has not crossed the external-send boundary, so an
        # abandoned lease is safe to release.
        PushReceipt
        |> where([receipt], receipt.id in ^stale_reservation_ids)
        |> where([receipt], receipt.decision == "reserved")
        |> where([receipt], receipt.inserted_at < ^stale_cutoff)
        |> Repo.delete_all()
      end

      stale_sending_ids =
        PushReceipt
        |> where([receipt], receipt.user_id == ^candidate.user_id)
        |> where([receipt], receipt.decision == "sending")
        |> where([receipt], receipt.inserted_at < ^stale_cutoff)
        |> order_by([receipt], asc: receipt.inserted_at, asc: receipt.id)
        |> limit(100)
        |> select([receipt], receipt.id)
        |> Repo.all()

      if stale_sending_ids != [] do
        # Once transport starts, a crash or lost APNS response is ambiguous.
        # Fail at-most-once: preserve a durable blocking proof rather than
        # retrying a notification that may already have reached the phone.
        PushReceipt
        |> where([receipt], receipt.id in ^stale_sending_ids)
        |> where([receipt], receipt.decision == "sending")
        |> Repo.update_all(set: [decision: "delivery_unknown"])
      end

      existing =
        Repo.get_by(PushReceipt,
          user_id: candidate.user_id,
          dedupe_key: candidate.dedupe_key
        )

      digest_membership = digest_membership_receipt(candidate)

      cond do
        match?(
          %PushReceipt{decision: decision} when decision in ["reserved", "sending"],
          existing
        ) ->
          Repo.rollback(:delivery_in_progress)

        match?(
          %PushReceipt{decision: decision}
          when decision in ["delivery_unknown", "sent_now", "merged", "queued_digest"],
          existing
        ) ->
          {:duplicate, existing}

        match?(
          %PushReceipt{decision: decision} when decision in ["reserved", "sending"],
          digest_membership
        ) ->
          Repo.rollback(:delivery_in_progress)

        match?(
          %PushReceipt{decision: decision} when decision in ["delivery_unknown", "sent_now"],
          digest_membership
        ) ->
          {:duplicate, digest_membership}

        hold_reason = interruption_hold_reason(candidate) ->
          case TelegramAssistant.record_push_receipt(%{
                 user_id: candidate.user_id,
                 dedupe_key: candidate.dedupe_key,
                 origin_type: candidate.origin_type,
                 origin_id: candidate.origin_id,
                 decision: "held_rate_limit",
                 metadata: candidate.receipt_metadata
               }) do
            {:ok, _receipt} -> {:held, hold_reason}
            {:error, reason} -> Repo.rollback(reason)
          end

        true ->
          case TelegramAssistant.record_push_receipt(%{
                 user_id: candidate.user_id,
                 dedupe_key: candidate.dedupe_key,
                 origin_type: candidate.origin_type,
                 origin_id: candidate.origin_id,
                 decision: "reserved",
                 metadata: candidate.receipt_metadata
               }) do
            {:ok, receipt} -> {:reserved, receipt}
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  # A digest receipt is the transport proof for every child included in that
  # APNs attempt. Match by a stable hash of the child dedupe key so expiry and
  # re-enqueue under a new candidate UUID cannot bypass an ambiguous parent.
  defp digest_membership_receipt(candidate) do
    case PushReceipt.dedupe_hash(candidate.dedupe_key) do
      hash when is_binary(hash) ->
        membership = %{"candidate_dedupe_hashes" => [hash]}

        PushReceipt
        |> where([receipt], receipt.user_id == ^candidate.user_id)
        |> where([receipt], receipt.origin_type == "assistant_digest")
        |> where(
          [receipt],
          receipt.decision in ["reserved", "sending", "delivery_unknown", "sent_now"]
        )
        |> where([receipt], fragment("? @> ?", receipt.metadata, type(^membership, :map)))
        |> order_by([receipt], desc: receipt.inserted_at, desc: receipt.id)
        |> limit(1)
        |> Repo.one()

      _invalid ->
        nil
    end
  end

  defp begin_delivery(%PushReceipt{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {count, _rows} =
      PushReceipt
      |> where([receipt], receipt.id == ^id and receipt.decision == "reserved")
      |> Repo.update_all(set: [decision: "sending", inserted_at: now])

    if count == 1,
      do: {:ok, Repo.get!(PushReceipt, id)},
      else: {:error, :reservation_lost}
  end

  defp finalize_reservation(%PushReceipt{id: id}) do
    {count, _rows} =
      PushReceipt
      |> where([receipt], receipt.id == ^id and receipt.decision == "sending")
      |> Repo.update_all(set: [decision: "sent_now"])

    if count == 1,
      do: {:ok, Repo.get!(PushReceipt, id)},
      else: {:error, :reservation_lost}
  end

  defp mark_delivery_unknown(%PushReceipt{id: id}) do
    PushReceipt
    |> where([receipt], receipt.id == ^id and receipt.decision == "sending")
    |> Repo.update_all(set: [decision: "delivery_unknown"])

    :ok
  end

  defp release_reservation(%PushReceipt{id: id}) do
    PushReceipt
    |> where([receipt], receipt.id == ^id and receipt.decision in ["reserved", "sending"])
    |> Repo.delete_all()

    :ok
  end

  defp release_reservation(_receipt), do: :ok

  def interruption_budget(user_id, opts \\ [])

  def interruption_budget(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit =
      opts
      |> Keyword.get(:limit, push_limit_per_hour())
      |> positive_integer(push_limit_per_hour())

    sent_last_hour = recent_sent_push_count(user_id)

    now =
      case Keyword.fetch(opts, :now) do
        {:ok, %DateTime{} = value} -> value
        _other -> local_now_for_user(user_id)
      end

    %{
      "max_immediate_per_hour" => limit,
      "sent_last_hour" => sent_last_hour,
      "remaining_immediate" => max(limit - sent_last_hour, 0),
      "quiet_hours" => quiet_hours?(now),
      "quiet_hours_start_local" => quiet_hours_start_local(),
      "quiet_hours_end_local" => quiet_hours_end_local()
    }
  end

  def interruption_budget(_user_id, _opts) do
    %{
      "max_immediate_per_hour" => push_limit_per_hour(),
      "sent_last_hour" => 0,
      "remaining_immediate" => push_limit_per_hour(),
      "quiet_hours" => false,
      "quiet_hours_start_local" => quiet_hours_start_local(),
      "quiet_hours_end_local" => quiet_hours_end_local()
    }
  end

  # Telegram is retired: the phone is the only proactive channel. A user
  # without a registered device gets a clean error — the candidate stays
  # pending and the producer's cycle retries once a device registers (briefs
  # additionally reach the inbox by email regardless).
  defp send_candidate(candidate, receipt) do
    if MobilePush.enabled_for_user?(candidate.user_id) do
      send_candidate_mobile(candidate, receipt)
    else
      release_reservation(receipt)
      {:error, :no_push_device}
    end
  end

  defp send_candidate_mobile(candidate, receipt) do
    attrs = %{
      title: candidate.title || push_fallback_title(candidate.origin_type),
      body: push_body(candidate),
      deeplink: push_deeplink(candidate),
      thread_id: candidate.origin_type,
      collapse_id: candidate.dedupe_key
    }

    case MobilePush.prepare(candidate.user_id, attrs) do
      {:ok, prepared} ->
        case begin_delivery(receipt) do
          {:ok, sending_receipt} ->
            finish_mobile_delivery(
              MobilePush.deliver_prepared(prepared, log_failures?: false),
              sending_receipt
            )

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :no_devices} ->
        release_reservation(receipt)
        {:error, :no_push_device}

      {:error, reason} ->
        # Preparation failed before crossing the external-send boundary.
        release_reservation(receipt)
        {:error, reason}
    end
  end

  defp finish_mobile_delivery({:ok, _delivered}, sending_receipt) do
    case finalize_reservation(sending_receipt) do
      {:ok, _receipt} ->
        {:ok, %{decision: "sent_now", message_id: nil, turn_id: nil, conversation_id: nil}}

      {:error, reason} ->
        # The durable row remains `sending`. Stale recovery converts it to a
        # blocking `delivery_unknown` proof, preventing a duplicate after APNS
        # accepted the notification but finalization failed.
        {:error, reason}
    end
  end

  defp finish_mobile_delivery({:error, :no_devices}, sending_receipt) do
    # Every prepared device was definitively rejected as unregistered.
    release_reservation(sending_receipt)
    {:error, :no_push_device}
  end

  defp finish_mobile_delivery({:error, :delivery_unknown} = error, sending_receipt) do
    # Response loss after crossing the transport boundary is ambiguous.
    # Preserve an at-most-once proof rather than retrying it.
    mark_delivery_unknown(sending_receipt)
    error
  end

  defp finish_mobile_delivery({:error, reason}, sending_receipt) do
    # APNS returned a definitive rejection, so no device accepted this attempt
    # and the durable reservation is safe to release/retry.
    release_reservation(sending_receipt)
    {:error, reason}
  end

  # A brief's full rendered text belongs on the Today tab, not in a lock
  # screen banner — the push is the doorbell, the app is the content. Use
  # the summary (why_now) when the candidate has one; everything else sends
  # its (short) body.
  defp push_body(%{origin_type: "brief", why_now: why_now}) when is_binary(why_now) do
    push_plain_text(why_now)
  end

  defp push_body(candidate), do: push_plain_text(candidate.body)

  # Push bodies are plain text; candidate bodies arrive HTML-converted for
  # the Telegram wire. Strip tags and unescape the few entities Telegram's
  # HTML mode uses.
  defp push_plain_text(body) when is_binary(body) do
    body
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.trim()
  end

  defp push_plain_text(_body), do: ""

  defp push_fallback_title("brief"), do: "Your briefing is ready"
  defp push_fallback_title("insight"), do: "New insight"
  defp push_fallback_title("nudge"), do: "Worth a look"
  defp push_fallback_title(_origin_type), do: "Maraithon"

  # Deep links route notification taps to the surface that renders the
  # content natively — the phone shows the real thing, not a text dump.
  defp push_deeplink(%{origin_type: "brief"}), do: "maraithon://today"
  defp push_deeplink(%{origin_type: "insight"}), do: "maraithon://stream"
  defp push_deeplink(%{origin_type: "nudge"}), do: "maraithon://people"

  defp push_deeplink(%{structured_data: %{"message_class" => "todo_digest"}}),
    do: "maraithon://todos"

  defp push_deeplink(%{origin_type: "assistant_digest"}), do: "maraithon://todos"
  defp push_deeplink(_candidate), do: "maraithon://today"

  defp normalize_candidate(candidate) do
    %{
      user_id: Map.get(candidate, :user_id) || candidate["user_id"],
      chat_id: normalize_id(Map.get(candidate, :chat_id) || candidate["chat_id"]),
      origin_type: Map.get(candidate, :origin_type) || candidate["origin_type"] || "agent_push",
      origin_id: Map.get(candidate, :origin_id) || candidate["origin_id"],
      linked_delivery_id:
        Map.get(candidate, :linked_delivery_id) || candidate["linked_delivery_id"],
      linked_insight_id: Map.get(candidate, :linked_insight_id) || candidate["linked_insight_id"],
      title: Map.get(candidate, :title) || candidate["title"],
      body: Map.get(candidate, :body) || candidate["body"] || "",
      urgency: normalize_urgency(Map.get(candidate, :urgency) || candidate["urgency"]),
      interrupt_now: truthy?(Map.get(candidate, :interrupt_now) || candidate["interrupt_now"]),
      bypass_budget_cap:
        truthy?(Map.get(candidate, :bypass_budget_cap) || candidate["bypass_budget_cap"]),
      digest: truthy?(Map.get(candidate, :digest) || candidate["digest"]),
      why_now: Map.get(candidate, :why_now) || candidate["why_now"],
      structured_data:
        Map.get(candidate, :structured_data) || candidate["structured_data"] || %{},
      conversation_metadata:
        Map.get(candidate, :conversation_metadata) || candidate["conversation_metadata"] || %{},
      receipt_metadata:
        Map.get(candidate, :receipt_metadata) || candidate["receipt_metadata"] || %{},
      dedupe_key:
        Map.get(candidate, :dedupe_key) || candidate["dedupe_key"] ||
          "telegram_push:#{Map.get(candidate, :origin_type) || candidate["origin_type"]}:#{Map.get(candidate, :origin_id) || candidate["origin_id"]}",
      telegram_opts: Map.get(candidate, :telegram_opts) || candidate["telegram_opts"] || []
    }
  end

  # Hard budget gate at send time. The model's own `interrupt_now` decision
  # is respected upstream, but it no longer bypasses enforcement here: only
  # genuinely high-urgency *interrupt* items (>= @urgency_exempt_threshold)
  # skip the hourly cap and quiet hours. Digest bundles never take this
  # exemption, even though their urgency is set to the max of the bundled
  # candidates for display/telemetry purposes: an urgency >= 0.9 item the
  # model chose to DIGEST was judged not interrupt-worthy, so it must ride
  # the digest through quiet hours rather than un-gate the whole batch.
  # Digest bundles opt out of the hourly cap via `bypass_budget_cap` (that is
  # precisely the overflow valve for the cap) but still respect quiet hours.
  defp interruption_hold_reason(candidate) do
    cond do
      not candidate.digest and candidate.urgency >= @urgency_exempt_threshold ->
        nil

      quiet_hours?(local_now_for_user(candidate.user_id)) ->
        "quiet_hours"

      candidate.bypass_budget_cap ->
        nil

      recent_sent_push_count(candidate.user_id) >= push_limit_per_hour() ->
        "budget_exhausted"

      true ->
        nil
    end
  end

  @doc """
  The operator's local wall-clock time, used both to enforce the quiet-hours
  send-time gate here and (via `DeliveryPlanner.now_from_context/2`) as the
  fallback source for the advisory budget shown to the planning model, so
  the two never disagree about "now".
  """
  def local_now_for_user(user_id) when is_binary(user_id) do
    offset_hours =
      user_id
      |> BriefingSchedules.summarize_for_prompt()
      |> Map.get(:timezone_offset_hours, -5)

    DateTime.add(DateTime.utc_now(), offset_hours, :hour)
  end

  def local_now_for_user(_user_id), do: DateTime.utc_now()

  @doc """
  True while the user's local wall clock is inside the quiet-hours window.
  Used by the stuck-state watchdog to tell "gated until morning" apart from
  "stuck" when judging pending briefs.
  """
  def quiet_hours_now_for_user?(user_id) do
    quiet_hours?(local_now_for_user(user_id))
  end

  defp quiet_hours?(%DateTime{} = now) do
    local_hour = now.hour
    start_hour = quiet_hours_start_local()
    end_hour = quiet_hours_end_local()

    if start_hour < end_hour do
      local_hour >= start_hour and local_hour < end_hour
    else
      local_hour >= start_hour or local_hour < end_hour
    end
  end

  defp quiet_hours?(_now), do: false

  defp recent_sent_push_count(user_id) when is_binary(user_id) do
    threshold = DateTime.add(DateTime.utc_now(), -3600, :second)

    Maraithon.TelegramAssistant.PushReceipt
    |> where(
      [receipt],
      receipt.user_id == ^user_id and
        receipt.decision in ["reserved", "sending", "delivery_unknown", "sent_now"]
    )
    |> where([receipt], receipt.inserted_at >= ^threshold)
    |> select([receipt], count(receipt.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp recent_sent_push_count(_user_id), do: 0

  defp push_limit_per_hour do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:max_immediate_pushes_per_hour, @default_push_limit_per_hour)
    |> positive_integer(@default_push_limit_per_hour)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) and byte_size(value) <= 16 do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp quiet_hours_start_local do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:quiet_hours_start_local, 22)
    |> normalize_hour(22)
  end

  defp quiet_hours_end_local do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:quiet_hours_end_local, 7)
    |> normalize_hour(7)
  end

  defp normalize_hour(value, _default) when is_integer(value) and value >= 0 and value <= 23,
    do: value

  defp normalize_hour(value, default) when is_binary(value) and byte_size(value) <= 16 do
    if String.valid?(value) do
      case Integer.parse(String.trim(value)) do
        {parsed, ""} when parsed >= 0 and parsed <= 23 -> parsed
        _other -> default
      end
    else
      default
    end
  end

  defp normalize_hour(_value, default), do: default

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_value), do: false

  defp normalize_urgency(value) when is_float(value), do: min(max(value, 0.0), 1.0)
  defp normalize_urgency(value) when is_integer(value), do: normalize_urgency(value / 1)
  defp normalize_urgency(_value), do: 0.0

  defp normalize_id(nil), do: nil
  defp normalize_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value), do: to_string(value)

  defp brief_structured_data(%Brief{
         metadata: %{"travel_itinerary_id" => itinerary_id} = metadata
       })
       when is_binary(itinerary_id) do
    %{
      "brief_type" => metadata["brief_type"] || "travel_prep",
      "travel_itinerary_id" => itinerary_id
    }
  end

  defp brief_structured_data(%Brief{metadata: metadata}) when is_map(metadata) do
    %{}
    |> maybe_put("brief_type", metadata["brief_type"])
    |> maybe_put("linked_project", normalize_linked_project(metadata["linked_project"]))
  end

  defp brief_structured_data(_brief), do: %{}

  defp brief_conversation_metadata(%Brief{metadata: %{"travel_itinerary_id" => itinerary_id}})
       when is_binary(itinerary_id) do
    %{"travel_itinerary_id" => itinerary_id}
  end

  defp brief_conversation_metadata(_brief), do: %{}

  defp normalize_linked_project(%{} = project) do
    %{
      "id" => project["id"] || project[:id],
      "name" => project["name"] || project[:name],
      "slug" => project["slug"] || project[:slug],
      "summary" => project["summary"] || project[:summary]
    }
  end

  defp normalize_linked_project(_project), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp enqueue_insight_candidate(%Delivery{} = delivery) do
    delivery = Repo.preload(delivery, :insight)
    payload = Actions.telegram_payload(delivery)

    TelegramAssistant.enqueue_proactive_candidate(%{
      user_id: delivery.user_id,
      source: "insight",
      source_id: delivery.id,
      dedupe_key: "insight_delivery:#{delivery.id}",
      title: delivery.insight && delivery.insight.title,
      body: payload.text,
      urgency: delivery.score || 0.0,
      why_now: delivery.insight && delivery.insight.summary,
      structured_data: %{
        "linked_delivery_id" => delivery.id,
        "linked_insight_id" => delivery.insight_id,
        "message_class" => "insight"
      },
      telegram_opts:
        compact_map(%{"parse_mode" => "HTML", "reply_markup" => payload.reply_markup})
    })
    |> case do
      {:ok, _candidate} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # :queued, not :ok — the brief has been handed to the DeliveryPlanner as a
  # candidate but nothing reached the user yet. Briefs.send_brief/1 counts
  # this as skipped so the notifier's "sent" tally (and its per-tick log
  # line) only reflects actual deliveries.
  defp enqueue_brief_candidate(%Brief{} = brief) do
    todos = todo_digest_delivery_todos(brief)

    attrs =
      if todos == [],
        do: standard_brief_candidate(brief),
        else: todo_digest_candidate(brief, todos)

    TelegramAssistant.enqueue_proactive_candidate(attrs)
    |> case do
      {:ok, _candidate} -> :queued
      {:error, reason} -> {:error, reason}
    end
  end

  defp todo_digest_delivery_todos(%Brief{cadence: cadence} = brief)
       when cadence in ["check_in", "end_of_day"],
       do: Briefs.todo_digest_todos(brief)

  defp todo_digest_delivery_todos(%Brief{}), do: []

  # SPEC 09 R18: candidate bodies carry the FULL rendered brief (clamped only
  # to the proactive_candidates.body ceiling); Telegram wire-size chunking
  # happens at send time in send_candidate/1. reply_markup still comes from
  # the (capped) payload function — markup construction doesn't depend on
  # text length.
  defp standard_brief_candidate(%Brief{} = brief) do
    payload = Briefs.telegram_payload(brief)

    %{
      user_id: brief.user_id,
      source: "brief",
      source_id: brief.id,
      dedupe_key: "brief:#{brief.id}",
      title: Briefs.public_title(brief),
      body: Briefs.telegram_full_text(brief),
      urgency: 0.7,
      why_now: Briefs.public_summary(brief),
      structured_data: brief_structured_data(brief),
      telegram_opts:
        compact_map(%{"parse_mode" => "HTML", "reply_markup" => payload.reply_markup})
    }
  end

  defp todo_digest_candidate(%Brief{} = brief, todos) when is_list(todos) do
    payload = Briefs.todo_digest_telegram_payload(brief, todos)

    %{
      user_id: brief.user_id,
      source: "brief",
      source_id: brief.id,
      dedupe_key: "brief:#{brief.id}",
      title: Briefs.public_title(brief),
      body: Briefs.todo_digest_full_text(brief, todos),
      urgency: 0.7,
      why_now: Briefs.public_summary(brief),
      structured_data:
        brief_structured_data(brief)
        |> Map.put("message_class", "todo_digest")
        |> Map.put("todo_ids", Enum.map(todos, & &1.id))
        |> Map.put("todo_count", length(todos))
        |> Map.put("brief_cadence", brief.cadence),
      telegram_opts:
        compact_map(%{"parse_mode" => "HTML", "reply_markup" => payload.reply_markup})
    }
  end

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp deliver_standard_brief(%Brief{} = brief) do
    payload = Briefs.telegram_payload(brief)

    case deliver(%{
           user_id: brief.user_id,
           chat_id: nil,
           origin_type: "brief",
           origin_id: brief.id,
           dedupe_key: "brief:#{brief.id}",
           title: Briefs.public_title(brief),
           body: Briefs.telegram_full_text(brief),
           urgency: 0.7,
           interrupt_now: true,
           why_now: Briefs.public_summary(brief),
           structured_data: brief_structured_data(brief),
           conversation_metadata: brief_conversation_metadata(brief),
           telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
         }) do
      {:ok, %{decision: "sent_now", message_id: message_id}} ->
        mark_brief_sent(brief, message_id)
        :ok

      {:ok, %{decision: decision}} when decision in ["merged", "queued_digest"] ->
        mark_brief_delivered_elsewhere(brief)
        :ok

      {:ok, %{decision: "suppressed", reason: "duplicate"}} ->
        mark_brief_delivered_elsewhere(brief)
        :ok

      {:ok, %{decision: "held_rate_limit"}} ->
        # Quiet hours or the interruption budget held this brief. Leave it
        # "pending" so Briefs.dispatch_pending_batch retries it instead of
        # it silently vanishing.
        :ok

      {:error, :no_push_device} ->
        # No registered phone yet: not a failure, just not deliverable — the
        # brief stays pending until a device registers or the sweep expires
        # it (email already carried morning briefs regardless).
        {:error, :no_push_device}

      {:error, reason} ->
        mark_brief_failed(brief, reason)
        {:error, reason}
    end
  end

  defp deliver_todo_digest_brief(%Brief{} = brief, todos) when is_list(todos) do
    if todos == [] do
      deliver_standard_brief(brief)
    else
      payload = Briefs.todo_digest_telegram_payload(brief, todos)

      case deliver(%{
             user_id: brief.user_id,
             chat_id: nil,
             origin_type: "brief",
             origin_id: brief.id,
             dedupe_key: "brief:#{brief.id}",
             title: Briefs.public_title(brief),
             body: Briefs.todo_digest_full_text(brief, todos),
             urgency: 0.7,
             interrupt_now: true,
             why_now: Briefs.public_summary(brief),
             structured_data:
               brief_structured_data(brief)
               |> Map.put("message_class", "todo_digest")
               |> Map.put("todo_ids", Enum.map(todos, & &1.id))
               |> Map.put("todo_count", length(todos)),
             conversation_metadata:
               brief_conversation_metadata(brief)
               |> Map.put("brief_cadence", brief.cadence),
             telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
           }) do
        {:ok, %{decision: "sent_now", message_id: message_id}} ->
          mark_brief_sent(brief, message_id)
          :ok

        {:ok, %{decision: decision}} when decision in ["merged", "queued_digest"] ->
          mark_brief_delivered_elsewhere(brief)
          :ok

        {:ok, %{decision: "suppressed", reason: "duplicate"}} ->
          mark_brief_delivered_elsewhere(brief)
          :ok

        {:ok, %{decision: "held_rate_limit"}} ->
          :ok

        {:error, :no_push_device} ->
          {:error, :no_push_device}

        {:error, reason} ->
          mark_brief_failed(brief, reason)
          {:error, reason}
      end
    end
  end

  defp mark_brief_delivered_elsewhere(%Brief{} = brief) do
    result =
      brief
      |> Ecto.Changeset.change(%{status: "sent", sent_at: brief.sent_at || DateTime.utc_now()})
      |> Repo.update()

    mark_held_interruptions_delivered(brief)
    note_travel_brief_delivered(brief)
    result
  end

  defp mark_brief_sent(%Brief{} = brief, message_id) do
    result =
      brief
      |> Ecto.Changeset.change(%{
        status: "sent",
        sent_at: DateTime.utc_now(),
        provider_message_id: normalize_id(message_id),
        error_message: nil
      })
      |> Repo.update()

    mark_held_interruptions_delivered(brief)
    note_travel_brief_delivered(brief)
    result
  end

  # Travel itineraries advance to "brief_sent" only once the brief is
  # confirmed delivered — this used to (incorrectly) fire when the planner
  # merely enqueued the brief's candidate.
  @doc false
  def note_travel_brief_delivered(%Brief{} = brief) do
    _ = Maraithon.Travel.note_brief_delivered(brief)
    :ok
  rescue
    _error -> :ok
  end

  defp mark_brief_failed(%Brief{} = brief, reason) do
    brief
    |> Ecto.Changeset.change(%{
      status: "failed",
      error_message: DeliveryErrorCopy.storage_message(reason)
    })
    |> Repo.update()
  end

  # SPEC 08 R2 finding 1: MorningBriefing.held_interruptions_for_prompt/1
  # folds held ProactiveCandidates into the brief prompt and stashes their
  # ids in brief.metadata["held_interruption_ids"], but deliberately does
  # NOT flip their status — that's irreversible. Only once the brief is
  # confirmed delivered (sent_now, or merged/queued_digest/suppressed
  # duplicate) do we flip them to "delivered". A generation error, a
  # held/failed brief, or a Brief.record insert failure leaves them "held"
  # for the next brief to re-fetch via ProactiveQueue.list_held_for_user/2
  # instead of losing them forever.
  #
  # Public because both the legacy direct-send path in this module
  # (`mark_brief_sent/2`, `mark_brief_delivered_elsewhere/1` above) and the
  # DeliveryPlanner-confirmed-delivery path (`maybe_mark_brief_delivered/1`
  # in DeliveryPlanner) need to share this one implementation rather than
  # duplicating the fold-in-cleanup logic.
  def mark_held_interruptions_delivered(%Brief{metadata: metadata}) do
    metadata
    |> Kernel.||(%{})
    |> Map.get("held_interruption_ids", [])
    |> List.wrap()
    |> Enum.each(fn
      id when is_binary(id) -> ProactiveQueue.mark_resolvable_held_delivered(id)
      _other -> :ok
    end)
  end
end
