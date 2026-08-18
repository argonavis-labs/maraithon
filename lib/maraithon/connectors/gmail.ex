defmodule Maraithon.Connectors.Gmail do
  @moduledoc """
  Gmail connector.

  Sets up push notifications for email changes and publishes normalized events to PubSub.

  ## Topic Format

  Events are published to `email:{user_id}`

  Example: `email:user_123`

  ## Event Types

  - `email_received` - New email received
  - `email_sync` - Batch of email changes

  ## How it Works

  Gmail push notifications use Google Cloud Pub/Sub:

  1. Create a Cloud Pub/Sub topic in Google Cloud Console
  2. Grant Gmail API service account publish access
  3. Create a push subscription pointing to your webhook
  4. Call Gmail API to "watch" the user's mailbox
  5. Google publishes messages to Pub/Sub when mail changes
  6. Pub/Sub pushes to your webhook

  ## Configuration

  Requires:
  - `GOOGLE_PUBSUB_TOPIC` - Full topic name (e.g., projects/my-project/topics/gmail-push)
  """

  @behaviour Maraithon.Connectors.Connector

  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Crm.Ingest
  alias Maraithon.Crm.Observation
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Connectors.Connector
  alias Maraithon.Runtime.BackgroundJobs

  require Logger

  @default_api_base "https://gmail.googleapis.com/gmail/v1"
  @history_cursor_kind "gmail_history_id"
  @full_resync_window_query "newer_than:1d"
  @full_resync_message_limit 50
  @default_message_fetch_concurrency 12
  @max_message_fetch_concurrency 24
  @default_message_fetch_timeout_ms 15_000
  @default_failed_precondition_retry_delay_ms 1_000
  @max_failed_precondition_retry_delay_ms 5_000
  @gmail_id_pattern ~r/\A[0-9A-Fa-f]+\z/
  # Safety cap on how many `history.list` pages we'll follow for a single
  # incremental sync before giving up and falling back to a full resync. A
  # legitimate delta should never come close to this; it exists so a
  # pathological/looping response can't wedge a background job forever.
  @max_history_pages 25
  # Per-chunk cap on concurrent-ish full-content fetches during an
  # incremental history sync. Every message id from the history delta is
  # processed (in chunks of this size) — the old behavior of truncating to
  # the first 20 while the caller still advanced the history cursor
  # permanently dropped everything past the truncation point.
  @history_message_fetch_chunk 100

  @doc "Returns true when a connected Google account granted a Gmail service scope."
  def enabled_for_account?(%{metadata: metadata, scopes: scopes}) do
    metadata = metadata || %{}
    services = metadata["services"] || metadata[:services] || []

    Enum.member?(List.wrap(services), "gmail") or
      Enum.any?(List.wrap(scopes), fn scope ->
        is_binary(scope) and String.contains?(String.downcase(scope), "gmail")
      end)
  end

  def enabled_for_account?(_account), do: false

  # ===========================================================================
  # Watch Management
  # ===========================================================================

  @doc """
  Sets up a watch on the user's mailbox.

  This registers the user's mailbox with Google Cloud Pub/Sub for push notifications.

  Returns `{:ok, watch_info}` or `{:error, reason}`.
  """
  def setup_watch(user_id, access_token \\ nil) do
    with {:ok, token} <- get_access_token(user_id, access_token),
         {:ok, watch} <- create_watch(user_id, token) do
      Logger.info("Gmail watch created",
        user_id: user_id,
        history_id: watch.history_id,
        expiration: watch.expiration
      )

      {:ok, watch}
    end
  end

  @doc """
  Stops watching the user's mailbox.

  Should be called when a user disconnects their email.
  """
  def stop_watch(user_id) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        url = "#{api_base_url()}/users/me/stop"

        case Google.api_request(:post, url, token, %{}) do
          {:ok, _} -> :ok
          # Gmail returns 404 if not watching - that's fine
          {:error, {:http_status, 404, _}} -> :ok
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
    # Cloud Pub/Sub push subscriptions can be configured to require authentication
    # For now, we rely on the subscription being properly configured
    # In production, you should verify the JWT token from Pub/Sub
    :ok
  end

  @impl true
  def handle_webhook(_conn, params) do
    # Cloud Pub/Sub sends messages in this format:
    # {
    #   "message": {
    #     "data": "<base64 encoded>",
    #     "messageId": "...",
    #     "publishTime": "..."
    #   },
    #   "subscription": "projects/.../subscriptions/..."
    # }
    #
    # We only decode enough to identify the mailbox and enqueue a durable
    # background job; the actual history fetch (and any Google API calls)
    # happen out-of-request in `Maraithon.Runtime.BackgroundJobHandler` so the
    # webhook can ack quickly and Pub/Sub never times out waiting on us.
    case decode_pubsub_message(params) do
      {:ok, claimed_user_id, _history_id, _message_id}
      when not is_binary(claimed_user_id) or claimed_user_id == "" ->
        {:error, :invalid_pubsub_message}

      {:ok, claimed_user_id, history_id, message_id} ->
        # The Pub/Sub push carries no verified identity (verify_signature/2 is
        # a no-op), so the body's emailAddress is attacker-controlled. Only
        # enqueue when it resolves to a known connected-account row — the same
        # lookup the background job itself performs — and derive the job's
        # user_id from the resolved row, never the raw claim. Unknown
        # mailboxes are acked-and-dropped so unauthenticated POSTs cannot
        # flood the job queue.
        case connected_mailbox_account(claimed_user_id) do
          nil ->
            Logger.debug("Gmail webhook for unknown mailbox ignored")
            {:ignore, "unknown mailbox"}

          account ->
            enqueue_incremental_sync(account.user_id, account.provider, history_id, message_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connected_mailbox_account(claimed_mailbox) when is_binary(claimed_mailbox) do
    mailbox = claimed_mailbox |> String.trim() |> String.downcase()

    ConnectedAccounts.get_connected_by_provider("google:#{mailbox}") ||
      ConnectedAccounts.get_connected_by_external_account("google", mailbox) ||
      ConnectedAccounts.get(mailbox, "google")
  end

  defp connected_mailbox_account(_claimed_mailbox), do: nil

  defp enqueue_incremental_sync(user_id, provider, history_id, message_id) do
    topic = "email:#{user_id}"

    dedupe_key = gmail_webhook_dedupe_key(message_id, user_id, history_id)

    case BackgroundJobs.enqueue("gmail_incremental_sync", %{
           "user_id" => user_id,
           "queue" => "connectors",
           "payload" => %{
             "notification_history_id" => history_id,
             "provider" => provider
           },
           "dedupe_key" => dedupe_key
         }) do
      {:ok, _job} ->
        event =
          Connector.build_event("email_webhook_enqueued", "gmail", %{
            user_id: user_id,
            history_id: history_id
          })

        {:ok, topic, event}

      {:error, reason} ->
        Logger.warning("Failed to enqueue Gmail incremental sync",
          user_id: user_id,
          history_id: history_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # ===========================================================================
  # Gmail API
  # ===========================================================================

  @doc """
  Fetches mail history since a given history ID.

  Returns `{:ok, messages}` or `{:error, reason}`.
  """
  def sync_mail_changes(user_id, history_id) do
    case OAuth.get_valid_access_token(user_id, "google") do
      {:ok, token} ->
        case fetch_history(token, history_id) do
          {:ok, messages, _latest_history_id} -> {:ok, messages}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cursor-aware incremental sync used by the `gmail_incremental_sync`
  background job.

  Reads the stored `gmail_history_id` cursor for `account` and uses it as
  `startHistoryId` (the *last processed* id, not the notification's own id).
  On success, ingests the messages and advances the cursor to the response's
  max historyId. When the stored id has expired (Gmail 404s) or no cursor
  exists yet, falls back to a bounded recent-window full fetch and resets the
  cursor to the mailbox's current history head.

  Returns `{:ok, %{count: n, history_id: id, mode: :incremental | :full_resync}}`
  or `{:error, reason}`.
  """
  def sync_history(user_id, account, opts \\ []) do
    provider = Keyword.get(opts, :provider, account.provider)

    case OAuth.get_valid_access_token(user_id, provider) do
      {:ok, token} ->
        cursor = SourceCursors.get(account.id, @history_cursor_kind)

        case cursor_history_id(cursor) do
          nil -> full_resync(user_id, account, token)
          history_id -> incremental_sync(user_id, account, token, history_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cursor_history_id(nil), do: nil
  defp cursor_history_id(%{value: value}) when is_binary(value) and value != "", do: value
  defp cursor_history_id(_cursor), do: nil

  defp incremental_sync(user_id, account, token, history_id) do
    case fetch_history(token, history_id) do
      {:ok, messages, latest_history_id} ->
        ingest_messages(user_id, messages)
        persist_history_cursor(account, latest_history_id || history_id)
        {:ok, %{count: length(messages), history_id: latest_history_id, mode: :incremental}}

      {:error, :history_expired} ->
        full_resync(user_id, account, token)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp full_resync(user_id, account, token) do
    case fetch_messages(token,
           max_results: @full_resync_message_limit,
           label_ids: [],
           query: @full_resync_window_query,
           access_token: true
         ) do
      {:ok, messages} ->
        ingest_messages(user_id, messages)

        case current_history_id(token) do
          {:ok, history_id} ->
            persist_history_cursor(account, history_id)
            {:ok, %{count: length(messages), history_id: history_id, mode: :full_resync}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_history_cursor(_account, nil), do: :ok

  defp persist_history_cursor(account, history_id) do
    SourceCursors.put(account, @history_cursor_kind, %{"value" => to_string(history_id)})
  end

  @doc """
  Fetches the mailbox's current `historyId` (the head of the history log),
  used to establish a fresh cursor baseline after a full resync.
  """
  def current_history_id(access_token) do
    url = "#{api_base_url()}/users/me/profile"

    case Google.api_request(:get, url, access_token) do
      {:ok, %{"historyId" => history_id}} when not is_nil(history_id) ->
        {:ok, history_id}

      {:ok, _response} ->
        {:error, :missing_history_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches recent emails from the user's inbox.
  """
  def fetch_recent_emails(user_id_or_token, max_results \\ 10, opts \\ []) do
    fetch_messages(
      user_id_or_token,
      Keyword.merge(opts, max_results: max_results, label_ids: ["INBOX"])
    )
  end

  @doc """
  Lists Gmail messages and hydrates each listed id.

  The default body mode remains `:full`. Callers with a bounded acquisition
  phase may request `message_format: :metadata`, tune concurrency/timeouts, and
  set `include_fetch_metadata: true` to receive completeness metadata as a
  third tuple element.
  """
  def fetch_messages(user_id_or_token, opts \\ [])
      when is_binary(user_id_or_token) and is_list(opts) do
    max_results = Keyword.get(opts, :max_results, 10)
    label_ids = Keyword.get(opts, :label_ids, [])
    query = Keyword.get(opts, :query)

    case request_access_token(user_id_or_token, opts) do
      {:ok, token} ->
        params =
          [{"maxResults", max_results}]
          |> maybe_append_query("q", query)
          |> append_repeated_query("labelIds", label_ids)
          |> Enum.map(&URI.encode_query([&1]))
          |> Enum.join("&")

        url = "#{api_base_url()}/users/me/messages?#{params}"

        case Google.api_request(:get, url, token) do
          {:ok, response} when is_map(response) ->
            messages = Map.get(response, "messages", [])
            messages = if is_list(messages), do: messages, else: []
            selected = Enum.take(messages, max_results)
            {detailed, detail_failure_count} = fetch_message_details(selected, token, opts)
            body_fallback_count = Enum.count(detailed, &metadata_body_fallback?/1)

            fetch_metadata = %{
              listed_count: length(messages),
              requested_count: length(selected),
              detail_success_count: length(detailed),
              detail_failure_count: detail_failure_count,
              body_fallback_count: body_fallback_count,
              truncated?:
                present?(Map.get(response, "nextPageToken")) or length(messages) > max_results
            }

            fetch_metadata =
              Map.put(
                fetch_metadata,
                :complete?,
                detail_failure_count == 0 and body_fallback_count == 0 and
                  not fetch_metadata.truncated?
              )

            if Keyword.get(opts, :include_fetch_metadata, false) do
              {:ok, detailed, fetch_metadata}
            else
              {:ok, detailed}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_message_details(messages, token, opts) do
    format = Keyword.get(opts, :message_format, :full)

    max_concurrency =
      opts
      |> Keyword.get(:message_fetch_concurrency, @default_message_fetch_concurrency)
      |> normalize_message_fetch_concurrency()

    messages
    |> Task.async_stream(
      fn message -> safe_fetch_message_detail(token, message, format, opts) end,
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: message_fetch_timeout_ms(opts),
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], 0}, fn
      {:ok, {:ok, message}}, {detailed, failures} ->
        {[message | detailed], failures}

      _error, {detailed, failures} ->
        {detailed, failures + 1}
    end)
    |> then(fn {detailed, failures} -> {Enum.reverse(detailed), failures} end)
  end

  defp safe_fetch_message_detail(token, %{"id" => id}, format, opts) when is_binary(id) do
    try do
      fetch_message_detail(token, id, format, opts)
    rescue
      error -> {:error, {:detail_exception, error.__struct__}}
    catch
      kind, reason -> {:error, {:detail_task_failure, kind, reason}}
    end
  end

  defp safe_fetch_message_detail(_token, _message, _format, _opts),
    do: {:error, :missing_message_id}

  defp fetch_message_detail(token, id, format, opts) when format in [:metadata, "metadata"] do
    fetch_message(token, id, listed_message_opts(opts))
  end

  defp fetch_message_detail(token, id, _format, opts) do
    fetch_message_content(token, id, listed_message_opts(opts))
  end

  defp listed_message_opts(opts) do
    opts
    |> Keyword.take([:failed_precondition_retry_delay_ms])
    |> Keyword.merge(access_token: true, listed_message: true)
  end

  defp message_fetch_timeout_ms(opts) do
    case Keyword.get(opts, :message_fetch_timeout_ms, @default_message_fetch_timeout_ms) do
      :infinity -> :infinity
      value when is_integer(value) and value > 0 -> value
      _value -> @default_message_fetch_timeout_ms
    end
  end

  defp normalize_message_fetch_concurrency(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@max_message_fetch_concurrency)
  end

  defp normalize_message_fetch_concurrency(_value), do: @default_message_fetch_concurrency

  @doc """
  Normalizes a raw Gmail message or thread id, returning `nil` for composite,
  synthetic, or otherwise invalid values.
  """
  def normalize_id(value) when is_binary(value) do
    id = String.trim(value)

    if id != "" and Regex.match?(@gmail_id_pattern, id), do: id
  end

  def normalize_id(_value), do: nil

  @doc """
  Returns whether a value is a valid raw Gmail API message or thread id.
  """
  def valid_id?(value), do: is_binary(normalize_id(value))

  @doc """
  Fetches a single email message.
  """
  def fetch_message(user_id_or_token, message_id, opts \\ []) do
    with id when is_binary(id) <- normalize_id(message_id),
         {:ok, access_token} <- request_access_token(user_id_or_token, opts),
         {:ok, response} <-
           fetch_gmail_point_resource(access_token, "messages", id, "metadata", opts) do
      {:ok, parse_message(response)}
    else
      nil -> {:error, :invalid_gmail_id}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Fetches a single Gmail message with decoded text and html body content.

  Callers hydrating an id returned by a successful list or history request may
  pass `listed_message: true`. Exact Gmail `FAILED_PRECONDITION` point-read
  churn is then retried once before retaining metadata with an unavailable-body
  marker. Direct lookups remain strict and noisy.
  """
  def fetch_message_content(user_id_or_token, message_id, opts \\ []) do
    with id when is_binary(id) <- normalize_id(message_id),
         {:ok, access_token} <- request_access_token(user_id_or_token, opts) do
      fetch_full_message_content(access_token, id, opts)
    else
      nil -> {:error, :invalid_gmail_id}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Fetches all available messages in one Gmail thread using metadata format.
  """
  def fetch_thread(user_id_or_token, thread_id, opts \\ []) do
    with id when is_binary(id) <- normalize_id(thread_id),
         {:ok, access_token} <- request_access_token(user_id_or_token, opts),
         {:ok, response} <- fetch_gmail_point_resource(access_token, "threads", id, "metadata") do
      case response do
        %{"messages" => messages} when is_list(messages) ->
          {:ok, Enum.map(messages, &parse_message/1)}

        _response ->
          {:ok, []}
      end
    else
      nil -> {:error, :invalid_gmail_id}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Sends a Gmail message, optionally within an existing thread.
  """
  def send_message(user_id_or_token, attrs) when is_map(attrs) do
    with {:ok, access_token, provider} <- access_token_for_send(user_id_or_token, attrs),
         {:ok, to} <- required_attr(attrs, "to"),
         {:ok, subject} <- required_attr(attrs, "subject"),
         {:ok, body} <- required_attr(attrs, "body") do
      thread_id = optional_attr(attrs, "thread_id")
      reply_to_message_id = optional_attr(attrs, "reply_to_message_id")
      reply_headers = fetch_reply_headers(access_token, reply_to_message_id)

      raw =
        build_raw_message(
          to,
          subject,
          body,
          reply_headers["message_id"],
          reply_headers["references"]
        )

      request_body =
        %{raw: raw}
        |> maybe_put("threadId", thread_id)

      url = "#{api_base_url()}/users/me/messages/send"

      case Google.api_request(:post, url, access_token, request_body) do
        {:ok, response} ->
          {:ok,
           %{
             provider: provider,
             message_id: response["id"],
             thread_id: response["threadId"],
             label_ids: response["labelIds"] || []
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp fetch_full_message_content(access_token, id, opts) do
    case fetch_gmail_point_resource(access_token, "messages", id, "full", opts) do
      {:ok, response} ->
        {:ok, parse_message_content(response)}

      {:error, {:http_status, status, body}} = error ->
        if listed_message?(opts) and listed_message_failed_precondition?(status, body) do
          fetch_message_metadata_fallback(access_token, id, opts)
        else
          error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_message_metadata_fallback(access_token, id, opts) do
    case fetch_gmail_point_resource(access_token, "messages", id, "metadata", opts) do
      {:ok, response} ->
        message =
          response
          |> parse_message()
          |> Map.merge(%{
            text_body: nil,
            html_body: nil,
            body_unavailable_reason: "failed_precondition"
          })

        {:ok, message}

      {:error, _reason} = error ->
        error
    end
  end

  defp metadata_body_fallback?(%{body_unavailable_reason: "failed_precondition"}), do: true
  defp metadata_body_fallback?(_message), do: false

  defp fetch_gmail_point_resource(access_token, resource, id, format) do
    fetch_gmail_point_resource(access_token, resource, id, format, [])
  end

  defp fetch_gmail_point_resource(access_token, resource, id, format, opts) do
    url = "#{api_base_url()}/users/me/#{resource}/#{id}?format=#{format}"

    request_opts =
      [expected_statuses: [404]]
      |> maybe_expect_listed_message_error(opts)

    request = fn -> Google.api_request(:get, url, access_token, nil, [], request_opts) end

    request.()
    |> maybe_retry_listed_message(request, opts)
    |> case do
      {:error, {:http_status, 404, _body}} -> {:error, :not_found}
      result -> result
    end
  end

  defp maybe_expect_listed_message_error(request_opts, opts) do
    if listed_message?(opts) do
      Keyword.put(request_opts, :expected_error?, &listed_message_failed_precondition?/2)
    else
      request_opts
    end
  end

  defp maybe_retry_listed_message(
         {:error, {:http_status, status, body}} = error,
         request,
         opts
       ) do
    if listed_message?(opts) and listed_message_failed_precondition?(status, body) do
      delay_ms = failed_precondition_retry_delay_ms(opts)
      if delay_ms > 0, do: Process.sleep(delay_ms)
      request.()
    else
      error
    end
  end

  defp maybe_retry_listed_message(result, _request, _opts), do: result

  defp listed_message_failed_precondition?(400, body) when is_binary(body) do
    String.contains?(body, "FAILED_PRECONDITION") and
      String.contains?(body, "failedPrecondition") and
      String.contains?(body, "Precondition check failed.")
  end

  defp listed_message_failed_precondition?(_status, _body), do: false

  defp listed_message?(opts), do: Keyword.get(opts, :listed_message, false) == true

  defp failed_precondition_retry_delay_ms(opts) do
    case Keyword.get(
           opts,
           :failed_precondition_retry_delay_ms,
           @default_failed_precondition_retry_delay_ms
         ) do
      delay_ms when is_integer(delay_ms) and delay_ms >= 0 ->
        min(delay_ms, @max_failed_precondition_retry_delay_ms)

      _delay_ms ->
        @default_failed_precondition_retry_delay_ms
    end
  end

  defp get_access_token(_user_id, token) when is_binary(token) and token != "", do: {:ok, token}

  defp get_access_token(user_id, _) do
    OAuth.get_valid_access_token(user_id, "google")
  end

  defp request_access_token("ya29." <> _ = token, _opts), do: {:ok, token}

  defp request_access_token(token, opts) when is_binary(token) and is_list(opts) do
    if Keyword.get(opts, :access_token, false) do
      {:ok, token}
    else
      case Keyword.get(opts, :provider) do
        provider when is_binary(provider) and provider != "" ->
          OAuth.get_valid_access_token(token, provider)

        _ ->
          get_access_token(token, nil)
      end
    end
  end

  defp access_token_for_send("ya29." <> _ = access_token, _attrs) do
    {:ok, access_token, "google"}
  end

  defp access_token_for_send(user_id, attrs) when is_binary(user_id) do
    account = optional_attr(attrs, "account")
    provider = if is_binary(account) and account != "", do: "google:#{account}", else: "google"

    case OAuth.get_valid_access_token(user_id, provider) do
      {:ok, access_token} ->
        {:ok, access_token, provider}

      {:error, :no_token} when provider != "google" ->
        get_access_token(user_id, nil) |> wrap_provider("google")

      other ->
        wrap_provider(other, provider)
    end
  end

  defp wrap_provider({:ok, access_token}, provider), do: {:ok, access_token, provider}
  defp wrap_provider(other, _provider), do: other

  defp create_watch(_user_id, access_token) do
    pubsub_topic = get_pubsub_topic()

    if is_nil(pubsub_topic) or pubsub_topic == "" do
      {:error, :pubsub_topic_not_configured}
    else
      url = "#{api_base_url()}/users/me/watch"

      body = %{
        topicName: pubsub_topic,
        labelIds: ["INBOX"]
      }

      case Google.api_request(:post, url, access_token, body) do
        {:ok, response} ->
          {:ok,
           %{
             history_id: response["historyId"],
             expiration: parse_expiration(response["expiration"])
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Follows `nextPageToken` across `users/me/history` pages, accumulating
  # history records BEFORE the cursor is advanced. Google returns
  # `historyId` (the mailbox's current head, used for cursor advancement) on
  # every page, but only the *final* page's records complete the delta - if
  # we stopped at page 1 like the old single-request implementation did,
  # pages 2+ would be silently dropped forever once the cursor moved past
  # them.
  defp fetch_history(access_token, history_id) do
    fetch_history_page(access_token, history_id, nil, [], 1)
  end

  defp fetch_history_page(access_token, history_id, page_token, acc_history, page) do
    params =
      %{startHistoryId: history_id, historyTypes: "messageAdded"}
      |> maybe_put_page_token(page_token)
      |> URI.encode_query()

    url = "#{api_base_url()}/users/me/history?#{params}"

    case Google.api_request(:get, url, access_token) do
      {:ok, response} ->
        # Gmail omits the "history" key entirely when a page's filtered
        # result set is empty (e.g. a page with only non-messageAdded
        # events). That can happen on ANY page of the pagination loop, not
        # just a single-page response - treat it as an empty page and keep
        # following nextPageToken rather than discarding acc_history and
        # stopping short.
        history = response["history"] || []
        acc_history = acc_history ++ history
        next_page_token = response["nextPageToken"]

        cond do
          present?(next_page_token) and page < max_history_pages() ->
            fetch_history_page(access_token, history_id, next_page_token, acc_history, page + 1)

          present?(next_page_token) ->
            # Safety cap hit - treat like a history overflow rather than risk
            # advancing the cursor past unread pages. The caller's existing
            # history_expired fallback does a bounded full resync and resets
            # the cursor to the mailbox's current head.
            Logger.warning(
              "Gmail history pagination exceeded safety cap; falling back to full resync",
              history_id: history_id,
              pages: page
            )

            {:error, :history_expired}

          true ->
            build_history_result(access_token, acc_history, response["historyId"])
        end

      {:error, {:http_status, 404, _}} ->
        # History ID too old - need full sync
        {:error, :history_expired}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_history_result(access_token, history_records, latest_history_id) do
    # Extract added message IDs across all accumulated pages
    message_ids =
      history_records
      |> Enum.flat_map(fn h -> h["messagesAdded"] || [] end)
      |> Enum.map(fn ma -> ma["message"]["id"] end)
      |> Enum.uniq()

    if length(message_ids) > @history_message_fetch_chunk do
      Logger.warning("Gmail history sync processing large delta in chunks",
        message_count: length(message_ids),
        chunk_size: @history_message_fetch_chunk
      )
    end

    # Fetch full message details so downstream model triage can use body text.
    # Process EVERY id from the delta — the caller advances the history
    # cursor to latest_history_id afterwards, so any id skipped here would be
    # silently lost forever. Chunking bounds each fetch burst; the total is
    # already bounded by the history pagination safety cap.
    messages =
      message_ids
      |> Enum.chunk_every(@history_message_fetch_chunk)
      |> Enum.flat_map(fn chunk ->
        chunk
        |> Task.async_stream(
          fn id ->
            fetch_message_content(access_token, id,
              access_token: true,
              listed_message: true
            )
          end,
          max_concurrency: 8,
          ordered: true,
          timeout: :infinity
        )
        |> Enum.flat_map(fn
          {:ok, {:ok, message}} -> [message]
          _ -> []
        end)
      end)

    {:ok, messages, latest_history_id}
  end

  defp maybe_put_page_token(params, page_token) when is_binary(page_token) and page_token != "",
    do: Map.put(params, :pageToken, page_token)

  defp maybe_put_page_token(params, _page_token), do: params

  defp max_history_pages do
    Application.get_env(:maraithon, :gmail, [])
    |> Keyword.get(:max_history_pages, @max_history_pages)
  end

  defp parse_message(message) do
    headers = message["payload"]["headers"] || []

    %{
      message_id: message["id"],
      thread_id: message["threadId"],
      snippet: message["snippet"],
      labels: message["labelIds"] || [],
      from: get_header(headers, "From"),
      to: get_header(headers, "To"),
      subject: get_header(headers, "Subject"),
      internet_message_id: get_header(headers, "Message-ID"),
      references: get_header(headers, "References"),
      date: get_header(headers, "Date"),
      internal_date: parse_internal_date(message["internalDate"])
    }
  end

  defp parse_message_content(message) do
    {text_body, html_body} = extract_message_bodies(message["payload"] || %{})

    parse_message(message)
    |> Map.merge(%{
      text_body: text_body,
      html_body: html_body
    })
  end

  defp extract_message_bodies(payload) when is_map(payload) do
    plain = collect_body(payload, "text/plain")
    html = collect_body(payload, "text/html")

    {plain || fallback_body(payload), html}
  end

  defp collect_body(payload, mime_type) when is_map(payload) do
    cond do
      payload["mimeType"] == mime_type ->
        decode_body(payload["body"])

      is_list(payload["parts"]) ->
        Enum.find_value(payload["parts"], &collect_body(&1, mime_type))

      true ->
        nil
    end
  end

  defp fallback_body(payload) when is_map(payload) do
    case decode_body(payload["body"]) do
      nil ->
        if is_list(payload["parts"]) do
          Enum.find_value(payload["parts"], &fallback_body/1)
        end

      decoded ->
        decoded
    end
  end

  defp decode_body(%{"data" => data}) when is_binary(data) do
    case Base.url_decode64(data, padding: false) do
      {:ok, decoded} -> decoded
      :error -> nil
    end
  end

  defp decode_body(_body), do: nil

  defp fetch_reply_headers(_access_token, nil), do: %{}
  defp fetch_reply_headers(_access_token, ""), do: %{}

  defp fetch_reply_headers(access_token, message_id) do
    with id when is_binary(id) <- normalize_id(message_id) do
      params =
        [
          {"format", "metadata"},
          {"metadataHeaders", "Message-ID"},
          {"metadataHeaders", "References"}
        ]
        |> Enum.map(&URI.encode_query([&1]))
        |> Enum.join("&")

      url = "#{api_base_url()}/users/me/messages/#{id}?#{params}"

      case Google.api_request(:get, url, access_token, nil, [], expected_statuses: [404]) do
        {:ok, response} ->
          parsed = parse_message(response)

          %{
            "message_id" => parsed.internet_message_id,
            "references" => parsed.references
          }

        _error ->
          %{}
      end
    else
      nil -> %{}
    end
  end

  defp build_raw_message(to, subject, body, in_reply_to, references) do
    [
      "To: #{to}",
      "Subject: #{subject}",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      if(present?(in_reply_to), do: "In-Reply-To: #{in_reply_to}"),
      if(present?(references), do: "References: #{references}"),
      "",
      body
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
    |> Base.url_encode64(padding: false)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_append_query(params, _key, nil), do: params
  defp maybe_append_query(params, _key, ""), do: params
  defp maybe_append_query(params, key, value), do: params ++ [{key, value}]

  defp append_repeated_query(params, _key, []), do: params

  defp append_repeated_query(params, key, values) when is_list(values) do
    params ++ Enum.map(values, &{key, &1})
  end

  defp required_attr(attrs, key) do
    case optional_attr(attrs, key) do
      nil -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp optional_attr(attrs, key) when is_map(attrs) do
    value =
      case Map.fetch(attrs, key) do
        {:ok, direct} ->
          direct

        :error ->
          Enum.find_value(attrs, fn
            {map_key, map_value} when is_atom(map_key) ->
              if Atom.to_string(map_key) == key, do: map_value

            _ ->
              nil
          end)
      end

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp get_header(headers, name) do
    case Enum.find(headers, fn h -> h["name"] == name end) do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp parse_internal_date(nil), do: nil

  defp parse_internal_date(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {millis, _} -> DateTime.from_unix!(millis, :millisecond)
      :error -> nil
    end
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

  defp decode_pubsub_message(%{"message" => %{"data" => data} = message}) do
    with {:ok, json} <- Base.decode64(data),
         {:ok, payload} <- Jason.decode(json) do
      # Gmail sends: {"emailAddress": "user@example.com", "historyId": "12345"}
      user_email = payload["emailAddress"]
      history_id = payload["historyId"]
      message_id = message["messageId"]

      # We use email address as user_id for Gmail
      # In production, you'd map this to your internal user_id
      {:ok, user_email, history_id, message_id}
    else
      _ -> {:error, :invalid_pubsub_message}
    end
  end

  defp decode_pubsub_message(_) do
    {:error, :invalid_pubsub_format}
  end

  # Pub/Sub's `messageId` uniquely identifies a delivery attempt; fall back to
  # the (user, historyId) pair if it is ever missing so we still dedupe.
  defp gmail_webhook_dedupe_key(message_id, _user_id, _history_id)
       when is_binary(message_id) and message_id != "" do
    "gmail_webhook:#{message_id}"
  end

  defp gmail_webhook_dedupe_key(_message_id, user_id, history_id) do
    "gmail_webhook:#{user_id}:#{history_id}"
  end

  defp get_pubsub_topic do
    Application.get_env(:maraithon, :google, [])
    |> Keyword.get(:pubsub_topic, "")
  end

  defp api_base_url do
    Application.get_env(:maraithon, :gmail, [])
    |> Keyword.get(:api_base_url, @default_api_base)
  end

  # ===========================================================================
  # CRM ingestion
  # ===========================================================================

  @doc """
  Fan a list of parsed Gmail messages into `Crm.Ingest.observe/2` calls.

  Used by the webhook handler and by the backfill seed.
  """
  def ingest_messages(user_id, messages) when is_binary(user_id) and is_list(messages) do
    user_email = String.downcase(user_id)

    Enum.each(messages, fn message ->
      case to_observation(message, user_id, user_email) do
        {:ok, changeset} ->
          result = Ingest.observe(user_id, changeset)

          case result do
            {:ok, _} ->
              :ok

            {:ok, _, _} ->
              :ok

            {:ok, _, _, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("CRM ingest skipped a Gmail message",
                user_id: user_id,
                source_item_id: message[:message_id],
                reason: inspect(reason)
              )

            other ->
              Logger.warning("CRM ingest unexpected result for Gmail message",
                user_id: user_id,
                source_item_id: message[:message_id],
                result: inspect(other)
              )
          end

        :skip ->
          :ok
      end
    end)

    case Ingest.flush_pending(user_id, "gmail") do
      {:error, reason} ->
        Logger.warning("CRM ingest could not flush Gmail observations",
          user_id: user_id,
          reason: inspect(reason)
        )

      _result ->
        :ok
    end

    :ok
  end

  def ingest_messages(_user_id, _messages), do: :ok

  defp to_observation(message, user_id, user_email) when is_map(message) do
    case Map.get(message, :message_id) || Map.get(message, "message_id") do
      nil ->
        :skip

      message_id ->
        from_value = Map.get(message, :from) || Map.get(message, "from")
        to_value = Map.get(message, :to) || Map.get(message, "to")
        cc_value = Map.get(message, :cc) || Map.get(message, "cc")

        from_participants = parse_address_list(from_value, :from)
        to_participants = parse_address_list(to_value, :to)
        cc_participants = parse_address_list(cc_value, :cc)

        participants =
          (from_participants ++ to_participants ++ cc_participants)
          |> Enum.uniq_by(& &1["identifier"])

        if participants == [] do
          :skip
        else
          direction = direction_for(participants, user_email)

          occurred_at =
            Map.get(message, :internal_date) || Map.get(message, "internal_date") ||
              DateTime.utc_now()

          {:ok,
           Observation.new(%{
             "user_id" => user_id,
             "source" => "gmail",
             "source_account" => user_email,
             "source_item_id" => to_string(message_id),
             "occurred_at" => occurred_at,
             "direction" => Atom.to_string(direction),
             "participants" => participants,
             "subject" => Map.get(message, :subject) || Map.get(message, "subject"),
             "excerpt" => Map.get(message, :snippet) || Map.get(message, "snippet"),
             "metadata" => %{
               "thread_id" => Map.get(message, :thread_id) || Map.get(message, "thread_id"),
               "labels" => Map.get(message, :labels) || Map.get(message, "labels") || []
             }
           })}
        end
    end
  end

  defp to_observation(_message, _user_id, _user_email), do: :skip

  defp parse_address_list(nil, _role), do: []
  defp parse_address_list("", _role), do: []

  defp parse_address_list(raw, role) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_address(&1, role))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_address_list(_raw, _role), do: []

  defp parse_address(address, role) do
    case Regex.run(~r/^\s*(?:"?([^"<]*)"?\s*)?<([^>]+)>\s*$/, address) do
      [_, name, email] ->
        %{
          "role" => Atom.to_string(role),
          "identifier" => %{"email" => String.trim(email) |> String.downcase()},
          "display_name" => name |> String.trim() |> presence_or_nil()
        }

      _ ->
        case Regex.run(~r/^\s*([^\s<>]+@[^\s<>]+)\s*$/, address) do
          [_, email] ->
            %{
              "role" => Atom.to_string(role),
              "identifier" => %{"email" => String.downcase(email)},
              "display_name" => nil
            }

          _ ->
            nil
        end
    end
  end

  defp presence_or_nil(""), do: nil
  defp presence_or_nil(value), do: value

  defp direction_for(participants, user_email) do
    self_in_from? =
      Enum.any?(participants, fn %{"role" => role, "identifier" => identifier} ->
        role == "from" and String.downcase(Map.get(identifier, "email", "")) == user_email
      end)

    if self_in_from?, do: :outbound, else: :inbound
  end
end
