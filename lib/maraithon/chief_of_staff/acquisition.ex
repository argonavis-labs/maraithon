defmodule Maraithon.ChiefOfStaff.Acquisition do
  @moduledoc """
  Assistant-owned source acquisition for one Chief of Staff cycle.
  """

  alias Maraithon.ChiefOfStaff.{Skills, SourceBundle, SourceScope}
  alias Maraithon.ConnectedAccounts
  alias Maraithon.News
  alias Maraithon.OAuth
  alias Maraithon.Tools.SlackHelpers

  require Logger

  @default_gmail_message_limit 250
  @default_calendar_limit 250
  @default_slack_channel_limit 12
  @default_slack_message_limit 100
  @default_lookback_hours 24 * 14
  @default_timezone_offset_hours -5
  @commercial_gmail_lookback_days 7
  @commercial_gmail_query_limit 5
  @commercial_gmail_queries [
    "newer_than:7d Cogniate",
    "newer_than:7d Glossier",
    "newer_than:7d \"team plan\"",
    "newer_than:7d \"Ultra plan\"",
    "newer_than:7d Enterprise",
    "newer_than:7d discount",
    "newer_than:7d intro",
    "newer_than:7d availability"
  ]
  @default_forward_days 14
  @default_slack_key_channels [
    "runner-general",
    "runner-leads",
    "runner-gtm",
    "runner-user-feedback",
    "gtm-leads",
    "general",
    "eng-general",
    "exec-agora-gov-mgmt-w-dash",
    "jeff",
    "charlie",
    "yitong"
  ]

  def build(user_id, skill_ids, skill_configs, context)
      when is_binary(user_id) and is_list(skill_ids) and is_map(skill_configs) and is_map(context) do
    source_scope = resolve_source_scope(user_id, skill_ids, skill_configs)
    bundle = SourceBundle.empty(context, source_scope)
    plan = build_plan(skill_ids, skill_configs, context)

    {bundle, telemetry} =
      {%{"fetches" => [], "sources" => %{}, "plan" => plan}, bundle}
      |> maybe_fetch_gmail(user_id, source_scope, plan, context)
      |> maybe_fetch_calendar(user_id, source_scope, plan, context)
      |> maybe_fetch_slack(user_id, source_scope, plan, context)
      |> maybe_fetch_news(user_id, source_scope, plan, context)
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
        messages = enrich_gmail_messages(messages, user_id, nil)

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
            "message_count" => length(messages),
            "full_body_count" => count_full_body_messages(messages),
            "body_missing_count" => count_body_missing_messages(messages)
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
            "events" => events,
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

  defp maybe_fetch_slack({telemetry, bundle}, _user_id, _source_scope, %{slack: false}, _context),
    do: {telemetry, bundle}

  defp maybe_fetch_slack({telemetry, bundle}, user_id, source_scope, plan, context) do
    team_ids = SourceScope.slack_team_ids(source_scope)

    if team_ids == [] do
      bundle = SourceBundle.mark_unavailable(bundle, "slack", "slack_workspace_not_connected")
      {put_source_summary(telemetry, "slack", %{"status" => "unavailable"}), bundle}
    else
      oldest =
        (context[:timestamp] || DateTime.utc_now())
        |> DateTime.add(-min(plan.lookback_hours, 24), :hour)
        |> DateTime.to_unix(:second)
        |> Integer.to_string()

      {workspaces, fetches} =
        Enum.reduce(team_ids, {[], telemetry["fetches"]}, fn team_id,
                                                             {workspace_acc, fetch_acc} ->
          case fetch_slack_workspace(user_id, source_scope, team_id, plan, oldest) do
            {:ok, workspace, workspace_fetches} ->
              {[workspace | workspace_acc], workspace_fetches ++ fetch_acc}

            {:error, reason, workspace_fetches} ->
              ConnectedAccounts.report_access_issue(user_id, "slack:#{team_id}", reason)

              Logger.warning("ChiefOfStaff acquisition failed to fetch Slack",
                user_id: user_id,
                team_id: team_id,
                reason: inspect(reason)
              )

              {workspace_acc,
               [
                 %{
                   "source" => "slack",
                   "team_id" => team_id,
                   "mode" => "connector",
                   "status" => "error",
                   "reason" => inspect(reason)
                 }
                 | workspace_fetches ++ fetch_acc
               ]}
          end
        end)

      messages =
        workspaces
        |> Enum.flat_map(&slack_workspace_messages/1)

      status = if workspaces == [], do: "partial", else: "ready"

      bundle =
        SourceBundle.put_slack(bundle, %{
          "workspaces" => Enum.reverse(workspaces),
          "mentions" => slack_mentions_from_workspaces(workspaces),
          "providers" => team_ids,
          "metadata" => %{"mode" => "connector", "oldest" => oldest},
          "status" => status,
          "fetched_at" => context[:timestamp] || DateTime.utc_now()
        })

      telemetry =
        telemetry
        |> Map.put("fetches", fetches)
        |> put_source_summary("slack", %{
          "mode" => "connector",
          "status" => status,
          "teams" => team_ids,
          "workspace_count" => length(workspaces),
          "message_count" => length(messages)
        })

      {telemetry, bundle}
    end
  end

  defp maybe_fetch_news({telemetry, bundle}, _user_id, _source_scope, %{news: false}, _context),
    do: {telemetry, bundle}

  defp maybe_fetch_news({telemetry, bundle}, _user_id, _source_scope, plan, context) do
    now = context[:timestamp] || DateTime.utc_now()

    case news_module().fetch_for_brief(Map.get(plan, :news_config, %{}), now) do
      {:ok, %{} = result} ->
        bundle =
          SourceBundle.put_news(bundle, %{
            "items" => Map.get(result, "items", []),
            "feeds" => Map.get(result, "feeds", []),
            "providers" => Map.get(result, "feeds", []),
            "metadata" => %{"mode" => "rss"},
            "status" => Map.get(result, "status", "ready"),
            "fetched_at" => Map.get(result, "fetched_at", DateTime.to_iso8601(now))
          })

        fetches = Map.get(result, "fetches", [])

        telemetry =
          telemetry
          |> Map.update("fetches", fetches, &(fetches ++ &1))
          |> put_source_summary("news", %{
            "mode" => "rss",
            "status" => Map.get(result, "status", "ready"),
            "feed_count" => length(Map.get(result, "feeds", [])),
            "item_count" => length(Map.get(result, "items", []))
          })

        {telemetry, bundle}

      {:error, reason} ->
        bundle = SourceBundle.mark_unavailable(bundle, "news", inspect(reason))

        telemetry =
          put_source_summary(telemetry, "news", %{
            "mode" => "rss",
            "status" => "error",
            "reason" => inspect(reason)
          })

        {telemetry, bundle}
    end
  end

  defp fetch_slack_workspace(user_id, source_scope, team_id, plan, oldest) do
    with {:ok, token} <-
           SlackHelpers.resolve_access_token(user_id, team_id, token_preference: "auto"),
         {:ok, response} <-
           slack_module().list_conversations(token.access_token,
             types: ["public_channel", "private_channel", "mpim", "im"],
             limit: max(plan.slack_channel_limit * 10, 200),
             exclude_archived: true
           ) do
      workspace = SourceScope.slack_workspace_for_team(source_scope, team_id) || %{}

      key_channels =
        response
        |> Map.get("channels", [])
        |> normalize_list()
        |> Enum.filter(&key_slack_channel?(&1, plan.slack_key_channels))
        |> Enum.sort_by(&slack_channel_priority(&1, plan.slack_key_channels))
        |> Enum.take(plan.slack_channel_limit)

      {channels, fetches} =
        Enum.reduce(key_channels, {[], []}, fn channel, {channel_acc, fetch_acc} ->
          channel_id = channel["id"]

          case slack_module().get_conversation_history(token.access_token, channel_id,
                 limit: plan.slack_message_limit,
                 oldest: oldest
               ) do
            {:ok, history} ->
              messages =
                history
                |> Map.get("messages", [])
                |> normalize_list()
                |> Enum.map(&serialize_slack_message(&1, channel, team_id, workspace))

              channel_payload =
                channel
                |> serialize_slack_channel()
                |> Map.put("messages", messages)

              {
                [channel_payload | channel_acc],
                [
                  %{
                    "source" => "slack",
                    "team_id" => team_id,
                    "channel_id" => channel_id,
                    "mode" => "connector",
                    "status" => "ok",
                    "count" => length(messages)
                  }
                  | fetch_acc
                ]
              }

            {:error, reason} ->
              {
                channel_acc,
                [
                  %{
                    "source" => "slack",
                    "team_id" => team_id,
                    "channel_id" => channel_id,
                    "mode" => "connector",
                    "status" => "error",
                    "reason" => inspect(reason)
                  }
                  | fetch_acc
                ]
              }
          end
        end)

      {mentions, mention_fetches} =
        fetch_slack_mentions(user_id, team_id, workspace, plan, oldest)

      workspace_payload = %{
        "team_id" => team_id,
        "team_name" => Map.get(workspace, "team_name"),
        "key_channels" => Enum.reverse(channels),
        "mentions" => mentions,
        "metadata" => %{"token_provider" => token.provider}
      }

      {:ok, workspace_payload, mention_fetches ++ fetches}
    else
      {:error, reason} -> {:error, reason, []}
    end
  end

  defp fetch_slack_mentions(user_id, team_id, workspace, plan, oldest) do
    user_ids = slack_user_ids_for_team(user_id, team_id)
    oldest_date = slack_search_after_date(oldest)

    user_ids
    |> Enum.take(3)
    |> Enum.reduce({[], []}, fn slack_user_id, {mention_acc, fetch_acc} ->
      query = "<@#{slack_user_id}> after:#{oldest_date}"

      with {:ok, token} <-
             SlackHelpers.resolve_access_token(user_id, team_id,
               token_preference: "user",
               slack_user_id: slack_user_id
             ),
           {:ok, response} <-
             slack_module().search_messages(token.access_token, query,
               count: plan.slack_message_limit,
               sort: "timestamp",
               sort_dir: "desc"
             ) do
        matches =
          response
          |> get_in(["messages", "matches"])
          |> normalize_list()
          |> Enum.map(&serialize_slack_match(&1, team_id, workspace))

        {
          mention_acc ++ matches,
          [
            %{
              "source" => "slack",
              "team_id" => team_id,
              "mode" => "mention_search",
              "status" => "ok",
              "slack_user_id" => slack_user_id,
              "count" => length(matches)
            }
            | fetch_acc
          ]
        }
      else
        {:error, :no_user_token} ->
          {mention_acc, fetch_acc}

        {:error, reason} ->
          {mention_acc,
           [
             %{
               "source" => "slack",
               "team_id" => team_id,
               "mode" => "mention_search",
               "status" => "error",
               "slack_user_id" => slack_user_id,
               "reason" => inspect(reason)
             }
             | fetch_acc
           ]}
      end
    end)
  end

  defp fetch_gmail_from_sources(telemetry, bundle, user_id, source_scope, plan, context) do
    providers = SourceScope.google_account_providers(source_scope, "gmail")

    if providers == [] do
      bundle = SourceBundle.mark_unavailable(bundle, "gmail", "google_gmail_not_connected")
      {put_source_summary(telemetry, "gmail", %{"status" => "unavailable"}), bundle}
    else
      lookback_days = max(div(plan.lookback_hours, 24), @commercial_gmail_lookback_days)
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
              commercial_messages = fetch_commercial_gmail_messages(user_id, provider)

              annotated =
                (messages ++ commercial_messages)
                |> dedupe_messages()
                |> annotate_google_items(source_scope, provider)
                |> enrich_gmail_messages(user_id, provider)

              {
                Map.put(message_acc, provider, annotated),
                [
                  %{
                    "source" => "gmail",
                    "provider" => provider,
                    "mode" => "connector",
                    "status" => "ok",
                    "count" => length(annotated),
                    "commercial_search_count" => length(commercial_messages),
                    "full_body_count" => count_full_body_messages(annotated),
                    "body_missing_count" => count_body_missing_messages(annotated)
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
        |> dedupe_messages()
        |> sort_messages()

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
          "message_count" => length(messages),
          "full_body_count" => count_full_body_messages(messages),
          "body_missing_count" => count_body_missing_messages(messages)
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
      reference_at = context[:timestamp] || DateTime.utc_now()

      time_min =
        plan[:calendar_time_min] ||
          reference_at
          |> DateTime.add(-plan.lookback_hours, :hour)
          |> DateTime.to_iso8601()

      time_max =
        reference_at
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

    max_slack_channel_limit =
      max_skill_integer(
        skill_ids,
        skill_configs,
        "slack_channel_scan_limit",
        @default_slack_channel_limit
      )

    max_slack_message_limit =
      max_skill_integer(
        skill_ids,
        skill_configs,
        "slack_message_scan_limit",
        @default_slack_message_limit
      )

    max_lookback_hours =
      max_skill_integer(skill_ids, skill_configs, "lookback_hours", @default_lookback_hours)

    news_config = news_config(skill_ids, skill_configs)
    morning_brief? = morning_brief_trigger?(skill_ids, context)

    %{
      gmail:
        service_required?(requirements, "google", "gmail") and
          event_allows_source?(event_source, "gmail"),
      calendar:
        service_required?(requirements, "google", "calendar") and
          event_allows_source?(event_source, "google_calendar"),
      slack: service_required?(requirements, "slack", nil),
      news: morning_brief_trigger?(skill_ids, context) and news_enabled?(news_config),
      news_config: news_config,
      web_context: morning_brief_trigger?(skill_ids, context),
      inbox_limit: max(max_email_scan_limit, 100),
      sent_limit: max(max_email_scan_limit * 2, 100),
      gmail_message_limit: max(max_email_scan_limit * 4, @default_gmail_message_limit),
      calendar_limit:
        if(morning_brief?,
          do: max(max_event_scan_limit * 10, @default_calendar_limit),
          else: max(max_event_scan_limit * 2, @default_calendar_limit)
        ),
      calendar_time_min: calendar_time_min(skill_ids, skill_configs, context, morning_brief?),
      slack_channel_limit: max_slack_channel_limit,
      slack_message_limit:
        if(morning_brief?,
          do: max(max_slack_message_limit, @default_slack_message_limit),
          else: max_slack_message_limit
        ),
      slack_key_channels: slack_key_channels(skill_ids, skill_configs),
      lookback_hours: max(max_lookback_hours, 24),
      forward_days: @default_forward_days
    }
  end

  defp news_config(skill_ids, skill_configs) do
    skill_ids
    |> Enum.map(fn skill_id -> Map.get(skill_configs, skill_id, %{}) end)
    |> Enum.reduce(%{}, fn config, acc ->
      acc
      |> maybe_put("news_enabled", Map.get(config, "news_enabled"))
      |> maybe_put("news_limit", Map.get(config, "news_limit"))
      |> maybe_merge_news_feeds(Map.get(config, "news_feeds"))
    end)
  end

  defp calendar_time_min(_skill_ids, _skill_configs, _context, false), do: nil

  defp calendar_time_min(skill_ids, skill_configs, context, true) do
    reference_at = context[:timestamp] || DateTime.utc_now()

    timezone_offset_hours =
      first_skill_integer(
        skill_ids,
        skill_configs,
        "timezone_offset_hours",
        @default_timezone_offset_hours
      )

    reference_at
    |> local_day_start_utc(timezone_offset_hours)
    |> DateTime.to_iso8601()
  end

  defp news_enabled?(%{"news_enabled" => false}), do: false
  defp news_enabled?(%{"news_enabled" => "false"}), do: false
  defp news_enabled?(%{"news_enabled" => "0"}), do: false

  defp news_enabled?(config) when is_map(config) do
    config
    |> Map.get("news_feeds", [])
    |> List.wrap()
    |> Enum.any?()
  end

  defp maybe_merge_news_feeds(config, feeds) when is_list(feeds) do
    current = Map.get(config, "news_feeds", [])
    Map.put(config, "news_feeds", Enum.uniq(current ++ feeds))
  end

  defp maybe_merge_news_feeds(config, _feeds), do: config

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
    ("briefing" in skill_ids or "morning_briefing" in skill_ids) and
      get_in(context, [:trigger, :type]) == :wakeup and
      is_nil(get_in(context, [:event, :payload]))
  end

  defp slack_key_channels(skill_ids, skill_configs) do
    configured =
      skill_ids
      |> Enum.flat_map(fn skill_id ->
        skill_configs
        |> Map.get(skill_id, %{})
        |> Map.get("slack_key_channels", [])
        |> List.wrap()
      end)
      |> Enum.map(&normalize_channel_name/1)
      |> Enum.reject(&is_nil/1)

    (@default_slack_key_channels ++ configured)
    |> Enum.map(&normalize_channel_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
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

  defp first_skill_integer(skill_ids, skill_configs, key, default) do
    skill_ids
    |> Enum.find_value(fn skill_id ->
      skill_configs
      |> Map.get(skill_id, %{})
      |> Map.get(key)
      |> parse_integer()
    end)
    |> case do
      nil -> default
      value -> value
    end
  end

  defp local_day_start_utc(%DateTime{} = reference_at, offset_hours)
       when is_integer(offset_hours) do
    reference_at
    |> DateTime.add(offset_hours, :hour)
    |> DateTime.to_date()
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(-offset_hours, :hour)
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

  defp enrich_gmail_messages(messages, user_id, default_provider)
       when is_list(messages) and is_binary(user_id) do
    messages
    |> Task.async_stream(
      fn message -> enrich_gmail_message(user_id, message, default_provider) end,
      max_concurrency: 4,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, message} -> message
      {:exit, _reason} -> %{"body_available" => false, "body_status" => "fetch_failed"}
    end)
  end

  defp enrich_gmail_messages(messages, _user_id, _default_provider) when is_list(messages),
    do: Enum.map(messages, &stringify_keys/1)

  defp enrich_gmail_messages(_messages, _user_id, _default_provider), do: []

  defp fetch_commercial_gmail_messages(user_id, provider) do
    @commercial_gmail_queries
    |> Enum.flat_map(fn query ->
      case gmail_module().fetch_messages(user_id,
             max_results: @commercial_gmail_query_limit,
             label_ids: [],
             query: query,
             provider: provider
           ) do
        {:ok, messages} ->
          messages

        {:error, reason} ->
          Logger.debug("ChiefOfStaff commercial Gmail search failed",
            user_id: user_id,
            provider: provider,
            query: query,
            reason: inspect(reason)
          )

          []
      end
    end)
    |> dedupe_messages()
  end

  defp enrich_gmail_message(user_id, message, default_provider) do
    metadata = stringify_keys(message)
    provider = Map.get(metadata, "google_provider") || default_provider
    message_id = Map.get(metadata, "message_id") || Map.get(metadata, "id")

    cond do
      gmail_body_available?(metadata) ->
        metadata
        |> Map.put("body_available", true)
        |> Map.put("body_status", "available")
        |> put_gmail_body_text()

      is_binary(provider) and provider != "" and is_binary(message_id) and message_id != "" ->
        case gmail_module().fetch_message_content(user_id, message_id, provider: provider) do
          {:ok, content} ->
            merged =
              metadata
              |> merge_gmail_content(content)
              |> maybe_put("google_provider", provider)
              |> put_gmail_body_text()

            if gmail_body_available?(merged) do
              merged
              |> Map.put("body_available", true)
              |> Map.put("body_status", "available")
            else
              merged
              |> Map.put("body_available", false)
              |> Map.put("body_status", "full_body_empty")
            end

          {:error, reason} ->
            metadata
            |> Map.put("body_available", false)
            |> Map.put("body_status", "fetch_error")
            |> Map.put("body_error", inspect(reason))
        end

      true ->
        metadata
        |> Map.put("body_available", false)
        |> Map.put("body_status", "missing_provider_or_message_id")
    end
  end

  defp merge_gmail_content(metadata, content) do
    content = stringify_keys(content)

    Map.merge(metadata, content, fn _key, original, fetched ->
      if blank_string?(fetched), do: original, else: fetched
    end)
  end

  defp put_gmail_body_text(message) do
    body =
      [
        Map.get(message, "body_text"),
        Map.get(message, "text_body"),
        Map.get(message, "html_body")
      ]
      |> Enum.find(&present_string?/1)

    maybe_put(message, "body_text", body)
  end

  defp gmail_body_available?(message) when is_map(message) do
    message
    |> put_gmail_body_text()
    |> Map.get("body_text")
    |> present_string?()
  end

  defp gmail_body_available?(_message), do: false

  defp count_full_body_messages(messages) when is_list(messages),
    do: Enum.count(messages, &gmail_body_available?/1)

  defp count_full_body_messages(_messages), do: 0

  defp count_body_missing_messages(messages) when is_list(messages) do
    Enum.count(messages, fn message ->
      is_map(message) and Map.get(message, "body_available") == false
    end)
  end

  defp count_body_missing_messages(_messages), do: 0

  defp group_messages_by_provider(messages) when is_list(messages) do
    Enum.group_by(messages, &Map.get(&1, "google_provider", "unknown"))
  end

  defp group_events_by_provider(events) when is_list(events) do
    Enum.group_by(events, &Map.get(&1, "google_provider", "unknown"))
  end

  defp filter_messages_by_label(messages, label, _limit) when is_list(messages) do
    messages
    |> Enum.filter(fn message ->
      message
      |> Map.get("labels", [])
      |> Enum.any?(&(to_string(&1) == label))
    end)
  end

  defp filter_messages_by_label(_messages, _label, _limit), do: []

  defp key_slack_channel?(channel, key_channels) when is_map(channel) and is_list(key_channels) do
    name = normalize_channel_name(channel["name"])

    cond do
      is_nil(name) -> false
      name in key_channels -> true
      String.starts_with?(name, "exec-") -> true
      String.starts_with?(name, "founders-") -> true
      channel["is_im"] == true -> true
      channel["is_mpim"] == true -> true
      true -> false
    end
  end

  defp key_slack_channel?(_channel, _key_channels), do: false

  defp serialize_slack_channel(channel) when is_map(channel) do
    %{
      "id" => channel["id"],
      "name" => channel["name"],
      "is_private" => channel["is_private"] || false,
      "is_im" => channel["is_im"] || false,
      "is_mpim" => channel["is_mpim"] || false,
      "conversation_kind" => slack_conversation_kind(channel),
      "is_member" => channel["is_member"] || false
    }
  end

  defp serialize_slack_message(message, channel, team_id, workspace) when is_map(message) do
    %{
      "team_id" => team_id,
      "team_name" => Map.get(workspace, "team_name"),
      "channel_id" => channel["id"],
      "channel_name" => channel["name"] || slack_conversation_kind(channel),
      "conversation_kind" => slack_conversation_kind(channel),
      "ts" => message["ts"],
      "thread_ts" => message["thread_ts"],
      "user" => message["user"],
      "bot_id" => message["bot_id"],
      "subtype" => message["subtype"],
      "text" => message["text"],
      "reply_count" => message["reply_count"],
      "latest_reply" => message["latest_reply"],
      "reactions" => normalize_list(message["reactions"])
    }
  end

  defp serialize_slack_match(match, team_id, workspace) when is_map(match) do
    %{
      "team_id" => team_id,
      "team_name" => Map.get(workspace, "team_name"),
      "channel_id" => get_in(match, ["channel", "id"]),
      "channel_name" => get_in(match, ["channel", "name"]),
      "ts" => match["ts"],
      "thread_ts" => match["thread_ts"],
      "user" => match["user"],
      "text" => match["text"],
      "permalink" => match["permalink"]
    }
  end

  defp slack_user_ids_for_team(user_id, team_id) do
    pattern = ~r/^slack:#{Regex.escape(team_id)}:user:([^:]+)$/

    user_id
    |> OAuth.list_user_tokens()
    |> Enum.map(& &1.provider)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn provider ->
      case Regex.run(pattern, provider, capture: :all_but_first) do
        [slack_user_id] -> [slack_user_id]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp slack_search_after_date(oldest) when is_binary(oldest) do
    with {seconds, _rest} <- Integer.parse(oldest),
         {:ok, datetime} <- DateTime.from_unix(seconds, :second) do
      datetime
      |> DateTime.to_date()
      |> Date.to_iso8601()
    else
      _ -> Date.utc_today() |> Date.to_iso8601()
    end
  end

  defp slack_search_after_date(_oldest), do: Date.utc_today() |> Date.to_iso8601()

  defp slack_workspace_messages(workspace) when is_map(workspace) do
    workspace
    |> Map.get("key_channels", [])
    |> normalize_list()
    |> Enum.flat_map(fn channel ->
      channel
      |> Map.get("messages", [])
      |> normalize_list()
    end)
  end

  defp slack_workspace_messages(_workspace), do: []

  defp slack_mentions_from_workspaces(workspaces) when is_list(workspaces) do
    workspaces
    |> Enum.flat_map(fn workspace ->
      workspace
      |> Map.get("mentions", [])
      |> normalize_list()
    end)
  end

  defp slack_channel_priority(channel, key_channels) when is_map(channel) do
    name = normalize_channel_name(channel["name"])

    cond do
      is_binary(name) and name in key_channels ->
        0

      is_binary(name) and String.starts_with?(name, "exec-") ->
        1

      is_binary(name) and String.starts_with?(name, "founders-") ->
        2

      channel["is_private"] == true and channel["is_im"] != true and channel["is_mpim"] != true ->
        3

      channel["is_im"] == true ->
        4

      channel["is_mpim"] == true ->
        5

      true ->
        6
    end
  end

  defp slack_channel_priority(_channel, _key_channels), do: 6

  defp slack_conversation_kind(%{"is_im" => true}), do: "dm"
  defp slack_conversation_kind(%{"is_mpim" => true}), do: "group_dm"
  defp slack_conversation_kind(%{"is_private" => true}), do: "private_channel"
  defp slack_conversation_kind(_channel), do: "public_channel"

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []

  defp event_calendar_providers(events) when is_list(events) do
    events
    |> Enum.map(&Map.get(&1, "google_provider"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp sort_messages(messages) when is_list(messages) do
    Enum.sort_by(messages, &message_sort_key/1, :desc)
  end

  defp dedupe_messages(messages) when is_list(messages) do
    Enum.uniq_by(messages, fn message ->
      Map.get(message, "message_id") ||
        Map.get(message, :message_id) ||
        Map.get(message, "id") ||
        Map.get(message, :id) ||
        :erlang.phash2(message)
    end)
  end

  defp sort_events(events) when is_list(events) do
    Enum.sort_by(events, &event_sort_key/1, :asc)
  end

  defp normalize_channel_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_channel_name(_value), do: nil

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

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp blank_string?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_string?(nil), do: true
  defp blank_string?(_value), do: false

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

  defp slack_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:slack_module, Maraithon.Connectors.Slack)
  end

  defp news_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:news_module, News)
  end

  defp account_provider(%{"provider" => provider}) when is_binary(provider), do: provider
  defp account_provider(_source), do: nil

  defp account_email(%{"account_email" => account_email}) when is_binary(account_email),
    do: account_email

  defp account_email(_source), do: nil
end
