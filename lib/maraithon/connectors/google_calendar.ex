defmodule Maraithon.Connectors.GoogleCalendar do
  @moduledoc """
  Google Calendar connector.

  Sets up push notifications for calendar changes and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `calendar:{user_id}`

  Example: `calendar:user_123`

  ## Event Types

  - `calendar_event_created` - New event created
  - `calendar_event_updated` - Event modified
  - `calendar_event_deleted` - Event removed
  - `calendar_sync` - Full or incremental sync completed

  ## How it Works

  1. User authorizes via OAuth
  2. We call Google Calendar API to create a "watch" on their calendar
  3. Google sends push notifications to our webhook when changes occur
  4. We fetch the changed events and publish to PubSub

  ## Configuration

  Requires `GOOGLE_CALENDAR_WEBHOOK_URL` environment variable for push notification address.
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Connectors.Connector
  alias Maraithon.Runtime.BackgroundJobs

  require Logger

  @default_api_base "https://www.googleapis.com/calendar/v3"
  @sync_token_cursor_kind "calendar_sync_token"
  # Safety cap on how many `events.list` pages we'll follow for a single sync
  # before giving up. Google only returns `nextSyncToken` on the FINAL page,
  # so stopping early (like the old single-request implementation did) means
  # `nextSyncToken` is always nil on multi-page results and the next sync
  # re-fetches the same first page forever. This cap exists only to bound a
  # pathological/looping response.
  @max_sync_pages 25

  # ===========================================================================
  # Watch Management
  # ===========================================================================

  @doc """
  Sets up a watch on the user's primary calendar.

  This registers a push notification channel with Google.
  Google will send POST requests to our webhook when events change.

  Returns `{:ok, watch_info}` or `{:error, reason}`.
  """
  def setup_watch(user_id, access_token \\ nil) do
    with {:ok, token} <- get_access_token(user_id, access_token),
         {:ok, watch} <- create_watch(user_id, token) do
      Logger.info("Google Calendar watch created",
        user_id: user_id,
        channel_id: watch.id,
        expiration: watch.expiration
      )

      {:ok, watch}
    end
  end

  @doc """
  Stops a calendar watch.

  Should be called when a user disconnects their calendar.
  """
  def stop_watch(user_id, channel_id, resource_id) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        url = "#{api_base_url()}/channels/stop"

        body = %{
          id: channel_id,
          resourceId: resource_id
        }

        case Google.api_request(:post, url, token, body) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Webhook Handling
  # ===========================================================================

  @impl true
  def verify_signature(_conn, _raw_body) do
    # Google Calendar push notifications use channel tokens for verification
    # We verify the X-Goog-Channel-Token header in handle_webhook
    :ok
  end

  @impl true
  def handle_webhook(conn, _params) do
    # Extract headers
    channel_id = get_header(conn, "x-goog-channel-id")
    resource_id = get_header(conn, "x-goog-resource-id")
    resource_state = get_header(conn, "x-goog-resource-state")
    channel_token = get_header(conn, "x-goog-channel-token")
    message_number = get_header(conn, "x-goog-message-number")

    # Channel token contains user_id
    user_id = channel_token

    if is_nil(user_id) or user_id == "" do
      {:error, :missing_channel_token}
    else
      topic = "calendar:#{user_id}"

      case resource_state do
        "sync" ->
          # Initial sync confirmation - acknowledge but don't publish
          {:ignore, "sync confirmation"}

        "exists" ->
          # Calendar changed - enqueue a durable background job so the
          # webhook request never makes an outbound Google API call. The
          # actual event fetch happens in `Maraithon.Runtime.BackgroundJobHandler`.
          dedupe_key = "calendar_webhook:#{channel_id}:#{resource_id}:#{message_number}"

          case BackgroundJobs.enqueue("calendar_incremental_sync", %{
                 "user_id" => user_id,
                 "queue" => "connectors",
                 "payload" => %{"channel_id" => channel_id, "resource_id" => resource_id},
                 "dedupe_key" => dedupe_key
               }) do
            {:ok, _job} ->
              event =
                Connector.build_event("calendar_webhook_enqueued", "google_calendar", %{
                  user_id: user_id,
                  channel_id: channel_id,
                  resource_id: resource_id
                })

              {:ok, topic, event}

            {:error, reason} ->
              Logger.warning("Failed to enqueue Calendar incremental sync",
                user_id: user_id,
                reason: inspect(reason)
              )

              {:error, reason}
          end

        "not_exists" ->
          # Resource deleted
          event =
            Connector.build_event("calendar_deleted", "google_calendar", %{
              user_id: user_id,
              channel_id: channel_id,
              resource_id: resource_id
            })

          {:ok, topic, event}

        _ ->
          {:ignore, "unknown resource state: #{resource_state}"}
      end
    end
  end

  # ===========================================================================
  # Calendar API
  # ===========================================================================

  @doc """
  Fetches calendar events, using incremental sync if a sync token is available.

  Returns `{:ok, events}` or `{:error, reason}`.
  """
  def sync_calendar_events(user_id, opts \\ []) do
    case sync_calendar_events_with_token(user_id, opts) do
      {:ok, events, _next_sync_token} -> {:ok, events}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Same as `sync_calendar_events/2`, but also returns the response's
  `nextSyncToken` so the caller can persist it as a cursor. Used by the
  `calendar_incremental_sync` background job.

  Returns `{:ok, events, next_sync_token}` or `{:error, reason}`. On a 410
  (expired sync token), `fetch_events/2` already falls back to one full
  window fetch internally, so the token returned here is always the fresh
  one to store.
  """
  def sync_calendar_events_with_token(user_id, opts \\ []) do
    provider = Keyword.get(opts, :provider, "google")

    case OAuth.get_valid_access_token(user_id, provider) do
      {:ok, token} ->
        case fetch_events(token, opts) do
          {:ok, events, next_sync_token} ->
            ingest_events(user_id, events)
            {:ok, events, next_sync_token}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cursor-aware incremental sync used by the `calendar_incremental_sync`
  background job. Reads the stored `calendar_sync_token` cursor for
  `account`, fetches events (a full window fetch when no cursor exists yet),
  ingests them, and persists the fresh `nextSyncToken`.

  On a 410 (expired sync token), the stored token is cleared *before* the
  recovery full-window fetch runs. If that fetch is nil (e.g. an empty
  window, or the fresh token isn't obtained until the final page of a
  multi-page result) the expired token is never left behind to cause a
  perpetual 410 loop on the next sync.
  """
  def sync_history(user_id, account, opts \\ []) do
    provider = Keyword.get(opts, :provider, account.provider)
    cursor = SourceCursors.get(account.id, @sync_token_cursor_kind)

    fetch_opts =
      case cursor do
        %{value: value} when is_binary(value) and value != "" ->
          Keyword.put(opts, :sync_token, value)

        _ ->
          opts
      end

    fetch_opts =
      Keyword.put(fetch_opts, :on_sync_token_reset, fn -> clear_sync_token(account) end)

    case sync_calendar_events_with_token(user_id, Keyword.put(fetch_opts, :provider, provider)) do
      {:ok, events, next_sync_token} ->
        persist_sync_token(account, next_sync_token)
        {:ok, %{count: length(events), next_sync_token: next_sync_token}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_sync_token(_account, next_sync_token)
       when next_sync_token in [nil, ""],
       do: :ok

  defp persist_sync_token(account, next_sync_token) do
    SourceCursors.put(account, @sync_token_cursor_kind, %{"value" => next_sync_token})
  end

  # Clears just the stored token `value`, preserving the row's watch
  # bookkeeping (`watch_channel_id`/`watch_resource_id`/`watch_expires_at`)
  # used by `Maraithon.Runtime.WatchRenewer` - a full `SourceCursors.clear/2`
  # would delete that row too and silently drop the account from watch
  # renewal until the next OAuth reconnect.
  defp clear_sync_token(account) do
    SourceCursors.put(account, @sync_token_cursor_kind, %{"value" => nil})
  end

  @doc """
  Fetches upcoming events from the user's primary calendar.
  """
  def fetch_upcoming_events(user_id, max_results \\ 10) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        params =
          URI.encode_query(%{
            timeMin: now,
            maxResults: max_results,
            singleEvents: true,
            orderBy: "startTime"
          })

        url = "#{api_base_url()}/calendars/primary/events?#{params}"

        case Google.api_request(:get, url, token) do
          {:ok, response} ->
            events = parse_events(response["items"] || [])
            {:ok, events}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Event Writes (SPEC 12 — calendar time-blocking)
  # ===========================================================================

  @doc """
  Creates an event on the user's primary calendar (SPEC 12 R2).

  `event_attrs` keys:

    * `:summary` (required string)
    * `:description` (optional string)
    * `:start` / `:end` (required, `%DateTime{}` or ISO-8601 string)
    * `:timezone` (required IANA name, e.g. `"America/New_York"` — passed as
      the `timeZone` of both `start` and `end` so Google resolves DST, never
      a hand-computed UTC offset)
    * `:client_event_id` (required, RFC2938 base32hex id derived from the
      prepared action, SPEC 12 R7 — makes retried creates idempotent)
    * `:extended_private_properties` (map, SPEC 12 R8 ownership markers)

  A `409` on the client-generated id means a prior attempt actually created
  the event and the response was lost: the event is fetched back and returned
  as success when its `maraithon_client_key` marker matches (R7).

  A `403` carrying Google's insufficient-scope signature returns the distinct
  `{:error, :calendar_write_scope_required}` so callers surface a reconnect
  prompt instead of flowing into the generic connector-health path (R6) —
  never call `ConnectedAccounts.mark_error/3` / `report_access_issue/3` for
  this error, since the account's read/sync/watch path is still healthy.
  """
  def create_event(user_id, event_attrs) when is_map(event_attrs) do
    with {:ok, token} <- OAuth.get_valid_access_token(user_id, "google"),
         {:ok, client_event_id} <- fetch_client_event_id(event_attrs),
         {:ok, start_iso} <- event_time_iso(read_attr(event_attrs, :start)),
         {:ok, end_iso} <- event_time_iso(read_attr(event_attrs, :end)),
         {:ok, timezone} <- fetch_timezone(event_attrs) do
      body =
        %{
          id: client_event_id,
          summary: read_attr(event_attrs, :summary),
          start: %{dateTime: start_iso, timeZone: timezone},
          end: %{dateTime: end_iso, timeZone: timezone},
          extendedProperties: %{
            private: read_attr(event_attrs, :extended_private_properties) || %{}
          }
        }
        |> maybe_put_description(read_attr(event_attrs, :description))

      url = "#{api_base_url()}/calendars/primary/events"

      case Google.api_request(:post, url, token, body) do
        {:ok, response} when is_map(response) ->
          {:ok, parse_event_detail(response)}

        {:error, {:http_status, 403, response_body}} = error ->
          if insufficient_scope_body?(response_body) do
            {:error, :calendar_write_scope_required}
          else
            # A non-scope 403 (revoked token etc.) keeps the generic shape so
            # the existing connector error handling still applies.
            error
          end

        {:error, {:http_status, 409, _body}} ->
          recover_existing_event(user_id, client_event_id)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Fetches one event from the primary calendar, including its
  `extendedProperties.private` map (as `:private_properties`) so callers can
  verify the SPEC 12 R8 ownership markers before any update/delete.

  Returns `{:error, :event_gone}` on 404/410.
  """
  def get_event(user_id, event_id) when is_binary(event_id) and event_id != "" do
    with {:ok, token} <- OAuth.get_valid_access_token(user_id, "google") do
      url = "#{api_base_url()}/calendars/primary/events/#{URI.encode(event_id)}"

      case Google.api_request(:get, url, token) do
        {:ok, response} when is_map(response) ->
          {:ok, parse_event_detail(response)}

        {:error, {:http_status, status, _body}} when status in [404, 410] ->
          {:error, :event_gone}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def get_event(_user_id, _event_id), do: {:error, :missing_event_id}

  @doc """
  Patches an event on the primary calendar (SPEC 12 R9). Callers MUST have
  verified the R8 ownership markers via `get_event/2` first — this function
  is transport only. Datetime changes carry the explicit IANA `timeZone`.

  Returns `{:error, :event_gone}` on 404/410 (event since deleted by the
  user — callers degrade to "propose a fresh block", never a crash).
  """
  def update_event(user_id, event_id, event_attrs)
      when is_binary(event_id) and event_id != "" and is_map(event_attrs) do
    with {:ok, token} <- OAuth.get_valid_access_token(user_id, "google"),
         {:ok, body} <- update_event_body(event_attrs) do
      url = "#{api_base_url()}/calendars/primary/events/#{URI.encode(event_id)}"

      case Google.api_request(:patch, url, token, body) do
        {:ok, response} when is_map(response) ->
          {:ok, parse_event_detail(response)}

        {:error, {:http_status, 403, response_body}} = error ->
          if insufficient_scope_body?(response_body) do
            {:error, :calendar_write_scope_required}
          else
            error
          end

        {:error, {:http_status, status, _body}} when status in [404, 410] ->
          {:error, :event_gone}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Deletes an event from the primary calendar (SPEC 12 R9). Callers MUST have
  verified the R8 ownership markers via `get_event/2` first.

  Idempotent: a 404/410 (already deleted) returns `{:ok, :already_gone}` —
  a second delete of an already-deleted event is success, not error.
  """
  def delete_event(user_id, event_id) when is_binary(event_id) and event_id != "" do
    with {:ok, token} <- OAuth.get_valid_access_token(user_id, "google") do
      url = "#{api_base_url()}/calendars/primary/events/#{URI.encode(event_id)}"

      case Google.api_request(:delete, url, token) do
        {:ok, _response} ->
          {:ok, :deleted}

        {:error, {:http_status, status, _body}} when status in [404, 410] ->
          {:ok, :already_gone}

        {:error, {:http_status, 403, response_body}} = error ->
          if insufficient_scope_body?(response_body) do
            {:error, :calendar_write_scope_required}
          else
            error
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Fresh read of events overlapping `[time_min, time_max]` on the primary
  calendar (SPEC 12 R10 double-booking recheck). Google's `timeMin`/`timeMax`
  bounds are exclusive against event end/start respectively, so this returns
  exactly the events that genuinely overlap the window.
  """
  def events_in_window(user_id, time_min, time_max) do
    with {:ok, token} <- OAuth.get_valid_access_token(user_id, "google"),
         {:ok, time_min_iso} <- event_time_iso(time_min),
         {:ok, time_max_iso} <- event_time_iso(time_max) do
      params =
        URI.encode_query(%{
          timeMin: time_min_iso,
          timeMax: time_max_iso,
          singleEvents: true,
          maxResults: 50,
          orderBy: "startTime"
        })

      url = "#{api_base_url()}/calendars/primary/events?#{params}"

      case Google.api_request(:get, url, token) do
        {:ok, response} -> {:ok, parse_events(response["items"] || [])}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # 409 on the client-generated id: the event already exists from a prior
  # attempt whose response was lost. Fetch it back and treat as success only
  # when the R8 `maraithon_client_key` marker proves it is this action's
  # event (defense against a hash collision with an unrelated event).
  defp recover_existing_event(user_id, client_event_id) do
    case get_event(user_id, client_event_id) do
      {:ok, event} ->
        if Map.get(event.private_properties || %{}, "maraithon_client_key") == client_event_id do
          {:ok, event}
        else
          {:error, :calendar_event_id_conflict}
        end

      {:error, :event_gone} ->
        {:error, :calendar_event_id_conflict}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_client_event_id(event_attrs) do
    case read_attr(event_attrs, :client_event_id) do
      value when is_binary(value) ->
        if Regex.match?(~r/^[a-v0-9]{5,1024}$/, value) do
          {:ok, value}
        else
          {:error, :invalid_client_event_id}
        end

      _ ->
        {:error, :missing_client_event_id}
    end
  end

  defp fetch_timezone(event_attrs) do
    case read_attr(event_attrs, :timezone) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_timezone}
    end
  end

  defp event_time_iso(%DateTime{} = datetime), do: {:ok, DateTime.to_iso8601(datetime)}

  defp event_time_iso(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      _ -> {:error, :invalid_event_time}
    end
  end

  defp event_time_iso(_value), do: {:error, :invalid_event_time}

  defp maybe_put_description(body, description)
       when is_binary(description) and description != "",
       do: Map.put(body, :description, description)

  defp maybe_put_description(body, _description), do: body

  defp update_event_body(event_attrs) do
    base =
      case read_attr(event_attrs, :summary) do
        summary when is_binary(summary) and summary != "" -> %{summary: summary}
        _ -> %{}
      end

    base = maybe_put_description(base, read_attr(event_attrs, :description))

    case {read_attr(event_attrs, :start), read_attr(event_attrs, :end)} do
      {nil, nil} ->
        if base == %{}, do: {:error, :empty_event_update}, else: {:ok, base}

      {start_value, end_value} ->
        with {:ok, timezone} <- fetch_timezone(event_attrs),
             {:ok, start_iso} <- event_time_iso(start_value),
             {:ok, end_iso} <- event_time_iso(end_value) do
          {:ok,
           Map.merge(base, %{
             start: %{dateTime: start_iso, timeZone: timezone},
             end: %{dateTime: end_iso, timeZone: timezone}
           })}
        end
    end
  end

  # Google phrases the insufficient-scope 403 several ways depending on API
  # surface ("insufficient authentication scopes",
  # reason: "insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT").
  # Match any of them case-insensitively rather than an exact body match.
  defp insufficient_scope_body?(body) when is_binary(body) do
    normalized = String.downcase(body)

    String.contains?(normalized, "insufficient authentication scopes") or
      String.contains?(normalized, "insufficientpermissions") or
      String.contains?(normalized, "access_token_scope_insufficient") or
      String.contains?(normalized, "insufficient_scope")
  end

  defp insufficient_scope_body?(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> insufficient_scope_body?(encoded)
      _ -> false
    end
  end

  defp insufficient_scope_body?(_body), do: false

  defp parse_event_detail(item) when is_map(item) do
    [parsed] = parse_events([item])

    Map.put(
      parsed,
      :private_properties,
      get_in(item, ["extendedProperties", "private"]) || %{}
    )
  end

  defp read_attr(attrs, key) when is_map(attrs) and is_atom(key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp get_access_token(_user_id, token) when is_binary(token) and token != "", do: {:ok, token}

  defp get_access_token(user_id, _) do
    OAuth.get_valid_access_token(user_id, "google")
  end

  defp create_watch(user_id, access_token) do
    webhook_url = get_webhook_url()

    if is_nil(webhook_url) or webhook_url == "" do
      {:error, :webhook_url_not_configured}
    else
      channel_id = generate_channel_id()

      url = "#{api_base_url()}/calendars/primary/events/watch"

      body = %{
        id: channel_id,
        type: "web_hook",
        address: webhook_url,
        token: user_id,
        params: %{
          ttl: "604800"
        }
      }

      case Google.api_request(:post, url, access_token, body) do
        {:ok, response} ->
          {:ok,
           %{
             id: response["id"],
             resource_id: response["resourceId"],
             expiration: parse_expiration(response["expiration"])
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Follows `nextPageToken` across `events.list` pages, accumulating events.
  # Google only returns `nextSyncToken` on the FINAL page, so a caller that
  # stopped after page 1 would get a nil token on every multi-page result and
  # never advance its cursor (`persist_sync_token` no-ops on nil), causing
  # the next sync to re-fetch the same first page forever.
  defp fetch_events(access_token, opts) do
    fetch_events_page(access_token, opts, [], 1, nil)
  end

  defp fetch_events_page(access_token, opts, acc_items, page, page_token) do
    sync_token = Keyword.get(opts, :sync_token)

    params =
      if sync_token do
        %{syncToken: sync_token}
      else
        max_results = Keyword.get(opts, :max_results, 100)

        time_min =
          opts
          |> Keyword.get(:time_min)
          |> normalize_iso_time(fn ->
            DateTime.utc_now() |> DateTime.add(-7, :day) |> DateTime.to_iso8601()
          end)

        time_max = opts |> Keyword.get(:time_max) |> normalize_iso_time(fn -> nil end)

        base = %{
          timeMin: time_min,
          singleEvents: true,
          maxResults: max_results
        }

        if time_max, do: Map.put(base, :timeMax, time_max), else: base
      end

    params = maybe_put_page_token(params, page_token)

    url = "#{api_base_url()}/calendars/primary/events?#{URI.encode_query(params)}"

    case Google.api_request(:get, url, access_token) do
      {:ok, response} ->
        acc_items = acc_items ++ (response["items"] || [])
        next_page_token = response["nextPageToken"]

        cond do
          present?(next_page_token) and page < max_sync_pages() ->
            fetch_events_page(access_token, opts, acc_items, page + 1, next_page_token)

          present?(next_page_token) ->
            # Safety cap hit. Return what we have but no sync token, so
            # `persist_sync_token` no-ops rather than persisting a token that
            # would skip the unseen remaining pages.
            Logger.warning(
              "Calendar sync pagination exceeded safety cap; returning partial batch without advancing cursor",
              pages: page
            )

            {:ok, parse_events(acc_items), nil}

          true ->
            {:ok, parse_events(acc_items), response["nextSyncToken"]}
        end

      {:error, {:http_status, 410, _}} ->
        # Sync token expired - clear the stored cursor (if the caller gave us
        # a way to do so) and do one full window fetch; the fresh
        # nextSyncToken from that fetch is what gets persisted.
        maybe_reset_sync_token(opts)
        fetch_events_page(access_token, Keyword.delete(opts, :sync_token), [], 1, nil)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_reset_sync_token(opts) do
    case Keyword.get(opts, :on_sync_token_reset) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp maybe_put_page_token(params, page_token) when is_binary(page_token) and page_token != "",
    do: Map.put(params, :pageToken, page_token)

  defp maybe_put_page_token(params, _page_token), do: params

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp max_sync_pages do
    Application.get_env(:maraithon, :google_calendar, [])
    |> Keyword.get(:max_sync_pages, @max_sync_pages)
  end

  defp parse_events(items) do
    Enum.map(items, fn item ->
      %{
        event_id: item["id"],
        summary: item["summary"],
        description: item["description"],
        location: item["location"],
        status: item["status"],
        start: parse_event_time(item["start"]),
        end: parse_event_time(item["end"]),
        attendees: parse_attendees(item["attendees"]),
        organizer: item["organizer"]["email"],
        html_link: item["htmlLink"],
        created: item["created"],
        updated: item["updated"]
      }
    end)
  end

  defp parse_event_time(nil), do: nil

  defp parse_event_time(%{"dateTime" => dt}) when not is_nil(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, datetime, _} -> datetime
      _ -> dt
    end
  end

  defp parse_event_time(%{"date" => date}) when not is_nil(date) do
    # All-day event
    %{date: date, all_day: true}
  end

  defp parse_event_time(_), do: nil

  defp parse_attendees(nil), do: []

  defp parse_attendees(attendees) do
    Enum.map(attendees, fn a ->
      %{
        email: a["email"],
        display_name: a["displayName"],
        response_status: a["responseStatus"],
        organizer: a["organizer"] || false,
        self: a["self"] || false
      }
    end)
  end

  defp parse_expiration(nil), do: nil

  defp parse_expiration(expiration) when is_binary(expiration) do
    case Integer.parse(expiration) do
      {ms, _} -> DateTime.from_unix!(ms, :millisecond)
      :error -> nil
    end
  end

  defp parse_expiration(expiration) when is_integer(expiration) do
    DateTime.from_unix!(expiration, :millisecond)
  end

  defp get_webhook_url do
    Application.get_env(:maraithon, :google, [])
    |> Keyword.get(:calendar_webhook_url, "")
  end

  defp get_header(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value] -> value
      _ -> nil
    end
  end

  defp generate_channel_id do
    "maraithon-cal-#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
  end

  defp api_base_url do
    Application.get_env(:maraithon, :google_calendar, [])
    |> Keyword.get(:api_base_url, @default_api_base)
  end

  # ===========================================================================
  # CRM ingestion
  # ===========================================================================

  @doc """
  Fan a list of parsed calendar events into `Crm.Ingest.observe/2` calls and
  flush any pending window. Used by the live sync path and by the backfill seed.
  """
  def ingest_events(user_id, events) when is_binary(user_id) and is_list(events) do
    user_email = String.downcase(user_id)
    source_account = "primary"

    Enum.each(events, fn event ->
      case to_calendar_observation(event, user_id, user_email, source_account) do
        {:ok, changeset} ->
          case Maraithon.Crm.Ingest.observe(user_id, changeset) do
            {:ok, _} ->
              :ok

            {:ok, _, _} ->
              :ok

            {:ok, _, _, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("CRM ingest skipped a calendar event",
                user_id: user_id,
                event_id: Map.get(event, :event_id),
                reason: inspect(reason)
              )

            other ->
              Logger.warning("CRM ingest unexpected result for calendar event",
                user_id: user_id,
                event_id: Map.get(event, :event_id),
                result: inspect(other)
              )
          end

        :skip ->
          :ok
      end
    end)

    case Maraithon.Crm.Ingest.flush_pending(user_id, "google_calendar") do
      {:ok, _} -> :ok
      _ -> :ok
    end
  end

  def ingest_events(_user_id, _events), do: :ok

  defp to_calendar_observation(event, user_id, user_email, source_account) when is_map(event) do
    case Map.get(event, :event_id) do
      nil ->
        :skip

      event_id ->
        attendees = Map.get(event, :attendees, [])
        organizer_email = Map.get(event, :organizer)

        attendee_participants =
          attendees
          |> Enum.flat_map(fn a ->
            email = Map.get(a, :email)

            cond do
              is_nil(email) or email == "" ->
                []

              String.downcase(email) == user_email ->
                []

              true ->
                role = if Map.get(a, :organizer, false), do: "organizer", else: "attendee"

                [
                  %{
                    "role" => role,
                    "identifier" => %{"email" => String.downcase(email)},
                    "display_name" => presence_or_nil(Map.get(a, :display_name))
                  }
                ]
            end
          end)

        organizer_participant =
          if is_binary(organizer_email) and String.downcase(organizer_email) != user_email and
               not Enum.any?(attendee_participants, fn p ->
                 get_in(p, ["identifier", "email"]) == String.downcase(organizer_email)
               end) do
            [
              %{
                "role" => "organizer",
                "identifier" => %{"email" => String.downcase(organizer_email)},
                "display_name" => nil
              }
            ]
          else
            []
          end

        participants = organizer_participant ++ attendee_participants

        if participants == [] do
          :skip
        else
          occurred_at = calendar_event_occurred_at(event)
          direction = if Map.get(event, :organizer) == user_email, do: "outbound", else: "inbound"

          {:ok,
           Maraithon.Crm.Observation.new(%{
             "user_id" => user_id,
             "source" => "google_calendar",
             "source_account" => source_account,
             "source_item_id" => to_string(event_id),
             "occurred_at" => occurred_at,
             "direction" => direction,
             "participants" => participants,
             "subject" => Map.get(event, :summary),
             "excerpt" =>
               event
               |> Map.get(:description, "")
               |> case do
                 nil -> nil
                 "" -> nil
                 desc when is_binary(desc) -> String.slice(desc, 0, 2_000)
                 _ -> nil
               end,
             "metadata" => %{
               "html_link" => Map.get(event, :html_link),
               "status" => Map.get(event, :status),
               "location" => Map.get(event, :location),
               "attendee_count" => length(attendees)
             }
           })}
        end
    end
  end

  defp to_calendar_observation(_event, _user_id, _user_email, _source_account), do: :skip

  defp calendar_event_occurred_at(event) do
    cond do
      match?(%DateTime{}, Map.get(event, :start)) ->
        Map.get(event, :start)

      match?(%DateTime{}, Map.get(event, :updated)) ->
        Map.get(event, :updated)

      true ->
        DateTime.utc_now()
    end
  end

  defp presence_or_nil(nil), do: nil
  defp presence_or_nil(""), do: nil
  defp presence_or_nil(value), do: value

  defp normalize_iso_time(%DateTime{} = dt, _default), do: DateTime.to_iso8601(dt)

  defp normalize_iso_time(value, _default) when is_binary(value) and value != "", do: value

  defp normalize_iso_time(_, default) when is_function(default, 0), do: default.()
end
