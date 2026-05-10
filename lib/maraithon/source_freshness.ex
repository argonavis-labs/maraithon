defmodule Maraithon.SourceFreshness do
  @moduledoc """
  Computes prompt-safe source freshness snapshots from connected-account state.

  This is intentionally backed by existing account records for the first trust
  release. Connector writes already update `connected_accounts.status`,
  `last_refreshed_at`, and error metadata, so callers get a durable freshness
  view without a second table to keep in sync.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Repo

  @default_stale_after_hours 24
  @provider_stale_after_hours %{
    "telegram" => 24 * 7,
    "github" => 24 * 3,
    "linear" => 24 * 3,
    "notion" => 24 * 3,
    "notaui" => 24 * 3
  }

  def for_user(user_id, opts \\ [])

  def for_user(user_id, opts) when is_binary(user_id) and is_list(opts) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id)
    |> order_by([account], asc: account.provider, asc: account.external_account_id)
    |> Repo.all()
    |> Enum.map(&for_account(&1, opts))
  end

  def for_user(_user_id, _opts), do: []

  def for_provider(user_id, provider, opts \\ [])

  def for_provider(user_id, provider, opts)
      when is_binary(user_id) and is_binary(provider) and is_list(opts) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id and account.provider == ^provider)
    |> order_by([account], desc: account.updated_at, desc: account.inserted_at)
    |> Repo.all()
    |> Enum.map(&for_account(&1, opts))
  end

  def for_provider(_user_id, _provider, _opts), do: []

  def for_account(account, opts \\ [])

  def for_account(%ConnectedAccount{} = account, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    metadata = account.metadata || %{}
    last_error = metadata["last_error"] || %{}
    last_success = last_success_at(account, metadata)
    status = freshness_status(account, last_success, last_error, now)

    %{
      user_id: account.user_id,
      provider: account.provider,
      account_id: account.external_account_id,
      status: status,
      last_successful_sync: last_success && DateTime.to_iso8601(last_success),
      last_webhook: metadata_datetime_iso(metadata, "last_webhook_at"),
      last_full_scan: metadata_datetime_iso(metadata, "last_full_scan_at"),
      last_error: safe_last_error(last_error),
      stale_reason: stale_reason(status, account, last_success, last_error, now),
      updated_at: DateTime.to_iso8601(account.updated_at)
    }
  end

  def for_account(_account, _opts), do: nil

  def compact_for_prompt(user_id, opts \\ []) do
    user_id
    |> for_user(opts)
    |> Enum.map(fn snapshot ->
      %{
        provider: snapshot.provider,
        account_id: snapshot.account_id,
        status: snapshot.status,
        last_successful_sync: snapshot.last_successful_sync,
        stale_reason: snapshot.stale_reason,
        last_error: snapshot.last_error
      }
    end)
  end

  def mark_success(user_id, provider, attrs \\ %{})

  def mark_success(user_id, provider, attrs)
      when is_binary(user_id) and is_binary(provider) and (is_map(attrs) or is_list(attrs)) do
    attrs = Map.new(attrs)

    case latest_account(user_id, provider) do
      %ConnectedAccount{} = account ->
        now = read_datetime(attrs, :at) || DateTime.utc_now()

        metadata =
          (account.metadata || %{})
          |> Map.drop(["last_error"])
          |> put_iso("last_successful_sync_at", now)
          |> maybe_put_iso("last_webhook_at", read_datetime(attrs, :last_webhook_at))
          |> maybe_put_iso("last_full_scan_at", read_datetime(attrs, :last_full_scan_at))

        account
        |> ConnectedAccount.changeset(%{
          status: "connected",
          metadata: metadata,
          last_refreshed_at: now
        })
        |> Repo.update()

      nil ->
        {:error, :connected_account_not_found}
    end
  end

  def mark_success(_user_id, _provider, _attrs), do: {:error, :invalid_source_reference}

  def mark_error(user_id, provider, reason, attrs \\ %{})

  def mark_error(user_id, provider, reason, attrs)
      when is_binary(user_id) and is_binary(provider) and (is_map(attrs) or is_list(attrs)) do
    attrs = Map.new(attrs)

    case latest_account(user_id, provider) do
      %ConnectedAccount{} = account ->
        now = read_datetime(attrs, :at) || DateTime.utc_now()

        metadata =
          (account.metadata || %{})
          |> Map.put("last_error", %{
            "reason" => safe_reason(reason),
            "at" => DateTime.to_iso8601(DateTime.truncate(now, :second))
          })

        account
        |> ConnectedAccount.changeset(%{
          status: error_status(reason),
          metadata: metadata,
          last_refreshed_at: now
        })
        |> Repo.update()

      nil ->
        {:error, :connected_account_not_found}
    end
  end

  def mark_error(_user_id, _provider, _reason, _attrs), do: {:error, :invalid_source_reference}

  def aggregate_status(snapshots) when is_list(snapshots) do
    statuses = Enum.map(snapshots, & &1.status)

    cond do
      statuses == [] -> "unknown"
      "reauth_required" in statuses -> "reauth_required"
      "error" in statuses -> "error"
      "stale" in statuses -> "stale"
      "never_synced" in statuses -> "never_synced"
      Enum.all?(statuses, &(&1 == "fresh")) -> "fresh"
      true -> "unknown"
    end
  end

  def aggregate_status(_snapshots), do: "unknown"

  defp latest_account(user_id, provider) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id and account.provider == ^provider)
    |> order_by([account], desc: account.updated_at, desc: account.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp freshness_status(%{status: "error"}, _last_success, last_error, _now) do
    if reauth_error?(last_error), do: "reauth_required", else: "error"
  end

  defp freshness_status(%{status: "disconnected"}, _last_success, _last_error, _now),
    do: "reauth_required"

  defp freshness_status(%{status: "connected"} = account, nil, _last_error, _now) do
    if account.connected_at, do: "fresh", else: "never_synced"
  end

  defp freshness_status(%{status: "connected"} = account, last_success, _last_error, now) do
    if stale?(account.provider, last_success, now), do: "stale", else: "fresh"
  end

  defp freshness_status(_account, _last_success, _last_error, _now), do: "unknown"

  defp stale?(provider, %DateTime{} = last_success, %DateTime{} = now) do
    DateTime.diff(now, last_success, :hour) > stale_after_hours(provider)
  end

  defp stale?(_provider, _last_success, _now), do: false

  defp stale_after_hours(provider) do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:stale_after_hours, %{})
    |> normalize_stale_config()
    |> Map.get(
      provider,
      Map.get(@provider_stale_after_hours, provider, @default_stale_after_hours)
    )
  end

  defp stale_reason("stale", account, last_success, _last_error, now) do
    hours = if last_success, do: DateTime.diff(now, last_success, :hour), else: nil

    "last successful #{account.provider} sync is #{hours || "unknown"} hours old"
  end

  defp stale_reason("reauth_required", _account, _last_success, last_error, _now) do
    safe_reason(last_error["reason"] || "reauth_required")
  end

  defp stale_reason("error", _account, _last_success, last_error, _now) do
    safe_reason(last_error["reason"] || "connector_error")
  end

  defp stale_reason("never_synced", account, _last_success, _last_error, _now) do
    "#{account.provider} has never synced"
  end

  defp stale_reason(_status, _account, _last_success, _last_error, _now), do: nil

  defp last_success_at(account, metadata) do
    metadata_datetime(metadata, "last_successful_sync_at") ||
      metadata_datetime(metadata, "last_full_scan_at") ||
      account.last_refreshed_at ||
      account.connected_at
  end

  defp metadata_datetime_iso(metadata, key) do
    case metadata_datetime(metadata, key) do
      %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
      nil -> nil
    end
  end

  defp metadata_datetime(metadata, key) when is_map(metadata) do
    metadata
    |> Map.get(key)
    |> parse_datetime()
  end

  defp metadata_datetime(_metadata, _key), do: nil

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp read_datetime(attrs, key) do
    attrs
    |> Map.get(key, Map.get(attrs, Atom.to_string(key)))
    |> parse_datetime()
  end

  defp put_iso(map, key, %DateTime{} = value) do
    Map.put(map, key, DateTime.to_iso8601(DateTime.truncate(value, :second)))
  end

  defp maybe_put_iso(map, _key, nil), do: map
  defp maybe_put_iso(map, key, %DateTime{} = value), do: put_iso(map, key, value)

  defp safe_last_error(%{"reason" => reason, "at" => at}) do
    %{"reason" => safe_reason(reason), "at" => at}
  end

  defp safe_last_error(_last_error), do: nil

  defp safe_reason(reason) when is_binary(reason) do
    reason
    |> Maraithon.Redaction.redact_string()
    |> String.slice(0, 240)
  end

  defp safe_reason(reason), do: reason |> inspect() |> safe_reason()

  defp reauth_error?(%{"reason" => reason}) when is_binary(reason) do
    normalized = String.downcase(reason)
    String.contains?(normalized, "reauth") or String.contains?(normalized, "invalid_grant")
  end

  defp reauth_error?(_last_error), do: false

  defp error_status(_reason), do: "error"

  defp normalize_stale_config(value) when is_map(value) or is_list(value) do
    Map.new(value, fn {key, hours} -> {to_string(key), hours} end)
  rescue
    _ -> %{}
  end

  defp normalize_stale_config(_value), do: %{}
end
