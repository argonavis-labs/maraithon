defmodule Maraithon.TelegramAssistant.ActionReconciliation do
  @moduledoc """
  Bounded, read-only observation of an approved action's external outcome.

  Identity is frozen with approval. Observation never dispatches a mutation.
  An absent result cannot prove that an expired sender has stopped or that a
  provider rejected its request. Only exact positive evidence settles success.
  """
  alias Maraithon.{ConnectedAccounts, OAuth, Repo, TelegramAssistant}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobs, PeriodicJobs}
  alias Maraithon.TelegramAssistant.PreparedAction
  alias Maraithon.TodoBrowser.Command
  alias Maraithon.Tools.GmailApiHelpers
  alias Maraithon.Connectors.GoogleCalendar

  @identity_key "_maraithon_reconciliation_identity"
  @job_type "assistant_action_reconcile"
  @types ~w(gmail_send gmail_draft_send calendar_create_event calendar_update_event calendar_cancel_event browser_interact)
  @max_checks 12

  def supported?(action), do: action.action_type in @types

  def freeze_identity(action, payload) do
    if supported?(action) do
      provider = provider(action, payload)

      account =
        case payload["account_id"] do
          id when is_integer(id) ->
            case Maraithon.Connectors.GoogleAccount.resolve(action.user_id, id) do
              {:ok, account} -> account
              _ -> nil
            end

          nil when action.action_type != "browser_interact" ->
            execution_account(action.user_id, provider)

          _ ->
            nil
        end

      identity = %{
        "version" => 1,
        "action_id" => action.id,
        "kind" => action.action_type,
        "provider" => (account && account.provider) || provider,
        "account_id" => account && account.id,
        "external_account_id" => account && account.external_account_id,
        "message_id" => mail_identity(action, payload)
      }

      Map.put(payload, @identity_key, identity)
    else
      payload
    end
  end

  def enqueue(action, opts \\ []) do
    if supported?(action) do
      BackgroundJobs.enqueue(@job_type, %{
        user_id: action.user_id,
        queue: PeriodicJobs.provider_queue(),
        partition_key: "prepared-action:#{action.id}",
        rate_limit_key: "action-reconciliation:#{action.user_id}",
        dedupe_key: "action-reconciliation:#{action.id}",
        scheduled_at:
          Keyword.get_lazy(opts, :scheduled_at, fn ->
            DateTime.add(DateTime.utc_now(), 60, :second)
          end),
        max_attempts: 3,
        payload: %{
          "action_id" => action.id,
          "conversation_id" => action.conversation_id,
          "confirmed_payload_hash" => action.payload["_maraithon_confirmed_payload_sha256"]
        }
      })
    else
      {:ok, :not_required}
    end
  end

  def execute(%BackgroundJob{} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    Execution.with_authority(job, fn ->
      with {:ok, id} <- Ecto.UUID.cast(job.payload["action_id"]),
           %PreparedAction{} = action <-
             Repo.get_by(PreparedAction, id: id, user_id: job.user_id),
           action = PreparedAction.hydrate_payload(action),
           true <- action.conversation_id == job.payload["conversation_id"],
           true <-
             action.payload["_maraithon_confirmed_payload_sha256"] ==
               job.payload["confirmed_payload_hash"],
           checks when is_integer(checks) and checks in 0..@max_checks <-
             (job.result || %{})["checks"] || 0 do
        if checks == @max_checks do
          finish_check(action, {:ok, %{state: "needs_review", checks: checks}})
        else
          reconcile_check(action, checks)
        end
      else
        nil -> {:ok, %{state: "action_removed"}}
        _ -> {:error, {:discard, :reconciliation_binding_mismatch}}
      end
    end)
  end

  defp reconcile_check(action, checks) do
    result =
      case TelegramAssistant.reconcile_prepared_action(action) do
        {:ok, _action, state} -> {:ok, %{state: to_string(state), checks: checks + 1}}
        {:pending, reason} -> pending(checks, reason)
        {:error, reason} -> pending(checks, reason)
      end

    finish_check(action, result)
  end

  defp finish_check(action, result) do
    persisted =
      if match?({:ok, %{state: "needs_review"}}, result),
        do: Maraithon.Delegations.Receipts.needs_review(action),
        else: :ok

    if action.authorization_kind == "delegation_grant",
      do: Maraithon.Delegations.Outbox.publish_pending(action.user_id)

    if persisted == :ok, do: result, else: persisted
  end

  defp pending(checks, reason) when checks + 1 < @max_checks do
    delay = min(60_000 * Integer.pow(2, min(checks, 4)), 900_000)

    {:ok,
     %{
       state: "waiting_for_evidence",
       checks: checks + 1,
       reason: Maraithon.Redaction.error_class(reason)
     }, {:reschedule_in, delay}}
  end

  defp pending(checks, reason),
    do:
      {:ok,
       %{
         state: "needs_review",
         checks: checks + 1,
         reason: Maraithon.Redaction.error_class(reason)
       }}

  def observe(action) do
    identity = action.payload[@identity_key]

    with :ok <- valid_identity(action, identity), :ok <- same_account?(action, identity) do
      case action.action_type do
        type when type in ["gmail_send", "gmail_draft_send"] ->
          observe_mail(action, identity)

        "browser_interact" ->
          observe_browser(action)

        type
        when type in ["calendar_create_event", "calendar_update_event", "calendar_cancel_event"] ->
          observe_calendar(action)

        _ ->
          {:pending, :unsupported_reconciliation}
      end
    end
  end

  # Legacy approvals retain their existing execution path, but cannot be
  # reconciled without a frozen identity. New approvals pin the provider account.
  def validate_execution_account(action) do
    case action.payload[@identity_key] do
      nil ->
        :ok

      identity ->
        with :ok <- valid_identity(action, identity),
             :ok <- same_account?(action, identity) do
          :ok
        else
          {:pending, reason} -> {:error, reason}
        end
    end
  end

  def identified?(action), do: valid_identity(action, action.payload[@identity_key]) == :ok

  defp provider(%{action_type: "gmail_send"}, payload) do
    # The direct sender uses `account`, whereas GmailDrafts accepts `provider`.
    GmailApiHelpers.provider_from_args(Map.delete(payload, "provider"))
  end

  defp provider(%{action_type: "gmail_draft_send"}, payload),
    do: GmailApiHelpers.provider_from_args(payload)

  defp provider(_, _), do: "google"

  # Google tokens are keyed per address ("google:<email>") and the connectors
  # resolve the plain "google" key to the best of them. The frozen identity
  # must name that same account, or every calendar confirm reads as an
  # account change and fails before reaching Google.
  defp execution_account(user_id, "google") do
    case OAuth.get_token(user_id, "google") do
      %{provider: provider} when is_binary(provider) ->
        ConnectedAccounts.get(user_id, provider) || ConnectedAccounts.get(user_id, "google")

      _ ->
        ConnectedAccounts.get(user_id, "google")
    end
  end

  defp execution_account(user_id, provider), do: ConnectedAccounts.get(user_id, provider)

  def message_id(action) do
    case get_in(action.payload || %{}, [@identity_key, "message_id"]) do
      id when is_binary(id) -> if valid_message_id?(id), do: id
      _ -> nil
    end
  end

  # Draft Message-IDs may predate approval. Compare frozen MIME content too,
  # so a later draft edit cannot be mistaken for the approved content.
  def draft_fingerprint(message) do
    case message["payload"] do
      %{} = payload ->
        payload
        |> mime_content()
        |> Maraithon.AssistantHarness.PromptStability.encode!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      _ ->
        nil
    end
  end

  defp mime_content(payload) do
    headers =
      (payload["headers"] || [])
      |> Enum.map(fn h -> {String.downcase(h["name"] || ""), h["value"]} end)
      |> Enum.filter(fn {name, _} -> name in ~w(to cc bcc subject message-id) end)
      |> Enum.sort()
      |> Enum.map(fn {name, value} -> [name, value] end)

    %{
      "headers" => headers,
      "mime_type" => payload["mimeType"],
      "filename" => payload["filename"],
      "body" => Map.take(payload["body"] || %{}, ~w(data attachmentId)),
      "parts" => Enum.map(payload["parts"] || [], &mime_content/1)
    }
  end

  def calendar_event_id(action_id) do
    :crypto.hash(:sha256, "calendar_create_event:" <> to_string(action_id))
    |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp mail_identity(%{action_type: "gmail_send", id: id}, _payload),
    do: "<maraithon.#{id}@maraithon.com>"

  defp mail_identity(%{action_type: "gmail_draft_send", id: id}, payload) do
    if payload["_maraithon_update_draft_before_send"] == true do
      "<maraithon.#{id}@maraithon.com>"
    else
      value = payload["_maraithon_draft_message_id"]
      if valid_message_id?(value), do: value
    end
  end

  defp mail_identity(_, _), do: nil

  defp valid_identity(action, %{"version" => 1, "action_id" => id, "kind" => kind})
       when id == action.id and kind == action.action_type,
       do: :ok

  defp valid_identity(_, _), do: {:pending, :reconciliation_identity_unavailable}

  defp same_account?(%{action_type: "browser_interact"}, _), do: :ok

  defp same_account?(action, identity) do
    account_id = identity["account_id"]
    external_id = identity["external_account_id"]

    case ConnectedAccounts.get(action.user_id, identity["provider"]) do
      %{id: ^account_id, external_account_id: ^external_id} when not is_nil(account_id) -> :ok
      _ -> {:pending, :connected_account_changed}
    end
  end

  defp observe_mail(action, identity) do
    id = identity["message_id"]

    if valid_message_id?(id) do
      args = %{
        "user_id" => action.user_id,
        "provider" => identity["provider"],
        "exact_account" => true
      }

      query = URI.encode_query(%{q: "in:sent rfc822msgid:#{id}", maxResults: 2})

      with {:ok, response} <- gmail_request(args, "/users/me/messages?" <> query),
           [%{"id" => message_id}] <- response["messages"] || [],
           true <- is_nil(response["nextPageToken"]),
           {:ok, message} <-
             gmail_request(args, "/users/me/messages/#{URI.encode(message_id)}?format=full"),
           true <- "SENT" in (message["labelIds"] || []),
           true <- header(message, "message-id") == id,
           true <- mail_headers_match?(action.payload, message),
           true <- delegated_mail_matches?(action, message),
           true <- draft_matches?(action, message) do
        {:ok,
         %{
           source: "gmail",
           message_id: message_id,
           thread_id: message["threadId"],
           message: "Verified the approved email in Sent mail.",
           reconciled: true
         }}
      else
        {:error, reason} -> {:pending, reason}
        _ -> {:pending, :sent_message_not_proven}
      end
    else
      {:pending, :message_identity_unavailable}
    end
  end

  defp draft_matches?(%{action_type: "gmail_draft_send", payload: payload}, message) do
    if payload["_maraithon_update_draft_before_send"] == true do
      true
    else
      expected = payload["_maraithon_draft_fingerprint"]
      is_binary(expected) and expected == draft_fingerprint(message)
    end
  end

  defp draft_matches?(_, _), do: true

  defp mail_headers_match?(payload, message) do
    Enum.all?([{"to", "to"}, {"subject", "subject"}, {"cc", "cc"}, {"from", "from"}], fn {key,
                                                                                          name} ->
      case payload[key] do
        value when is_binary(value) and value != "" and key != "subject" ->
          mail_addresses(header(message, name)) == mail_addresses(value)

        value when is_binary(value) and value != "" ->
          header(message, name) == value

        _ ->
          true
      end
    end)
  end

  defp mail_addresses(value) do
    Maraithon.Connectors.Gmail.message_participants(%{from: value || ""})
    |> MapSet.new(&String.downcase(&1["identifier"]["email"]))
  end

  defp delegated_mail_matches?(
         %{authorization_kind: "delegation_grant", payload: payload},
         message
       ) do
    expected_thread = payload["thread_id"]
    expected_body = payload["body"]
    actual_body = get_in(message, ["payload", "body", "data"])

    with true <- is_binary(expected_body) and is_binary(actual_body),
         {:ok, actual_body} <- Base.url_decode64(actual_body, padding: false) do
      normalize = &(&1 |> String.replace("\r\n", "\n") |> String.trim_trailing())

      (expected_thread == nil or expected_thread == message["threadId"]) and
        mail_addresses(header(message, "cc")) == mail_addresses(payload["cc"]) and
        mail_addresses(header(message, "bcc")) == MapSet.new() and
        normalize.(expected_body) == normalize.(actual_body)
    else
      _ -> false
    end
  end

  defp delegated_mail_matches?(_, _), do: true

  defp header(message, name) do
    (get_in(message, ["payload", "headers"]) || [])
    |> Enum.find_value(fn h -> if String.downcase(h["name"] || "") == name, do: h["value"] end)
  end

  defp observe_calendar(action) do
    id =
      if action.action_type == "calendar_create_event",
        do: calendar_event_id(action.id),
        else: action.payload["event_id"]

    case calendar_get(action, id) do
      {:ok, event} ->
        if calendar_matches?(action, id, event) do
          {:ok,
           %{
             source: "google_calendar",
             event_id: id,
             event: %{event_id: id},
             message: "Verified the approved calendar change.",
             reconciled: true
           }}
        else
          {:pending, :calendar_change_not_proven}
        end

      {:error, :event_gone} when action.action_type == "calendar_cancel_event" ->
        {:ok,
         %{
           source: "google_calendar",
           event_id: id,
           message: "Verified that the calendar event is gone.",
           reconciled: true
         }}

      {:error, reason} ->
        {:pending, reason}
    end
  end

  defp calendar_matches?(action, id, event) do
    private = event[:private_properties] || %{}

    owned =
      event[:event_id] == id and private["maraithon_managed"] == "true" and
        (action.payload["todo_id"] || "") == (private["maraithon_todo_id"] || "")

    if action.action_type == "calendar_cancel_event" do
      owned and event[:status] == "cancelled"
    else
      owned and event[:status] != "cancelled" and
        calendar_attendees_match?(action, event) and
        (action.action_type != "calendar_create_event" or private["maraithon_client_key"] == id) and
        Enum.all?(
          [
            {"title", :summary},
            {"description", :description},
            {"start_at", :start},
            {"end_at", :end}
          ],
          fn {key, field} ->
            case action.payload[key] do
              nil -> true
              value when field in [:start, :end] -> same_instant?(value, event[field])
              value -> value == event[field]
            end
          end
        )
    end
  end

  defp calendar_attendees_match?(%{payload: %{"attendees" => expected}}, event)
       when is_list(expected) do
    actual = Enum.map(event[:attendees] || [], & &1[:email])
    normalize = fn emails -> MapSet.new(emails, &String.downcase/1) end
    Enum.all?(actual, &is_binary/1) and normalize.(actual) == normalize.(expected)
  end

  defp calendar_attendees_match?(%{authorization_kind: "delegation_grant"}, _), do: false
  defp calendar_attendees_match?(_, _), do: true

  defp same_instant?(left, %DateTime{} = right),
    do: same_instant?(left, DateTime.to_iso8601(right))

  defp same_instant?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, l, _} <- DateTime.from_iso8601(left),
         {:ok, r, _} <- DateTime.from_iso8601(right) do
      DateTime.compare(l, r) == :eq
    else
      _ -> false
    end
  end

  defp same_instant?(_, _), do: false

  defp observe_browser(action) do
    payload = action.payload

    case Repo.get_by(Command, id: action.id, user_id: action.user_id, todo_id: payload["todo_id"]) do
      %Command{status: "completed", result: result} = command when is_map(result) ->
        if not Map.has_key?(result, "error") and result["error_class"] != "ambiguous" and
             command.operation == payload["operation"] and
             command.payload == Map.take(payload, ~w(url element_id label text)) do
          {:ok,
           %{
             source: "browser",
             command_id: command.id,
             reconciled: true,
             message: "Verified the completed browser command."
           }}
        else
          {:pending, :browser_command_mismatch}
        end

      _ ->
        {:pending, :browser_result_not_proven}
    end
  end

  defp valid_message_id?(id) when is_binary(id),
    do:
      byte_size(id) <= 255 and
        Regex.match?(~r/^<[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9.-]+>$/, id)

  defp valid_message_id?(_), do: false

  defp gmail_request(args, path) do
    case config()[:gmail_request] do
      fun when is_function(fun, 2) -> fun.(args, path)
      _ -> GmailApiHelpers.request(args, :get, path)
    end
  end

  defp calendar_get(%{authorization_kind: "delegation_grant"} = action, id) do
    case action.payload["account_id"] do
      account_id when is_integer(account_id) ->
        GoogleCalendar.get_event(action.user_id, id, account_id: account_id)

      _ ->
        {:error, :invalid_calendar_account}
    end
  end

  defp calendar_get(%{user_id: user_id} = action, id) do
    case config()[:calendar_get] do
      fun when is_function(fun, 2) -> fun.(user_id, id)
      _ -> GoogleCalendar.get_event(user_id, id, account_id: action.payload["account_id"])
    end
  end

  defp config, do: Application.get_env(:maraithon, __MODULE__, [])
end
