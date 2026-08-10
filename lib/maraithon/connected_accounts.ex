defmodule Maraithon.ConnectedAccounts do
  @moduledoc """
  Provider-agnostic connected account read/write context.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.EmailDelivery
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Token
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Repo
  alias Maraithon.SourceLabels
  alias Maraithon.Tools.ToolErrorCopy

  require Logger

  def list_for_user(user_id) when is_binary(user_id) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id)
    |> order_by([account], asc: account.provider)
    |> Repo.all()
  end

  def list_connected_provider(provider) when is_binary(provider) do
    ConnectedAccount
    |> where([account], account.provider == ^provider and account.status == "connected")
    |> order_by([account], asc: account.user_id)
    |> Repo.all()
  end

  def has_any?(user_id) when is_binary(user_id) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id)
    |> Repo.exists?()
  end

  def has_any?(_), do: false

  def get(user_id, provider) when is_binary(user_id) and is_binary(provider) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id and account.provider == ^provider)
    |> latest_account()
  end

  @doc """
  Like `get_connected_by_external_account/2` but ignores account status.

  Inbound provider traffic (e.g. a Telegram webhook message) is proof the
  source is alive even when the account row is currently marked `error` —
  callers use this so a wrongly-flagged account can be found and healed by
  `SourceFreshness.mark_success/3` instead of staying invisible to every
  status-filtered lookup.
  """
  def get_by_external_account_any_status(provider, external_account_id)
      when is_binary(provider) and is_binary(external_account_id) do
    case normalize_destination(external_account_id) do
      nil ->
        nil

      value ->
        find_by_metadata_identifier_any_status(provider, value) ||
          find_by_external_id_any_status(provider, value)
    end
  end

  def get_by_external_account_any_status(_provider, _external_account_id), do: nil

  def get_connected_by_external_account(provider, external_account_id)
      when is_binary(provider) and is_binary(external_account_id) do
    normalized_external_account_id = normalize_destination(external_account_id)

    case normalized_external_account_id do
      nil ->
        nil

      value ->
        if provider == "telegram" do
          find_connected_by_metadata_identifier(provider, value) ||
            find_connected_by_external_id(provider, value)
        else
          find_connected_by_external_id(provider, value) ||
            find_connected_by_metadata_identifier(provider, value)
        end
    end
  end

  def upsert_from_oauth(user_id, provider, token_data)
      when is_binary(user_id) and is_binary(provider) do
    with_writable_user(user_id, fn -> do_upsert_from_oauth(user_id, provider, token_data) end)
  end

  defp do_upsert_from_oauth(user_id, provider, token_data) do
    now = DateTime.utc_now()
    previous_account = get(user_id, provider)

    attrs = %{
      user_id: user_id,
      provider: provider,
      status: "connected",
      access_token: token_data[:access_token] || token_data["access_token"],
      refresh_token: token_data[:refresh_token] || token_data["refresh_token"],
      expires_at: token_data[:expires_at] || token_data["expires_at"],
      scopes: normalize_scopes(token_data[:scopes] || token_data["scopes"]),
      metadata: normalize_metadata(token_data[:metadata] || token_data["metadata"]),
      connected_at: now,
      last_refreshed_at: now,
      external_account_id:
        token_data[:external_account_id] || token_data["external_account_id"] ||
          metadata_external_account_id(token_data[:metadata] || token_data["metadata"])
    }

    result =
      case previous_account do
        nil ->
          %ConnectedAccount{}
          |> ConnectedAccount.changeset(attrs)
          |> Repo.insert()

        account ->
          account
          |> ConnectedAccount.changeset(attrs)
          |> Repo.update()
      end

    case result do
      {:ok, updated_account} = ok ->
        maybe_report_recovery(previous_account, updated_account)
        ok

      error ->
        error
    end
  end

  def upsert_manual(user_id, provider, attrs \\ %{})
      when is_binary(user_id) and is_binary(provider) and is_map(attrs) do
    with_writable_user(user_id, fn -> do_upsert_manual(user_id, provider, attrs) end)
  end

  defp do_upsert_manual(user_id, provider, attrs) do
    now = DateTime.utc_now()

    merged_attrs =
      attrs
      |> Map.take([
        :external_account_id,
        "external_account_id",
        :metadata,
        "metadata",
        :scopes,
        "scopes"
      ])
      |> normalize_attrs()
      |> Map.merge(%{
        user_id: user_id,
        provider: provider,
        status: "connected",
        connected_at: now,
        last_refreshed_at: now
      })

    case get(user_id, provider) do
      nil ->
        %ConnectedAccount{}
        |> ConnectedAccount.changeset(merged_attrs)
        |> Repo.insert()

      account ->
        account
        |> ConnectedAccount.changeset(merged_attrs)
        |> Repo.update()
    end
  end

  def mark_disconnected(user_id, provider) when is_binary(user_id) and is_binary(provider) do
    mark_disconnected(user_id, provider, [])
  end

  def mark_disconnected(user_id, provider, opts)
      when is_binary(user_id) and is_binary(provider) do
    case get(user_id, provider) do
      nil ->
        :ok

      account ->
        result =
          account
          |> ConnectedAccount.changeset(%{
            status: "disconnected",
            access_token: nil,
            refresh_token: nil,
            expires_at: nil,
            last_refreshed_at: DateTime.utc_now()
          })
          |> Repo.update()

        case result do
          {:ok, updated_account} = ok ->
            maybe_send_reconnect_notification(updated_account, "disconnected", opts)
            ok

          error ->
            error
        end
    end
  end

  def mark_error(user_id, provider, reason) when is_binary(user_id) and is_binary(provider) do
    case get(user_id, provider) do
      nil ->
        :ok

      account ->
        now = DateTime.utc_now()
        normalized_reason = normalize_error_reason(reason)

        metadata =
          account.metadata
          |> normalize_metadata()
          |> Map.put("last_error", %{
            "reason" => normalized_reason,
            "at" => DateTime.to_iso8601(now)
          })

        result =
          account
          |> ConnectedAccount.changeset(%{
            status: "error",
            metadata: metadata,
            last_refreshed_at: now
          })
          |> Repo.update()

        case result do
          {:ok, updated_account} = ok ->
            maybe_send_reconnect_notification(updated_account, normalized_reason)
            ok

          error ->
            error
        end
    end
  end

  def report_access_issue(user_id, provider, reason)
      when is_binary(user_id) and is_binary(provider) do
    case normalize_access_issue_reason(reason) do
      nil ->
        :ok

      normalized_reason ->
        case mark_error(user_id, provider, normalized_reason) do
          {:ok, _account} -> :ok
          :ok -> :ok
          _ -> :ok
        end
    end
  end

  def notify_reconnect_required(user_id, provider, reason, opts \\ [])

  def notify_reconnect_required(user_id, provider, reason, opts)
      when is_binary(user_id) and is_binary(provider) and is_list(opts) do
    case normalize_access_issue_reason(reason) do
      nil ->
        :ok

      normalized_reason ->
        case get(user_id, provider) do
          %ConnectedAccount{} = account ->
            maybe_send_reconnect_notification(account, normalized_reason, opts)

          nil ->
            :ok
        end
    end
  end

  def notify_reconnect_required(_user_id, _provider, _reason, _opts), do: :ok

  # Flapping-source damping: a source that fails, recovers, fails, recovers
  # in quick succession (a bad DNS blip, a token that refreshes then dies
  # again) previously sent a full notify+confirm pair on *every* flip,
  # because `mark_success`/`mark_error` clear/re-set the same metadata keys
  # each time and neither side remembered the other happened recently.
  #
  # `recovery_confirmed_at` (stored in the same metadata region as
  # `reconnect_notification`/`reauth_notification`) is the shared damping
  # signal: it is stamped whenever a recovery confirmation is actually sent,
  # and checked before sending either a new failure notification or another
  # recovery confirmation. It is intentionally *not* cleared by
  # `mark_success`'s metadata drop, so it survives across the flap. Once the
  # window elapses without the source actually recovering, everything is
  # re-armed exactly as before.
  @flap_damping_window_minutes 60

  @doc """
  R4: sends a one-time recovery confirmation when `previous_account` was
  broken (`error`/`disconnected`) and had a reconnect notification pending,
  and `updated_account` is now healthy (`connected`). No-ops otherwise.

  Called after any write that represents "this source is working again":
  a successful OAuth token refresh/reconnect (`upsert_from_oauth/3`) or a
  successful sync (`Maraithon.SourceFreshness.mark_success/3`). Both of
  those already clear `reconnect_notification`/`reauth_notification` from
  metadata as part of the same write, so the pending-notification flag is
  read from `previous_account` (the pre-write snapshot) — this also
  re-arms notifications, since the next failure will find no pending
  notification and be free to send again.

  Flap damping: if a recovery confirmation was already sent very recently
  (within `@flap_damping_window_minutes`), this no-ops instead of sending
  another one — see the module note above `@flap_damping_window_minutes`.
  """
  def maybe_report_recovery(previous_account, updated_account)

  def maybe_report_recovery(
        %ConnectedAccount{} = previous_account,
        %ConnectedAccount{
          status: "connected"
        } = updated_account
      ) do
    if recoverable_transition?(previous_account) do
      maybe_send_recovery_confirmation(updated_account)
    end

    :ok
  end

  def maybe_report_recovery(_previous_account, _updated_account), do: :ok

  defp maybe_send_recovery_confirmation(%ConnectedAccount{} = account) do
    if flap_damped?(account) do
      :ok
    else
      send_recovery_notification(account)
      mark_recovery_confirmed(account)
    end
  end

  defp flap_damped?(%ConnectedAccount{metadata: metadata}) do
    metadata
    |> normalize_metadata()
    |> fetch_map_value("recovery_confirmed_at")
    |> recent_within_minutes?(@flap_damping_window_minutes)
  end

  defp recent_within_minutes?(value, minutes) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, confirmed_at, _offset} ->
        DateTime.diff(DateTime.utc_now(), confirmed_at, :minute) < minutes

      _ ->
        false
    end
  end

  defp recent_within_minutes?(_value, _minutes), do: false

  defp mark_recovery_confirmed(%ConnectedAccount{} = account) do
    metadata =
      account.metadata
      |> normalize_metadata()
      |> Map.put("recovery_confirmed_at", DateTime.utc_now() |> DateTime.to_iso8601())

    _ =
      account
      |> ConnectedAccount.changeset(%{metadata: metadata})
      |> Repo.update()

    :ok
  end

  defp recoverable_transition?(%ConnectedAccount{status: status, metadata: metadata})
       when status in ["error", "disconnected"] do
    metadata = normalize_metadata(metadata)

    is_map(fetch_map_value(metadata, "reconnect_notification")) or
      is_map(fetch_map_value(metadata, "reauth_notification"))
  end

  defp recoverable_transition?(_previous_account), do: false

  defp send_recovery_notification(%ConnectedAccount{} = account) do
    message = recovery_message(account)
    email_content = recovery_email(account)

    [
      reconnect_push_channel(account, message, "recovered"),
      reconnect_email_channel(account, email_content)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&send_reconnect_notification_channel(account, &1))

    :ok
  end

  defp recovery_message(%ConnectedAccount{} = account) do
    provider_label = provider_label(account.provider)

    """
    <b>Maraithon connector check</b>
    #{html_escape(provider_label)} is connected again — I'm caught up.
    """
    |> String.trim()
  end

  defp recovery_email(%ConnectedAccount{} = account) do
    provider_label = provider_label(account.provider)

    %{
      subject: "#{provider_label} is connected again",
      text_body: "#{provider_label} is connected again - I'm caught up.",
      html_body: "<p>#{html_escape(provider_label)} is connected again — I'm caught up.</p>"
    }
  end

  def sync_from_oauth_tokens(user_id) when is_binary(user_id) do
    OAuth.list_user_tokens(user_id)
    |> Enum.map(&sync_token/1)
  end

  def sync_from_oauth_tokens(_), do: []

  defp sync_token(%Token{} = token) do
    upsert_from_oauth(token.user_id, token.provider, %{
      access_token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: token.expires_at,
      scopes: token.scopes,
      metadata: token.metadata
    })
  end

  defp with_writable_user(user_id, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      _user = WriteFence.lock_user_writable!(user_id)

      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
        value -> value
      end
    end)
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_scopes(scopes) when is_list(scopes), do: scopes
  defp normalize_scopes(_), do: []

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp normalize_error_reason(reason) when is_binary(reason) do
    ToolErrorCopy.safe_message(reason, "connector_error")
  end

  defp normalize_error_reason(_reason), do: "connector_error"

  defp normalize_access_issue_reason(:reauth_required), do: "oauth_reauth_required"
  defp normalize_access_issue_reason(:no_refresh_token), do: "oauth_missing_refresh_token"
  defp normalize_access_issue_reason(:no_token), do: "oauth_reauth_required"

  # R2: the freshness sweep and watch renewal already did the classifying
  # (a provider-appropriate staleness threshold, or an expired push watch);
  # pass those reasons through unchanged instead of running them back
  # through the generic error-text matcher below.
  defp normalize_access_issue_reason("source_stale"), do: "source_stale"
  defp normalize_access_issue_reason("watch_expired"), do: "watch_expired"

  defp normalize_access_issue_reason({:http_status, status, _body}) when status in [401, 403],
    do: "oauth_reauth_required"

  defp normalize_access_issue_reason({:token_refresh_failed, nested_reason}),
    do: normalize_access_issue_reason(nested_reason)

  defp normalize_access_issue_reason(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    cond do
      String.contains?(normalized, "oauth_reauth_required") ->
        "oauth_reauth_required"

      String.contains?(normalized, "oauth_missing_refresh_token") ->
        "oauth_missing_refresh_token"

      String.contains?(normalized, "invalid_grant") ->
        "oauth_reauth_required"

      String.contains?(normalized, "expired or revoked") ->
        "oauth_reauth_required"

      String.contains?(normalized, "has been revoked") ->
        "oauth_reauth_required"

      String.contains?(normalized, "invalid_refresh_token") ->
        "oauth_reauth_required"

      String.contains?(normalized, "token_revoked") ->
        "oauth_reauth_required"

      true ->
        nil
    end
  end

  defp normalize_access_issue_reason(reason) do
    reason
    |> inspect()
    |> normalize_access_issue_reason()
  end

  defp metadata_external_account_id(metadata) when is_map(metadata) do
    metadata["id"] || metadata[:id] || metadata["github_id"] || metadata[:github_id] ||
      metadata["workspace_id"] || metadata[:workspace_id] ||
      metadata["default_account_id"] || metadata[:default_account_id]
  end

  defp metadata_external_account_id(_), do: nil

  defp find_by_metadata_identifier_any_status(provider, external_account_id) do
    ConnectedAccount
    |> where([account], account.provider == ^provider)
    |> order_by([account], desc: account.updated_at, desc: account.inserted_at, desc: account.id)
    |> Repo.all()
    |> Enum.find(fn account ->
      metadata_identifiers(account.metadata)
      |> Enum.member?(external_account_id)
    end)
  end

  defp find_by_external_id_any_status(provider, external_account_id) do
    ConnectedAccount
    |> where(
      [account],
      account.provider == ^provider and
        account.external_account_id == ^external_account_id
    )
    |> latest_account()
  end

  defp find_connected_by_metadata_identifier(provider, external_account_id)
       when is_binary(provider) and is_binary(external_account_id) do
    ConnectedAccount
    |> where([account], account.provider == ^provider and account.status == "connected")
    |> order_by([account], desc: account.updated_at, desc: account.inserted_at, desc: account.id)
    |> Repo.all()
    |> Enum.find(fn account ->
      metadata_identifiers(account.metadata)
      |> Enum.member?(external_account_id)
    end)
  end

  defp find_connected_by_metadata_identifier(_provider, _external_account_id), do: nil

  defp find_connected_by_external_id(provider, external_account_id)
       when is_binary(provider) and is_binary(external_account_id) do
    ConnectedAccount
    |> where(
      [account],
      account.provider == ^provider and
        account.external_account_id == ^external_account_id and
        account.status == "connected"
    )
    |> latest_account()
  end

  defp find_connected_by_external_id(_provider, _external_account_id), do: nil

  defp latest_account(queryable) do
    queryable
    |> order_by([account], desc: account.updated_at, desc: account.inserted_at, desc: account.id)
    |> limit(1)
    |> Repo.all()
    |> List.first()
  end

  defp metadata_identifiers(metadata) when is_map(metadata) do
    metadata
    |> normalize_metadata()
    |> then(fn value ->
      [
        fetch_map_value(value, "chat_id"),
        fetch_map_value(value, "telegram_user_id"),
        fetch_map_value(value, "id"),
        fetch_map_value(value, "github_id"),
        fetch_map_value(value, "workspace_id"),
        fetch_map_value(value, "default_account_id"),
        fetch_map_value(value, "account_email"),
        fetch_map_value(value, "email")
      ] ++
        metadata_account_ids(value)
    end)
    |> Enum.map(&normalize_destination/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp metadata_identifiers(_metadata), do: []

  defp metadata_account_ids(metadata) when is_map(metadata) do
    metadata
    |> fetch_map_value("accounts")
    |> List.wrap()
    |> Enum.map(fn
      account when is_map(account) -> fetch_map_value(account, "id")
      _ -> nil
    end)
  end

  defp metadata_account_ids(_metadata), do: []

  defp normalize_attrs(attrs) do
    %{
      external_account_id: attrs[:external_account_id] || attrs["external_account_id"],
      metadata: normalize_metadata(attrs[:metadata] || attrs["metadata"]),
      scopes: normalize_scopes(attrs[:scopes] || attrs["scopes"])
    }
  end

  defp maybe_send_reconnect_notification(account, reason, opts \\ [])

  defp maybe_send_reconnect_notification(%ConnectedAccount{} = account, reason, opts)
       when is_binary(reason) do
    cond do
      not (reconnect_notification_enabled?(opts) and reconnect_notification_reason?(reason)) ->
        :ok

      # Flap damping: the source recovered very recently — hold the
      # notification rather than firing immediately. `mark_error` still ran
      # (error state/metadata are already written by the caller); if it's
      # still broken after the window, the next failure notifies normally.
      flap_damped?(account) ->
        :ok

      true ->
        channels =
          account
          |> reconnect_notification_channels(reason)
          |> pending_reconnect_notification_channels(account.metadata, reason)

        send_reconnect_notifications(account, channels, reason)
    end
  end

  defp maybe_send_reconnect_notification(_account, _reason, _opts), do: :ok

  defp reconnect_notification_channels(%ConnectedAccount{} = account, reason) do
    reconnect_url = reconnect_url(account.provider)
    push_message = reconnect_notification_message(account, reconnect_url, reason)
    email_content = reconnect_notification_email(account, reconnect_url, reason)

    [
      reconnect_push_channel(account, push_message, reason),
      reconnect_email_channel(account, email_content)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Telegram is retired: the push channel means the user's phone. The broker
  # resolves registered devices itself, so no destination is needed here.
  defp reconnect_push_channel(%ConnectedAccount{} = account, message, reason) do
    if Maraithon.Push.Notifier.enabled_for_user?(account.user_id) do
      %{
        "channel" => "push",
        "destination" => nil,
        "message" => message,
        "reason" => reason
      }
    end
  end

  defp reconnect_email_channel(%ConnectedAccount{} = account, content) do
    with true <- email_configured?(),
         destination when is_binary(destination) <- email_destination(account.user_id) do
      %{
        "channel" => "email",
        "destination" => destination,
        "content" => content
      }
    else
      _ -> nil
    end
  end

  defp pending_reconnect_notification_channels(channels, _metadata, _reason)
       when not is_list(channels),
       do: []

  defp pending_reconnect_notification_channels([], _metadata, _reason), do: []

  defp pending_reconnect_notification_channels(channels, metadata, reason) do
    notification =
      metadata
      |> normalize_metadata()
      |> then(fn value ->
        fetch_map_value(value, "reconnect_notification") ||
          fetch_map_value(value, "reauth_notification")
      end)

    sent_reason = is_map(notification) && fetch_map_value(notification, "reason")

    if sent_reason == reason do
      now = DateTime.utc_now()
      Enum.reject(channels, &reconnect_channel_sent_recently?(notification, &1["channel"], now))
    else
      channels
    end
  end

  # R3: a still-broken source should not be silenced forever after the
  # first notification - re-notify once `renotify_after_days` has passed
  # since the last send for this same reason, using the existing `sent_at`
  # tracking (no new column needed).
  defp reconnect_channel_sent_recently?(notification, channel, now) when is_map(notification) do
    channels = fetch_map_value(notification, "channels")

    cond do
      is_map(channels) ->
        channel_entry = fetch_map_value(channels, channel)
        sent_at = is_map(channel_entry) && fetch_map_value(channel_entry, "sent_at")
        is_binary(sent_at) and sent_at != "" and sent_recently?(sent_at, now)

      # Legacy rows only prove the old Telegram push path already ran.
      is_binary(fetch_map_value(notification, "sent_at")) ->
        channel == "push" and sent_recently?(fetch_map_value(notification, "sent_at"), now)

      true ->
        false
    end
  end

  defp reconnect_channel_sent_recently?(_notification, _channel, _now), do: false

  defp sent_recently?(sent_at, now) when is_binary(sent_at) do
    case DateTime.from_iso8601(sent_at) do
      {:ok, sent_at_dt, _offset} -> DateTime.diff(now, sent_at_dt, :day) < renotify_after_days()
      _ -> false
    end
  end

  defp sent_recently?(_sent_at, _now), do: false

  @default_renotify_after_days 3

  defp renotify_after_days do
    Application.get_env(:maraithon, :connected_accounts, [])
    |> Keyword.get(:renotify_after_days, @default_renotify_after_days)
    |> case do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_renotify_after_days
    end
  end

  defp send_reconnect_notifications(%ConnectedAccount{} = account, channels, reason)
       when is_list(channels) do
    sent_channels =
      channels
      |> Enum.map(&send_reconnect_notification_channel(account, &1))
      |> Enum.filter(&match?({:ok, _channel}, &1))
      |> Enum.map(fn {:ok, channel} -> channel end)

    if sent_channels == [] do
      :ok
    else
      mark_reconnect_notification_sent(account, sent_channels, reason)
    end
  end

  defp send_reconnect_notifications(_account, _channels, _reason), do: :ok

  # SPEC 02 R9: every system-initiated push rides PushBroker.deliver/1 —
  # quiet-hours gate, PushReceipt audit trail, per-send dedupe — instead of
  # calling the Telegram module directly (which could buzz the operator at
  # 3am and leave no "why did you ping me?" trail).
  #
  # Only a confirmed delivery ("sent_now", or already-delivered-elsewhere:
  # "merged"/"queued_digest"/suppressed-duplicate) returns `{:ok, channel}`
  # and stamps the renotify window. "held_rate_limit" (quiet hours),
  # `{:fallback, :disabled}` (unified broker globally off), and
  # `{:error, :missing_chat_id}` are ordinary could-not-deliver-right-now
  # outcomes: the channel is excluded from sent_channels so the next
  # `FreshnessSweep`-driven `report_access_issue/3` (~hourly) retries
  # naturally once the hold clears — no new retry loop needed.
  defp send_reconnect_notification_channel(
         %ConnectedAccount{} = account,
         %{"channel" => "push", "destination" => destination, "message" => message} = channel
       ) do
    reason = fetch_map_value(channel, "reason") || "reconnect"

    case Maraithon.TelegramAssistant.PushBroker.deliver(%{
           user_id: account.user_id,
           chat_id: destination,
           origin_type: "connector_health",
           origin_id: "#{account.id}:#{reason}",
           dedupe_key: reconnect_push_dedupe_key(account, reason),
           title: "Connector health: #{provider_label(account.provider)}",
           body: message,
           bypass_budget_cap: true,
           interrupt_now: false,
           telegram_opts: [parse_mode: "HTML"]
         }) do
      {:ok, %{decision: "sent_now"}} ->
        {:ok, %{"channel" => "push", "destination" => to_string(destination)}}

      {:ok, %{decision: decision}} when decision in ["merged", "queued_digest"] ->
        {:ok, %{"channel" => "push", "destination" => to_string(destination)}}

      {:ok, %{decision: "suppressed", reason: "duplicate"}} ->
        # Already delivered elsewhere under this dedupe_key.
        {:ok, %{"channel" => "push", "destination" => to_string(destination)}}

      {:ok, %{decision: "held_rate_limit"}} ->
        Logger.info("Reconnect push held by quiet hours/interruption gate",
          user_id: account.user_id,
          provider: account.provider,
          reason: reason
        )

        :ok

      {:fallback, :disabled} ->
        Logger.info("Reconnect push skipped; unified push broker disabled",
          user_id: account.user_id,
          provider: account.provider,
          reason: reason
        )

        :ok

      {:error, :missing_chat_id} ->
        Logger.info("Reconnect push skipped; no Telegram destination",
          user_id: account.user_id,
          provider: account.provider,
          reason: reason
        )

        :ok

      {:error, notification_error} ->
        Logger.warning("Failed to send reconnect push notification",
          user_id: account.user_id,
          provider: account.provider,
          reason: inspect(notification_error)
        )

        :ok

      _other ->
        :ok
    end
  rescue
    notification_error ->
      Logger.warning("Reconnect push notification crashed",
        user_id: account.user_id,
        provider: account.provider,
        reason: Exception.message(notification_error)
      )

      :ok
  end

  defp send_reconnect_notification_channel(
         %ConnectedAccount{} = account,
         %{"channel" => "email", "destination" => destination, "content" => content}
       ) do
    case email_module().send(destination, content) do
      :ok ->
        {:ok, %{"channel" => "email", "destination" => destination}}

      :disabled ->
        :ok

      {:error, notification_error} ->
        Logger.warning("Failed to send reconnect email notification",
          user_id: account.user_id,
          provider: account.provider,
          reason: inspect(notification_error)
        )

        :ok
    end
  rescue
    notification_error ->
      Logger.warning("Reconnect email notification crashed",
        user_id: account.user_id,
        provider: account.provider,
        reason: Exception.message(notification_error)
      )

      :ok
  end

  defp send_reconnect_notification_channel(_account, _channel), do: :ok

  defp reconnect_notification_reason?("oauth_reauth_required"), do: true
  defp reconnect_notification_reason?("oauth_missing_refresh_token"), do: true
  defp reconnect_notification_reason?("disconnected"), do: true
  # R3: broaden beyond hard OAuth failures — a source that's gone quiet
  # (no successful sync/watch for a while) is worth a soft notice too.
  defp reconnect_notification_reason?("source_stale"), do: true
  defp reconnect_notification_reason?("watch_expired"), do: true
  defp reconnect_notification_reason?(_reason), do: false

  @soft_reconnect_reasons ~w(source_stale watch_expired)

  @doc """
  Reasons that mark an account error-status on the sweep's *inference*
  (silence, an expired watch) rather than an observed failure. These are the
  only flags the freshness sweep is allowed to self-heal by active probing.
  """
  def soft_reconnect_reasons, do: @soft_reconnect_reasons

  defp soft_reconnect_reason?(reason), do: reason in @soft_reconnect_reasons

  def telegram_destination(user_id) when is_binary(user_id) do
    case get(user_id, "telegram") do
      %ConnectedAccount{status: "connected"} = account ->
        value =
          account.external_account_id ||
            fetch_map_value(normalize_metadata(account.metadata), "chat_id")

        normalize_destination(value)

      _ ->
        nil
    end
  end

  def telegram_destination(_user_id), do: nil

  # PushBroker's PushReceipt dedupe is a *per-send-attempt* layer (it
  # prevents the same push from double-inserting within one attempt); the
  # account-metadata `reconnect_notification` tracking +
  # `renotify_after_days/0` stays the authoritative "have we nagged about
  # this reason recently" layer. The two must not interfere: a
  # `sent_now` receipt blocks its dedupe_key forever, so any key stable
  # across attempts (account id + reason, even day-scoped) would silently
  # swallow a legitimate renotify or a post-recovery re-arm as a
  # "duplicate". The unique suffix keeps every attempt's receipt (audit
  # trail: "why did you ping me?") without letting receipts second-guess
  # the renotify-window logic.
  defp reconnect_push_dedupe_key(%ConnectedAccount{} = account, reason) do
    "connector_health:#{account.id}:#{reason}:#{Ecto.UUID.generate()}"
  end

  defp email_module do
    Application.get_env(:maraithon, :connected_accounts, [])
    |> Keyword.get(:email_module, EmailDelivery)
  end

  defp email_configured? do
    module = email_module()

    if function_exported?(module, :configured?, 0) do
      module.configured?()
    else
      true
    end
  rescue
    _ -> false
  end

  @doc """
  Public reconnect-management URL for a provider (e.g. `/connectors/google`).

  Exposed for `Maraithon.SourceFreshness.compact_for_prompt/2` (R5) so the
  assistant can hand the user a reconnect link for a broken source without
  duplicating the base-URL/provider-root logic.
  """
  def reconnect_url(provider) when is_binary(provider) do
    base =
      Application.get_env(:maraithon, :connected_accounts, [])
      |> Keyword.get_lazy(:reconnect_base_url, fn -> Maraithon.AppUrl.base_url() end)
      |> to_string()
      |> String.trim_trailing("/")

    root = provider_root(provider)
    path = if root == "", do: "/connectors", else: "/connectors/#{root}"
    if base == "", do: path, else: base <> path
  end

  def reconnect_url(_provider), do: "/connectors"

  defp provider_root(provider) when is_binary(provider) do
    provider
    |> String.split(":", parts: 2)
    |> List.first()
    |> case do
      nil -> ""
      "" -> ""
      value -> value
    end
  end

  defp provider_root(_provider), do: ""

  defp reconnect_notification_enabled?(opts) when is_list(opts) do
    Keyword.get(opts, :notify?, true)
  end

  defp reconnect_notification_enabled?(_opts), do: true

  defp reconnect_notification_message(%ConnectedAccount{} = account, reconnect_url, reason) do
    if soft_reconnect_reason?(reason) do
      soft_notification_message(account, reconnect_url, reason)
    else
      hard_notification_message(account, reconnect_url, reason)
    end
  end

  defp hard_notification_message(%ConnectedAccount{} = account, reconnect_url, reason) do
    provider_label = provider_label(account.provider)
    account_label = account_label(account)
    action_text = reconnect_action_text(reason)

    """
    <b>Maraithon action required</b>
    #{html_escape(provider_label)} account #{html_escape(account_label)} #{html_escape(action_text)}.
    <a href="#{html_escape(reconnect_url)}">Reconnect in Maraithon</a>
    """
    |> String.trim()
  end

  # R3: softer copy for source_stale/watch_expired — the account is not
  # necessarily broken (no OAuth error), it has just gone quiet, so this
  # should read like a gentle heads-up rather than an alarm.
  defp soft_notification_message(%ConnectedAccount{} = account, reconnect_url, reason) do
    provider_label = provider_label(account.provider)
    since_phrase = since_phrase(account)
    quiet_text = quiet_action_text(reason)

    """
    <b>Maraithon connector check</b>
    I haven't seen #{quiet_text} #{html_escape(provider_label)} #{since_phrase} — the connection may need attention.
    <a href="#{html_escape(reconnect_url)}">Check #{html_escape(provider_label)} in Maraithon</a>
    """
    |> String.trim()
  end

  defp reconnect_notification_email(%ConnectedAccount{} = account, reconnect_url, reason) do
    if soft_reconnect_reason?(reason) do
      soft_notification_email(account, reconnect_url, reason)
    else
      hard_notification_email(account, reconnect_url, reason)
    end
  end

  defp hard_notification_email(%ConnectedAccount{} = account, reconnect_url, reason) do
    provider_label = provider_label(account.provider)
    account_label = account_label(account)
    action_text = reconnect_action_text(reason)

    subject = "Reconnect #{provider_label} in Maraithon"

    text_body = """
    Maraithon action required

    #{provider_label} account #{account_label} #{action_text}.
    Reconnect in Maraithon: #{reconnect_url}
    """

    html_body = """
    <p><strong>Maraithon action required</strong></p>
    <p>#{html_escape(provider_label)} account #{html_escape(account_label)} #{html_escape(action_text)}.</p>
    <p><a href="#{html_escape(reconnect_url)}">Reconnect in Maraithon</a></p>
    """

    %{
      subject: subject,
      text_body: String.trim(text_body),
      html_body: String.trim(html_body)
    }
  end

  defp soft_notification_email(%ConnectedAccount{} = account, reconnect_url, reason) do
    provider_label = provider_label(account.provider)
    since_phrase = since_phrase(account)
    quiet_text = quiet_action_text(reason)

    subject = "Check #{provider_label} in Maraithon"

    text_body = """
    Maraithon connector check

    I haven't seen #{quiet_text} #{provider_label} #{since_phrase} - the connection may need attention.
    Check #{provider_label} in Maraithon: #{reconnect_url}
    """

    html_body = """
    <p><strong>Maraithon connector check</strong></p>
    <p>I haven't seen #{quiet_text} #{html_escape(provider_label)} #{since_phrase} — the connection may need attention.</p>
    <p><a href="#{html_escape(reconnect_url)}">Check #{html_escape(provider_label)} in Maraithon</a></p>
    """

    %{
      subject: subject,
      text_body: String.trim(text_body),
      html_body: String.trim(html_body)
    }
  end

  defp reconnect_action_text("disconnected"), do: "was disconnected"
  defp reconnect_action_text(_reason), do: "needs re-authentication"

  defp quiet_action_text("watch_expired"), do: "live updates from"
  defp quiet_action_text(_reason), do: "new activity from"

  # "I haven't seen new Gmail since Tuesday" - falls back to a vaguer
  # phrase when we don't have a last-successful-sync timestamp to anchor to.
  defp since_phrase(%ConnectedAccount{metadata: metadata}) do
    metadata = normalize_metadata(metadata)

    case fetch_map_value(metadata, "last_successful_sync_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> "since #{Calendar.strftime(datetime, "%A")}"
          _ -> "in a while"
        end

      _ ->
        "in a while"
    end
  end

  defp provider_label(provider) when is_binary(provider),
    do: SourceLabels.label(provider, fallback: "Connector")

  defp provider_label(_provider), do: "Connector"

  defp account_label(%ConnectedAccount{} = account) do
    metadata = normalize_metadata(account.metadata)

    normalize_destination(
      fetch_map_value(metadata, "account_email") || fetch_map_value(metadata, "email")
    ) || provider_suffix(account.provider) || provider_label(account.provider)
  end

  defp account_label(_account), do: "account"

  defp provider_suffix(provider) when is_binary(provider) do
    case String.split(provider, ":", parts: 2) do
      [_root, suffix] -> normalize_destination(suffix)
      _ -> nil
    end
  end

  defp provider_suffix(_provider), do: nil

  defp mark_reconnect_notification_sent(%ConnectedAccount{} = account, sent_channels, reason)
       when is_list(sent_channels) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    existing_notification =
      account.metadata |> normalize_metadata() |> fetch_map_value("reconnect_notification")

    existing_channels =
      if is_map(existing_notification),
        do: fetch_map_value(existing_notification, "channels"),
        else: %{}

    existing_channels = if is_map(existing_channels), do: existing_channels, else: %{}

    channel_metadata =
      Map.new(sent_channels, fn channel ->
        channel_name = fetch_map_value(channel, "channel") || "unknown"

        {channel_name,
         %{
           "sent_at" => now,
           "destination" => fetch_map_value(channel, "destination")
         }}
      end)

    destination =
      sent_channels
      |> Enum.find(&(fetch_map_value(&1, "channel") == "push"))
      |> case do
        channel when is_map(channel) -> fetch_map_value(channel, "destination")
        _ -> sent_channels |> List.first() |> fetch_map_value("destination")
      end

    metadata =
      account.metadata
      |> normalize_metadata()
      |> Map.put("reconnect_notification", %{
        "reason" => reason,
        "sent_at" => now,
        "destination" => destination && to_string(destination),
        "channels" => Map.merge(existing_channels, channel_metadata)
      })

    _ =
      account
      |> ConnectedAccount.changeset(%{metadata: metadata})
      |> Repo.update()

    :ok
  end

  defp mark_reconnect_notification_sent(_account, _sent_channels, _reason), do: :ok

  defp email_destination(user_id) when is_binary(user_id) do
    user_id
    |> String.trim()
    |> case do
      "" -> nil
      value -> if String.contains?(value, "@"), do: value
    end
  end

  defp email_destination(_user_id), do: nil

  defp normalize_destination(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      destination -> destination
    end
  end

  defp normalize_destination(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_destination(_value), do: nil

  defp fetch_map_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: value

          _ ->
            nil
        end)
    end
  end

  defp fetch_map_value(_map, _key), do: nil

  defp html_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp html_escape(_value), do: ""
end
