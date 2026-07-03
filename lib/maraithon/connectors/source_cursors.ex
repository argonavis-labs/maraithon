defmodule Maraithon.Connectors.SourceCursors do
  @moduledoc """
  Context for durable per-source sync cursors (`Maraithon.Connectors.SourceCursor`).

  Cursors back incremental sync (Gmail `historyId`, Calendar `nextSyncToken`,
  Slack poll watermarks) and push-watch bookkeeping (channel/resource id and
  expiration) used by `Maraithon.Runtime.WatchRenewer`.
  """

  import Ecto.Query

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursor
  alias Maraithon.Repo

  # Poll-watermark kinds are epoch-second strings that a *delta* fetch reads
  # to know "since when" to ask a provider for new items. Post-review
  # belt-and-suspenders guard: a caller racing/misordering writes (or a bug
  # like the non-agent `Acquisition.build` callers advancing these
  # immediately) must never be able to move one of these backwards, since
  # that would make the next delta fetch re-request a window it already
  # covered rather than silently losing coverage — moving forward
  # incorrectly is the dangerous direction, so only guard against rewinding.
  # `gmail_history_id`/sync-token kinds are opaque provider cursors, not
  # comparable integers, and are left untouched.
  @monotonic_watermark_kinds ["gmail_poll_watermark", "slack_watermark"]

  @doc """
  Fetches the cursor for a `(connected_account_id, kind)` pair, or `nil`.
  """
  def get(connected_account_id, kind)

  def get(connected_account_id, kind) when is_integer(connected_account_id) and is_binary(kind) do
    Repo.get_by(SourceCursor, connected_account_id: connected_account_id, kind: kind)
  end

  def get(_connected_account_id, _kind), do: nil

  @doc """
  Upserts the cursor row for `account` (a `%ConnectedAccount{}`) and `kind`.

  Only the fields present in `attrs` are written; existing columns not
  mentioned in `attrs` are left untouched (a plain `on_conflict: :replace_all`
  would otherwise reset them to `nil`). `attrs` keys may be atoms or strings
  and may include `"value"`, `"watch_channel_id"`, `"watch_resource_id"`,
  `"watch_expires_at"`.
  """
  def put(account, kind, attrs \\ %{})

  def put(%ConnectedAccount{} = account, kind, attrs) when is_binary(kind) do
    attrs =
      attrs
      |> normalize_attrs()
      |> guard_monotonic_value(account, kind)

    base = %{
      "user_id" => account.user_id,
      "connected_account_id" => account.id,
      "provider" => account.provider,
      "kind" => kind
    }

    changeset = SourceCursor.changeset(%SourceCursor{}, Map.merge(base, attrs))

    replace_fields =
      attrs
      |> Map.keys()
      |> Enum.map(&String.to_existing_atom/1)
      |> Enum.uniq()
      |> Kernel.++([:updated_at])

    Repo.insert(changeset,
      on_conflict: {:replace, replace_fields},
      conflict_target: [:connected_account_id, :kind],
      returning: true
    )
  end

  @doc """
  Sets `value` only if the cursor does not already have one. Used by watch
  renewal so a fresh watch's `historyId` never rewinds progress already made.
  """
  def ensure_value(%ConnectedAccount{} = account, kind, value) when is_binary(kind) do
    case get(account.id, kind) do
      %SourceCursor{value: existing} when is_binary(existing) and existing != "" ->
        {:ok, :unchanged}

      _ ->
        put(account, kind, %{"value" => value})
    end
  end

  @doc """
  Deletes the cursor row for `(connected_account_id, kind)`, if any.
  """
  def clear(connected_account_id, kind)

  def clear(connected_account_id, kind)
      when is_integer(connected_account_id) and is_binary(kind) do
    Repo.delete_all(
      from(cursor in SourceCursor,
        where: cursor.connected_account_id == ^connected_account_id and cursor.kind == ^kind
      )
    )

    :ok
  end

  def clear(_connected_account_id, _kind), do: :ok

  @doc """
  Cursors whose watch is due for renewal: `watch_expires_at` is set and falls
  within `horizon_seconds` from `now`. Ordered soonest-to-expire first.
  """
  def due_for_renewal(now \\ DateTime.utc_now(), horizon_seconds, limit)
      when is_integer(horizon_seconds) and is_integer(limit) do
    cutoff = DateTime.add(now, horizon_seconds, :second)

    SourceCursor
    |> where([cursor], not is_nil(cursor.watch_expires_at))
    |> where([cursor], cursor.watch_expires_at <= ^cutoff)
    |> order_by([cursor], asc: cursor.watch_expires_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Cursors whose watch has already expired (`watch_expires_at` in the past).

  Used by `Maraithon.Runtime.FreshnessSweep` (SPEC 10 R2) to flag watches
  that `Maraithon.Runtime.WatchRenewer` failed to renew before expiry —
  the sweep flags, `WatchRenewer` renews. Ordered oldest-expired first.
  """
  def expired(now \\ DateTime.utc_now(), limit) when is_integer(limit) do
    SourceCursor
    |> where([cursor], not is_nil(cursor.watch_expires_at))
    |> where([cursor], cursor.watch_expires_at < ^now)
    |> order_by([cursor], asc: cursor.watch_expires_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize_attrs()
  defp normalize_attrs(_attrs), do: %{}

  # Drops a rewinding "value" from `attrs` for the monotonic poll-watermark
  # kinds, leaving the existing column untouched (per `put/3`'s "only fields
  # present in attrs are written" contract). Only guards when both the
  # existing and incoming values parse cleanly as integers; anything else
  # (no existing cursor yet, non-numeric value) falls through to today's
  # unconditional replace.
  defp guard_monotonic_value(%{"value" => new_value} = attrs, %ConnectedAccount{} = account, kind)
       when kind in @monotonic_watermark_kinds and is_binary(new_value) do
    with {new_int, ""} <- Integer.parse(new_value),
         %SourceCursor{value: existing_value} when is_binary(existing_value) <-
           get(account.id, kind),
         {existing_int, ""} <- Integer.parse(existing_value) do
      if new_int < existing_int do
        Map.delete(attrs, "value")
      else
        attrs
      end
    else
      _ -> attrs
    end
  end

  defp guard_monotonic_value(attrs, _account, _kind), do: attrs
end
