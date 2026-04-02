defmodule Maraithon.ChiefOfStaff.Acquisition do
  @moduledoc """
  Assistant-owned source acquisition for one Chief of Staff cycle.
  """

  alias Maraithon.ChiefOfStaff.{Skills, SourceBundle, SourceScope}
  alias Maraithon.ConnectedAccounts

  require Logger

  @default_gmail_message_limit 60
  @default_calendar_limit 24
  @default_lookback_hours 24 * 14
  @default_forward_days 14

  def build(user_id, skill_ids, skill_configs, context)
      when is_binary(user_id) and is_list(skill_ids) and is_map(skill_configs) and is_map(context) do
    source_scope = resolve_source_scope(user_id, skill_ids, skill_configs)
    bundle = SourceBundle.empty(context, source_scope)
    plan = build_plan(skill_ids, skill_configs, context)

    {bundle, telemetry} =
      {%{"fetches" => [], "sources" => %{}, "plan" => plan}, bundle}
      |> maybe_fetch_gmail(user_id, source_scope, plan, context)
      |> maybe_fetch_calendar(user_id, source_scope, plan, context)
      |> then(fn {telemetry, bundle} -> {bundle, telemetry} end)

    {bundle, telemetry}
  end

  def build(_user_id, _skill_ids, _skill_configs, context) when is_map(context) do
    bundle = SourceBundle.empty(context, %{})

    {bundle,
     %{
       "fetches" => [],
       "sources" => %{},
       "plan" => %{}
     }}
  end

  defp maybe_fetch_gmail({telemetry, bundle}, _user_id, _source_scope, %{gmail: false}, _context),
    do: {telemetry, bundle}

  defp maybe_fetch_gmail({telemetry, bundle}, user_id, source_scope, plan, context) do
    case event_gmail_messages(context, source_scope) do
      {:ok, %{messages: messages, providers: providers}} ->
        bundle =
          SourceBundle.put_gmail(bundle, %{
            "messages" => messages,
            "inbox_messages" => filter_messages_by_label(messages, "INBOX", plan.inbox_limit),
            "sent_messages" => filter_messages_by_label(messages, "SENT", plan.sent_limit),
            "messages_by_provider" => group_messages_by_provider(messages),
            "providers" => providers,
            "metadata" => %{"mode" => "event"},
            "status" => "ready",
            "fetched_at" => context[:timestamp] || DateTime.utc_now()
          })

        telemetry =
          put_source_summary(telemetry, "gmail", %{
            "mode" => "event",
            "providers" => providers,
            "message_count" => length(messages)
          })

        {telemetry, bundle}

      :fallback ->
        fetch_gmail_from_sources(telemetry, bundle, user_id, source_scope, plan, context)
    end
  end

  defp maybe_fetch_calendar(
         {telemetry, bundle},
         _user_id,
         _source_scope,
         %{calendar: false},
         _context
       ),
       do: {telemetry, bundle}

  defp maybe_fetch_calendar({telemetry, bundle}, user_id, source_scope, plan, context) do
    case event_calendar_events(context) do
      {:ok, events} ->
        bundle =
          SourceBundle.put_calendar(bundle, %{
            "events" => Enum.take(events, plan.calendar_limit),
            "events_by_provider" => group_events_by_provider(events),
            "providers" => event_calendar_providers(events),
            "metadata" => %{"mode" => "event"},
            "status" => "ready",
            "fetched_at" => context[:timestamp] || DateTime.utc_now()
          })

        telemetry =
          put_source_summary(telemetry, "calendar", %{
            "mode" => "event",
            "providers" => event_calendar_providers(events),
            "event_count" => length(events)
          })

        {telemetry, bundle}

      :fallback ->
        fetch_calendar_from_sources(telemetry, bundle, user_id, source_scope, plan, context)
    end
  end

  defp fetch_gmail_from_sources(telemetry, bundle, user_id, source_scope, plan, context) do
    providers = SourceScope.google_account_providers(source_scope, "gmail")

    if providers == [] do
      bundle = SourceBundle.mark_unavailable(bundle, "gmail", "google_gmail_not_connected")
      {put_source_summary(telemetry, "gmail", %{"status" => "unavailable"}), bundle}
    else
      lookback_days = max(div(plan.lookback_hours, 24), 1)
      query = "newer_than:#{lookback_days}d"

      {messages_by_provider, fetches} =
        Enum.reduce(providers, {%{}, telemetry["fetches"]}, fn provider,
                                                               {message_acc, fetch_acc} ->
          case gmail_module().fetch_messages(user_id,
                 max_results: plan.gmail_message_limit,
                 label_ids: [],
                 query: query,
                 provider: provider
               ) do
            {:ok, messages} ->
              annotated = annotate_google_items(messages, source_scope, provider)

              {
                Map.put(message_acc, provider, annotated),
                [
                  %{
                    "source" => "gmail",
                    "provider" => provider,
                    "mode" => "connector",
                    "status" => "ok",
                    "count" => length(annotated)
                  }
                  | fetch_acc
                ]
              }

            {:error, reason} ->
              ConnectedAccounts.report_access_issue(user_id, provider, reason)

              Logger.warning("ChiefOfStaff acquisition failed to fetch Gmail",
                user_id: user_id,
                provider: provider,
                reason: inspect(reason)
              )

              {
                message_acc,
                [
                  %{
                    "source" => "gmail",
                    "provider" => provider,
                    "mode" => "connector",
                    "status" => "error",
                    "reason" => inspect(reason)
                  }
                  | fetch_acc
                ]
              }
          end
        end)

      messages =
        messages_by_provider
        |> Map.values()
        |> List.flatten()
        |> sort_messages()
        |> Enum.take(plan.gmail_message_limit)

      status = if messages == [], do: "partial", else: "ready"

      bundle =
        SourceBundle.put_gmail(bundle, %{
          "messages" => messages,
          "inbox_messages" => filter_messages_by_label(messages, "INBOX", plan.inbox_limit),
          "sent_messages" => filter_messages_by_label(messages, "SENT", plan.sent_limit),
          "messages_by_provider" => messages_by_provider,
          "providers" => providers,
          "metadata" => %{"mode" => "connector", "query" => query},
          "status" => status,
          "fetched_at" => context[:timestamp] || DateTime.utc_now()
        })

      telemetry =
        telemetry
        |> Map.put("fetches", fetches)
        |> put_source_summary("gmail", %{
          "mode" => "connector",
          "status" => status,
          "providers" => providers,
          "message_count" => length(messages)
        })

      {telemetry, bundle}
    end
  end

  defp fetch_calendar_from_sources(telemetry, bundle, user_id, source_scope, plan, context) do
    providers = SourceScope.google_account_providers(source_scope, "calendar")

    if providers == [] do
      bundle = SourceBundle.mark_unavailable(bundle, "calendar", "google_calendar_not_connected")
      {put_source_summary(telemetry, "calendar", %{"status" => "unavailable"}), bundle}
    else
      time_min =
        (context[:timestamp] || DateTime.utc_now())
        |> DateTime.add(-plan.lookback_hours, :hour)
        |> DateTime.to_iso8601()

      time_max =
        (context[:timestamp] || DateTime.utc_now())
        |> DateTime.add(plan.forward_days, :day)
        |> DateTime.to_iso8601()

      {events_by_provider, fetches} =
        Enum.reduce(providers, {%{}, telemetry["fetches"]}, fn provider, {event_acc, fetch_acc} ->
          case calendar_module().list_events(user_id,
                 max_results: plan.calendar_limit,
                 time_min: time_min,
                 time_max: time_max,
                 provider: provider
               ) do
            {:ok, events} ->
              annotated = annotate_google_items(events, source_scope, provider)

              {
                Map.put(event_acc, provider, annotated),
                [
                  %{
                    "source" => "calendar",
                    "provider" => provider,
                    "mode" => "connector",
                    "status" => "ok",
                    "count" => length(annotated)
                  }
                  | fetch_acc
                ]
              }

            {:error, reason} ->
              ConnectedAccounts.report_access_issue(user_id, provider, reason)

              Logger.warning("ChiefOfStaff acquisition failed to fetch calendar",
                user_id: user_id,
                provider: provider,
                reason: inspect(reason)
              )

              {
                event_acc,
                [
                  %{
                    "source" => "calendar",
                    "provider" => provider,
                    "mode" => "connector",
                    "status" => "error",
                    "reason" => inspect(reason)
                  }
                  | fetch_acc
                ]
              }
          end
        end)

      events =
        events_by_provider
        |> Map.values()
        |> List.flatten()
        |> sort_events()
        |> Enum.take(plan.calendar_limit)

      status = if events == [], do: "partial", else: "ready"

      bundle =
        SourceBundle.put_calendar(bundle, %{
          "events" => events,
          "events_by_provider" => events_by_provider,
          "providers" => providers,
          "metadata" => %{"mode" => "connector", "time_min" => time_min, "time_max" => time_max},
          "status" => status,
          "fetched_at" => context[:timestamp] || DateTime.utc_now()
        })

      telemetry =
        telemetry
        |> Map.put("fetches", fetches)
        |> put_source_summary("calendar", %{
          "mode" => "connector",
          "status" => status,
          "providers" => providers,
          "event_count" => length(events)
        })

      {telemetry, bundle}
    end
  end

  defp build_plan(skill_ids, skill_configs, context) do
    requirements =
      skill_ids
      |> Skills.requirements()
      |> Enum.map(&stringify_keys/1)

    event_source = event_source(context)

    max_email_scan_limit =
      max_skill_integer(skill_ids, skill_configs, "email_scan_limit", 14)

    max_event_scan_limit =
      max_skill_integer(skill_ids, skill_configs, "event_scan_limit", 12)

    max_lookback_hours =
      max_skill_integer(skill_ids, skill_configs, "lookback_hours", @default_lookback_hours)

    %{
      gmail:
        service_required?(requirements, "google", "gmail") and
          event_allows_source?(event_source, "gmail"),
      calendar:
        service_required?(requirements, "google", "calendar") and
          event_allows_source?(event_source, "google_calendar"),
      slack: service_required?(requirements, "slack", nil),
      web_context: morning_brief_trigger?(skill_ids, context),
      inbox_limit: max(max_email_scan_limit, 10),
      sent_limit: max(max_email_scan_limit * 2, 12),
      gmail_message_limit: max(max_email_scan_limit * 4, @default_gmail_message_limit),
      calendar_limit: max(max_event_scan_limit * 2, @default_calendar_limit),
      lookback_hours: max(max_lookback_hours, 24),
      forward_days: @default_forward_days
    }
  end

  defp resolve_source_scope(user_id, skill_ids, skill_configs) do
    configured_scope =
      skill_ids
      |> Enum.map(fn skill_id ->
        skill_configs
        |> Map.get(skill_id, %{})
        |> Map.get("source_scope")
      end)
      |> Enum.find(&is_map/1)

    live_scope = SourceScope.resolve(user_id)

    if SourceScope.google_accounts(live_scope) == [] and
         SourceScope.slack_workspaces(live_scope) == [] do
      SourceScope.normalize(configured_scope || %{})
    else
      live_scope
    end
  end

  defp event_gmail_messages(context, source_scope) do
    payload = get_in(context, [:event, :payload])
    source = payload_source(payload)

    if source == "gmail" do
      messages =
        payload
        |> payload_data()
        |> Map.get("messages", [])
        |> annotate_event_messages(source_scope, context)

      {:ok,
       %{
         messages: messages,
         providers:
           messages
           |> Enum.map(&Map.get(&1, "google_provider"))
           |> Enum.filter(&is_binary/1)
           |> Enum.uniq()
       }}
    else
      :fallback
    end
  end

  defp event_calendar_events(context) do
    payload = get_in(context, [:event, :payload])
    source = payload_source(payload)

    if source == "google_calendar" do
      events =
        payload
        |> payload_data()
        |> Map.get("events", [])
        |> Enum.map(&stringify_keys/1)

      {:ok, events}
    else
      :fallback
    end
  end

  defp annotate_event_messages(messages, source_scope, context) when is_list(messages) do
    google_source =
      case get_in(context, [:event, :topic]) do
        "email:" <> account_email ->
          SourceScope.google_account_for_email(source_scope, account_email)

        _ ->
          nil
      end

    provider = account_provider(google_source)
    account_email = account_email(google_source)

    Enum.map(messages, fn message ->
      message
      |> stringify_keys()
      |> maybe_put("google_provider", provider)
      |> maybe_put("account", account_email)
    end)
  end

  defp annotate_event_messages(_messages, _source_scope, _context), do: []

  defp payload_source(payload) when is_map(payload) do
    payload
    |> stringify_keys()
    |> Map.get("source")
  end

  defp payload_source(_payload), do: nil

  defp payload_data(payload) when is_map(payload) do
    payload
    |> stringify_keys()
    |> Map.get("data", %{})
    |> stringify_keys()
  end

  defp payload_data(_payload), do: %{}

  defp event_source(context) do
    payload_source(get_in(context, [:event, :payload]))
  end

  defp morning_brief_trigger?(skill_ids, context) do
    "briefing" in skill_ids and
      get_in(context, [:trigger, :type]) == :wakeup and
      is_nil(get_in(context, [:event, :payload]))
  end

  defp service_required?(requirements, provider, service) do
    Enum.any?(requirements, fn requirement ->
      requirement["provider"] == provider and
        (service == nil or requirement["service"] == service)
    end)
  end

  defp event_allows_source?(nil, _source), do: true
  defp event_allows_source?("gmail", "gmail"), do: true
  defp event_allows_source?("google_calendar", "google_calendar"), do: true
  defp event_allows_source?(source, _expected) when is_binary(source), do: false
  defp event_allows_source?(_source, _expected), do: true

  defp max_skill_integer(skill_ids, skill_configs, key, default) do
    skill_ids
    |> Enum.map(fn skill_id ->
      skill_configs
      |> Map.get(skill_id, %{})
      |> Map.get(key)
      |> parse_integer()
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> default
      values -> Enum.max(values)
    end
  end

  defp annotate_google_items(items, source_scope, provider) when is_list(items) do
    google_source = SourceScope.google_account_for_provider(source_scope, provider)
    account_email = account_email(google_source)

    Enum.map(items, fn item ->
      item
      |> stringify_keys()
      |> maybe_put("google_provider", provider)
      |> maybe_put("account", account_email)
    end)
  end

  defp annotate_google_items(_items, _source_scope, _provider), do: []

  defp group_messages_by_provider(messages) when is_list(messages) do
    Enum.group_by(messages, &Map.get(&1, "google_provider", "unknown"))
  end

  defp group_events_by_provider(events) when is_list(events) do
    Enum.group_by(events, &Map.get(&1, "google_provider", "unknown"))
  end

  defp filter_messages_by_label(messages, label, limit) when is_list(messages) do
    messages
    |> Enum.filter(fn message ->
      message
      |> Map.get("labels", [])
      |> Enum.any?(&(to_string(&1) == label))
    end)
    |> Enum.take(limit)
  end

  defp filter_messages_by_label(_messages, _label, _limit), do: []

  defp event_calendar_providers(events) when is_list(events) do
    events
    |> Enum.map(&Map.get(&1, "google_provider"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp sort_messages(messages) when is_list(messages) do
    Enum.sort_by(messages, &message_sort_key/1, :desc)
  end

  defp sort_events(events) when is_list(events) do
    Enum.sort_by(events, &event_sort_key/1, :asc)
  end

  defp message_sort_key(%{"internal_date" => %DateTime{} = value}),
    do: DateTime.to_unix(value, :microsecond)

  defp message_sort_key(_message), do: 0

  defp event_sort_key(%{"start" => %DateTime{} = value}),
    do: DateTime.to_unix(value, :microsecond)

  defp event_sort_key(%{"start" => %{"date" => value}}) when is_binary(value), do: value
  defp event_sort_key(_event), do: 0

  defp put_source_summary(telemetry, source, summary) do
    Map.update(telemetry, "sources", %{source => summary}, &Map.put(&1, source, summary))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(%_{} = struct), do: struct

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_map(value) -> {to_string(key), stringify_keys(value)}
      {key, value} when is_list(value) -> {to_string(key), Enum.map(value, &stringify_keys/1)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_keys(value), do: value

  defp parse_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp gmail_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:gmail_module, Maraithon.Connectors.Gmail)
  end

  defp calendar_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:calendar_module, Maraithon.Tools.GoogleCalendarHelpers)
  end

  defp account_provider(%{"provider" => provider}) when is_binary(provider), do: provider
  defp account_provider(_source), do: nil

  defp account_email(%{"account_email" => account_email}) when is_binary(account_email),
    do: account_email

  defp account_email(_source), do: nil
end
