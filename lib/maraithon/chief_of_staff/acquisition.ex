defmodule Maraithon.ChiefOfStaff.Acquisition do
  @moduledoc """
  Assistant-owned source acquisition for one Chief of Staff cycle.
  """

  alias Maraithon.ChiefOfStaff.{Skills, SourceBundle, SourceScope}
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm
  alias Maraithon.LocalBrowserHistory
  alias Maraithon.LocalCalendar
  alias Maraithon.LocalFiles
  alias Maraithon.LocalMessages
  alias Maraithon.LocalNotes
  alias Maraithon.LocalReminders
  alias Maraithon.LocalVoiceMemos
  alias Maraithon.News
  alias Maraithon.OAuth
  alias Maraithon.Slack.UserDirectory
  alias Maraithon.Tools.SlackHelpers

  require Logger

  @default_gmail_message_limit 250
  @default_gmail_body_fetch_limit 40
  @default_gmail_body_fetch_timeout_ms 5_000
  @default_calendar_limit 250
  @default_slack_channel_limit 12
  @default_slack_message_limit 100
  @slack_thread_fetch_limit 6
  @slack_thread_reply_limit 40
  @slack_user_directory_limit 80
  @slack_user_directory_timeout_ms 1_500
  @slack_conversations_page_limit 1_000
  @slack_self_authored_search_result_limit 50
  @slack_self_authored_search_queries [
    "\"I am going to\"",
    "\"I'm going to\"",
    "\"I will\"",
    "\"I'll\"",
    "\"I need to\"",
    "\"I have to\"",
    "\"follow up\""
  ]
  @default_lookback_hours 24 * 14
  @default_timezone_offset_hours -5
  @commercial_gmail_lookback_days 7
  @commercial_gmail_query_limit 5
  @default_forward_days 14
  @default_commercial_gmail_queries []
  @default_slack_key_channels []
  @default_local_calendar_limit 250
  @default_local_message_limit 200
  @default_local_chat_limit 100
  @default_local_voice_memo_limit 80
  @default_local_note_limit 100
  @default_local_reminder_limit 100
  @default_local_file_limit 100
  @default_local_browser_visit_limit 250

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
      |> maybe_fetch_companion_sources(user_id, plan, context)
      |> maybe_fetch_news(user_id, source_scope, plan, context)
      |> maybe_fetch_weather(user_id, source_scope, plan, context)
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
        messages = enrich_gmail_messages(messages, user_id, nil, plan)

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
        |> DateTime.add(-plan.lookback_hours, :hour)
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

      conversation_count =
        workspaces
        |> Enum.flat_map(&Map.get(&1, "channels", []))
        |> length()

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
          "conversation_count" => conversation_count,
          "message_count" => length(messages)
        })

      {telemetry, bundle}
    end
  end

  defp maybe_fetch_companion_sources({telemetry, bundle}, user_id, plan, context)
       when is_binary(user_id) do
    now = context[:timestamp] || DateTime.utc_now()
    lookback_start = DateTime.add(now, -plan.lookback_hours, :hour)
    calendar_end = DateTime.add(now, plan.forward_days, :day)

    {telemetry, bundle}
    |> fetch_companion_source(
      "calendar_local",
      fn ->
        events =
          user_id
          |> LocalCalendar.events_around(
            since: lookback_start,
            until: calendar_end,
            limit: plan.local_calendar_limit
          )
          |> Enum.map(&local_calendar_event_for_bundle/1)

        {:ok,
         &SourceBundle.put_calendar_local(&1, %{
           "events" => events,
           "counts" => %{"event_count" => length(events)},
           "metadata" => %{"mode" => "companion"}
         }), %{"event_count" => length(events)}}
      end
    )
    |> fetch_companion_source(
      "imessage",
      fn ->
        messages =
          user_id
          |> LocalMessages.recent_for_user(limit: plan.local_message_limit)
          |> Enum.map(&local_message_for_bundle(user_id, &1))

        chats =
          user_id
          |> LocalMessages.chats_recent(limit: plan.local_chat_limit, now: now)
          |> Enum.map(&local_chat_for_bundle(user_id, &1))

        {:ok,
         &SourceBundle.put_imessage(&1, %{
           "messages" => messages,
           "chats" => chats,
           "counts" => %{"message_count" => length(messages), "chat_count" => length(chats)},
           "metadata" => %{"mode" => "companion"}
         }), %{"message_count" => length(messages), "chat_count" => length(chats)}}
      end
    )
    |> fetch_companion_source(
      "voice_memos",
      fn ->
        memos =
          user_id
          |> LocalVoiceMemos.recent_for_user(limit: plan.local_voice_memo_limit)
          |> Enum.map(&voice_memo_for_bundle/1)

        {:ok,
         &SourceBundle.put_voice_memos(&1, %{
           "memos" => memos,
           "counts" => %{"memo_count" => length(memos)},
           "metadata" => %{"mode" => "companion"}
         }), %{"memo_count" => length(memos)}}
      end
    )
    |> fetch_companion_source(
      "notes",
      fn ->
        notes =
          user_id
          |> LocalNotes.recent_for_user(limit: plan.local_note_limit)
          |> Enum.map(&note_for_bundle/1)

        {:ok,
         &SourceBundle.put_notes(&1, %{
           "notes" => notes,
           "counts" => %{"note_count" => length(notes)},
           "metadata" => %{"mode" => "companion"}
         }), %{"note_count" => length(notes)}}
      end
    )
    |> fetch_companion_source(
      "reminders",
      fn ->
        reminders =
          user_id
          |> LocalReminders.due_soon(
            days_ahead: plan.forward_days,
            limit: plan.local_reminder_limit
          )
          |> Enum.map(&reminder_for_bundle/1)

        {:ok,
         &SourceBundle.put_reminders(&1, %{
           "reminders" => reminders,
           "counts" => %{"open_due_soon" => length(reminders)},
           "metadata" => %{"mode" => "companion"}
         }), %{"open_due_soon" => length(reminders)}}
      end
    )
    |> fetch_companion_source(
      "files",
      fn ->
        files =
          user_id
          |> LocalFiles.recent_for_user(limit: plan.local_file_limit)
          |> Enum.map(&file_for_bundle/1)

        {:ok,
         &SourceBundle.put_files(&1, %{
           "files" => files,
           "counts" => %{"recent_count" => length(files)},
           "metadata" => %{"mode" => "companion"}
         }), %{"recent_count" => length(files)}}
      end
    )
    |> fetch_companion_source(
      "browser_history",
      fn ->
        visits =
          user_id
          |> LocalBrowserHistory.recent_visits(limit: plan.local_browser_visit_limit)
          |> Enum.map(&browser_visit_for_bundle/1)

        {:ok,
         &SourceBundle.put_browser_history(&1, %{
           "visits" => visits,
           "counts" => %{"visit_count" => length(visits)},
           "metadata" => %{"mode" => "companion"}
         }), %{"visit_count" => length(visits)}}
      end
    )
  end

  defp maybe_fetch_companion_sources({telemetry, bundle}, _user_id, _plan, _context),
    do: {telemetry, bundle}

  defp fetch_companion_source({telemetry, bundle}, source, fetch_fun) do
    case fetch_fun.() do
      {:ok, put_fun, counts} when is_function(put_fun, 1) ->
        bundle = put_fun.(bundle)

        telemetry =
          telemetry
          |> Map.update("fetches", [], fn fetches ->
            [
              %{
                "source" => source,
                "mode" => "companion",
                "status" => "ok"
              }
              |> Map.merge(counts)
              | fetches
            ]
          end)
          |> put_source_summary(
            source,
            %{"mode" => "companion", "status" => "ready"} |> Map.merge(counts)
          )

        {telemetry, bundle}

      {:error, reason} ->
        companion_source_error({telemetry, bundle}, source, reason)
    end
  rescue
    exception ->
      companion_source_error({telemetry, bundle}, source, Exception.message(exception))
  catch
    kind, reason ->
      companion_source_error({telemetry, bundle}, source, "#{kind}: #{inspect(reason)}")
  end

  defp companion_source_error({telemetry, bundle}, source, reason) do
    bundle = SourceBundle.mark_unavailable(bundle, source, inspect(reason))

    telemetry =
      telemetry
      |> Map.update("fetches", [], fn fetches ->
        [
          %{
            "source" => source,
            "mode" => "companion",
            "status" => "error",
            "reason" => inspect(reason)
          }
          | fetches
        ]
      end)
      |> put_source_summary(source, %{
        "mode" => "companion",
        "status" => "error",
        "reason" => inspect(reason)
      })

    {telemetry, bundle}
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

  defp maybe_fetch_weather(
         {telemetry, bundle},
         _user_id,
         _source_scope,
         %{weather: false},
         _context
       ),
       do: {telemetry, bundle}

  defp maybe_fetch_weather({telemetry, bundle}, _user_id, _source_scope, plan, context) do
    now = context[:timestamp] || DateTime.utc_now()

    case weather_module().fetch_for_brief(Map.get(plan, :weather_config, %{}), now) do
      {:ok, %{} = result} ->
        bundle = SourceBundle.put_weather(bundle, result)

        telemetry =
          put_source_summary(telemetry, "weather", %{
            "mode" => "open_meteo",
            "status" => Map.get(result, "status", "ready"),
            "location" => Map.get(result, "location")
          })

        {telemetry, bundle}

      {:error, reason} ->
        bundle = SourceBundle.mark_unavailable(bundle, "weather", inspect(reason))

        telemetry =
          put_source_summary(telemetry, "weather", %{
            "mode" => "open_meteo",
            "status" => "error",
            "reason" => inspect(reason)
          })

        {telemetry, bundle}
    end
  end

  defp fetch_slack_workspace(user_id, source_scope, team_id, plan, oldest) do
    with {:ok, token} <-
           SlackHelpers.resolve_access_token(user_id, team_id, token_preference: "auto"),
         {:ok, conversations} <-
           list_all_slack_conversations(token.access_token,
             types: ["public_channel", "private_channel", "mpim", "im"]
           ) do
      workspace = SourceScope.slack_workspace_for_team(source_scope, team_id) || %{}

      conversations =
        conversations
        |> Enum.sort_by(&slack_channel_priority(&1, plan.slack_key_channels))
        |> Enum.take(max(plan.slack_channel_limit, 0))

      {channels, fetches, _user_directory} =
        Enum.reduce(conversations, {[], [], %{}}, fn channel,
                                                     {channel_acc, fetch_acc, directory_acc} ->
          channel_id = channel["id"]

          case slack_module().get_conversation_history(token.access_token, channel_id,
                 limit: plan.slack_message_limit,
                 oldest: oldest
               ) do
            {:ok, history} ->
              raw_messages =
                history
                |> Map.get("messages", [])
                |> normalize_list()

              {raw_messages, thread_fetches} =
                expand_slack_threads(token.access_token, channel_id, raw_messages, plan)

              user_directory =
                slack_user_directory(token.access_token, raw_messages, channel, directory_acc)

              messages =
                raw_messages
                |> Enum.map(
                  &serialize_slack_message(&1, channel, team_id, workspace, user_directory)
                )

              channel_payload =
                channel
                |> serialize_slack_channel()
                |> put_slack_channel_user_fields(channel, user_directory)
                |> Map.put("messages", messages)

              {
                [channel_payload | channel_acc],
                [
                  %{
                    "source" => "slack",
                    "team_id" => team_id,
                    "channel_id" => channel_id,
                    "conversation_kind" => slack_conversation_kind(channel),
                    "mode" => "connector",
                    "status" => "ok",
                    "count" => length(messages),
                    "thread_fetch_count" => count_ok_slack_thread_fetches(thread_fetches),
                    "thread_reply_count" => count_slack_thread_replies(thread_fetches)
                  }
                  | thread_fetches ++ fetch_acc
                ],
                user_directory
              }

            {:error, reason} ->
              {
                channel_acc,
                [
                  %{
                    "source" => "slack",
                    "team_id" => team_id,
                    "channel_id" => channel_id,
                    "conversation_kind" => slack_conversation_kind(channel),
                    "mode" => "connector",
                    "status" => "error",
                    "reason" => inspect(reason)
                  }
                  | fetch_acc
                ],
                directory_acc
              }
          end
        end)

      {mentions, mention_fetches} =
        fetch_slack_mentions(user_id, team_id, workspace, plan, oldest)

      {self_authored_messages, self_authored_fetches} =
        fetch_slack_self_authored_messages(user_id, team_id, workspace, plan, oldest)

      channels =
        maybe_prepend_slack_search_channel(channels, self_authored_messages)

      workspace_payload = %{
        "team_id" => team_id,
        "team_name" => Map.get(workspace, "team_name"),
        "channels" => Enum.reverse(channels),
        "key_channels" => Enum.reverse(channels),
        "mentions" => mentions,
        "metadata" => %{
          "conversation_count" => length(conversations),
          "conversation_scope" => "all_connected_conversations",
          "token_provider" => token.provider
        }
      }

      {:ok, workspace_payload, self_authored_fetches ++ mention_fetches ++ fetches}
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
        raw_matches =
          response
          |> get_in(["messages", "matches"])
          |> normalize_list()

        user_directory = slack_user_directory(token.access_token, raw_matches, nil)

        matches =
          Enum.map(raw_matches, &serialize_slack_match(&1, team_id, workspace, user_directory))

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

  defp fetch_slack_self_authored_messages(user_id, team_id, workspace, plan, oldest) do
    user_ids = slack_user_ids_for_team(user_id, team_id)
    search_limit = slack_self_authored_search_limit(plan)

    user_ids
    |> Enum.take(3)
    |> Enum.reduce({[], []}, fn slack_user_id, {message_acc, fetch_acc} ->
      case SlackHelpers.resolve_access_token(user_id, team_id,
             token_preference: "user",
             slack_user_id: slack_user_id
           ) do
        {:ok, token} ->
          {matches, query_fetches} =
            fetch_slack_self_authored_queries(
              token.access_token,
              team_id,
              workspace,
              slack_user_id,
              search_limit,
              oldest
            )

          {dedupe_slack_messages(message_acc ++ matches), query_fetches ++ fetch_acc}

        {:error, :no_user_token} ->
          {message_acc, fetch_acc}

        {:error, reason} ->
          {message_acc,
           [
             %{
               "source" => "slack",
               "team_id" => team_id,
               "mode" => "self_authored_search",
               "status" => "error",
               "slack_user_id" => slack_user_id,
               "reason" => inspect(reason)
             }
             | fetch_acc
           ]}
      end
    end)
  end

  defp fetch_slack_self_authored_queries(
         access_token,
         team_id,
         workspace,
         slack_user_id,
         search_limit,
         oldest
       ) do
    Enum.reduce(@slack_self_authored_search_queries, {[], []}, fn query,
                                                                  {message_acc, fetch_acc} ->
      case slack_module().search_messages(access_token, query,
             count: search_limit,
             sort: "timestamp",
             sort_dir: "desc"
           ) do
        {:ok, response} ->
          raw_matches =
            response
            |> get_in(["messages", "matches"])
            |> normalize_list()
            |> Enum.filter(&slack_search_match_for_user?(&1, slack_user_id))
            |> Enum.filter(&slack_search_match_recent?(&1, oldest))

          user_directory = slack_user_directory(access_token, raw_matches, nil)

          matches =
            raw_matches
            |> Enum.map(fn match ->
              match
              |> serialize_slack_match(team_id, workspace, user_directory)
              |> Map.put("search_mode", "self_authored")
              |> Map.put("search_query", query)
            end)

          fetch = %{
            "source" => "slack",
            "team_id" => team_id,
            "mode" => "self_authored_search",
            "status" => "ok",
            "slack_user_id" => slack_user_id,
            "query" => query,
            "count" => length(matches)
          }

          {dedupe_slack_messages(message_acc ++ matches), [fetch | fetch_acc]}

        {:error, reason} ->
          fetch = %{
            "source" => "slack",
            "team_id" => team_id,
            "mode" => "self_authored_search",
            "status" => "error",
            "slack_user_id" => slack_user_id,
            "query" => query,
            "reason" => inspect(reason)
          }

          {message_acc, [fetch | fetch_acc]}
      end
    end)
  end

  defp maybe_prepend_slack_search_channel(channels, []), do: channels

  defp maybe_prepend_slack_search_channel(channels, messages) when is_list(channels) do
    [
      %{
        "id" => "slack_search:self_authored",
        "name" => "self-authored Slack search",
        "conversation_kind" => "search",
        "messages" => dedupe_slack_messages(messages)
      }
      | channels
    ]
  end

  defp slack_self_authored_search_limit(plan) when is_map(plan) do
    limit =
      plan
      |> Map.get(:slack_message_limit, @default_slack_message_limit)
      |> parse_integer()

    (limit || @default_slack_message_limit)
    |> min(@slack_self_authored_search_result_limit)
  end

  defp slack_self_authored_search_limit(_plan), do: @default_slack_message_limit

  defp slack_search_match_for_user?(match, slack_user_id) when is_map(match) do
    normalize_string(match["user"]) == slack_user_id
  end

  defp slack_search_match_for_user?(_match, _slack_user_id), do: false

  defp slack_search_match_recent?(match, oldest) when is_map(match) and is_binary(oldest) do
    with {oldest_seconds, _} <- Float.parse(oldest),
         ts when ts > 0 <- slack_ts_sort_value(match) do
      ts >= oldest_seconds
    else
      _ -> true
    end
  end

  defp slack_search_match_recent?(_match, _oldest), do: true

  defp expand_slack_threads(access_token, channel_id, raw_messages, plan)
       when is_binary(access_token) and is_binary(channel_id) and is_list(raw_messages) do
    raw_messages
    |> slack_thread_ids_from_messages()
    |> Enum.take(@slack_thread_fetch_limit)
    |> Enum.reduce({raw_messages, []}, fn thread_ts, {message_acc, fetch_acc} ->
      case slack_module().get_thread_replies(access_token, channel_id, thread_ts,
             limit: slack_thread_reply_limit(plan)
           ) do
        {:ok, response} ->
          replies =
            response
            |> Map.get("messages", [])
            |> normalize_list()

          fetch = %{
            "source" => "slack",
            "channel_id" => channel_id,
            "thread_ts" => thread_ts,
            "mode" => "thread_replies",
            "status" => "ok",
            "count" => length(replies),
            "has_more" => response["has_more"] || false
          }

          {merge_slack_messages(message_acc, replies), [fetch | fetch_acc]}

        {:error, reason} ->
          fetch = %{
            "source" => "slack",
            "channel_id" => channel_id,
            "thread_ts" => thread_ts,
            "mode" => "thread_replies",
            "status" => "error",
            "reason" => inspect(reason)
          }

          {message_acc, [fetch | fetch_acc]}
      end
    end)
  end

  defp expand_slack_threads(_access_token, _channel_id, raw_messages, _plan),
    do: {raw_messages, []}

  defp slack_thread_ids_from_messages(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(&slack_thread_ids_from_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp slack_thread_ids_from_messages(_messages), do: []

  defp slack_thread_ids_from_message(message) when is_map(message) do
    ts = normalize_string(message["ts"])
    thread_ts = normalize_string(message["thread_ts"])

    cond do
      thread_ts ->
        [thread_ts]

      slack_threaded_root?(message) and ts ->
        [ts]

      true ->
        []
    end
  end

  defp slack_thread_ids_from_message(_message), do: []

  defp slack_threaded_root?(message) when is_map(message) do
    positive_integer?(message["reply_count"]) or present_string?(message["latest_reply"])
  end

  defp slack_threaded_root?(_message), do: false

  defp positive_integer?(value) when is_integer(value), do: value > 0

  defp positive_integer?(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int > 0
      _ -> false
    end
  end

  defp positive_integer?(_value), do: false

  defp slack_thread_reply_limit(plan) when is_map(plan) do
    plan
    |> Map.get(:slack_message_limit, @default_slack_message_limit)
    |> max(1)
    |> min(@slack_thread_reply_limit)
  end

  defp slack_thread_reply_limit(_plan), do: @default_slack_message_limit

  defp merge_slack_messages(messages, replies) do
    (normalize_list(messages) ++ normalize_list(replies))
    |> Enum.uniq_by(&normalize_string(&1["ts"]))
    |> Enum.sort_by(&slack_ts_sort_value/1, :desc)
  end

  defp dedupe_slack_messages(messages) when is_list(messages) do
    messages
    |> normalize_list()
    |> Enum.uniq_by(fn message ->
      {
        normalize_string(message["team_id"]),
        normalize_string(message["channel_id"]),
        normalize_string(message["ts"])
      }
    end)
    |> Enum.sort_by(&slack_ts_sort_value/1, :desc)
  end

  defp slack_ts_sort_value(message) when is_map(message) do
    case Float.parse(to_string(message["ts"] || "")) do
      {value, _rest} -> value
      :error -> 0.0
    end
  end

  defp slack_ts_sort_value(_message), do: 0.0

  defp count_ok_slack_thread_fetches(fetches) when is_list(fetches) do
    Enum.count(fetches, &(&1["mode"] == "thread_replies" and &1["status"] == "ok"))
  end

  defp count_ok_slack_thread_fetches(_fetches), do: 0

  defp count_slack_thread_replies(fetches) when is_list(fetches) do
    fetches
    |> Enum.filter(&(&1["mode"] == "thread_replies" and &1["status"] == "ok"))
    |> Enum.map(&(&1["count"] || 0))
    |> Enum.sum()
  end

  defp count_slack_thread_replies(_fetches), do: 0

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
              commercial_messages =
                fetch_commercial_gmail_messages(user_id, provider, plan.commercial_gmail_queries)

              annotated =
                (messages ++ commercial_messages)
                |> dedupe_messages()
                |> annotate_google_items(source_scope, provider)
                |> enrich_gmail_messages(user_id, provider, plan)

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
    weather_config = weather_config(skill_ids, skill_configs)
    morning_brief? = morning_brief_trigger?(skill_ids, context)

    %{
      gmail:
        service_required?(requirements, "google", "gmail") and
          event_allows_source?(event_source, "gmail"),
      calendar:
        service_required?(requirements, "google", "calendar") and
          event_allows_source?(event_source, "google_calendar"),
      slack: true,
      news: morning_brief_trigger?(skill_ids, context) and news_enabled?(news_config),
      news_config: news_config,
      weather: morning_brief_trigger?(skill_ids, context) and weather_enabled?(weather_config),
      weather_config: weather_config,
      web_context: morning_brief_trigger?(skill_ids, context),
      inbox_limit: max(max_email_scan_limit, 100),
      sent_limit: max(max_email_scan_limit * 2, 100),
      gmail_message_limit: max(max_email_scan_limit * 4, @default_gmail_message_limit),
      gmail_body_fetch_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "gmail_body_fetch_limit",
          @default_gmail_body_fetch_limit
        ),
      gmail_body_fetch_timeout_ms:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "gmail_body_fetch_timeout_ms",
          configured_gmail_body_fetch_timeout_ms()
        ),
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
      commercial_gmail_queries: commercial_gmail_queries(skill_ids, skill_configs),
      local_calendar_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_calendar_limit",
          @default_local_calendar_limit
        ),
      local_message_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_message_limit",
          @default_local_message_limit
        ),
      local_chat_limit:
        max_skill_integer(skill_ids, skill_configs, "local_chat_limit", @default_local_chat_limit),
      local_voice_memo_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_voice_memo_limit",
          @default_local_voice_memo_limit
        ),
      local_note_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_note_limit",
          @default_local_note_limit
        ),
      local_reminder_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_reminder_limit",
          @default_local_reminder_limit
        ),
      local_file_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_file_limit",
          @default_local_file_limit
        ),
      local_browser_visit_limit:
        max_skill_integer(
          skill_ids,
          skill_configs,
          "local_browser_visit_limit",
          @default_local_browser_visit_limit
        ),
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

  defp weather_config(skill_ids, skill_configs) do
    skill_ids
    |> Enum.map(fn skill_id -> Map.get(skill_configs, skill_id, %{}) end)
    |> Enum.reduce(%{}, fn config, acc ->
      acc
      |> maybe_put("weather_enabled", Map.get(config, "weather_enabled"))
      |> maybe_put("weather_location", Map.get(config, "weather_location"))
      |> maybe_put("weather_latitude", Map.get(config, "weather_latitude"))
      |> maybe_put("weather_longitude", Map.get(config, "weather_longitude"))
      |> maybe_put("timezone", Map.get(config, "timezone") || Map.get(config, "timezone_name"))
    end)
  end

  defp weather_enabled?(%{"weather_enabled" => false}), do: false
  defp weather_enabled?(%{"weather_enabled" => "false"}), do: false
  defp weather_enabled?(%{"weather_enabled" => "0"}), do: false
  defp weather_enabled?(config) when is_map(config), do: true

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
        |> configured_list("slack_key_channels")
      end)
      |> Enum.map(&normalize_channel_name/1)
      |> Enum.reject(&is_nil/1)

    (@default_slack_key_channels ++ configured)
    |> Enum.map(&normalize_channel_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp commercial_gmail_queries(skill_ids, skill_configs) do
    configured =
      skill_ids
      |> Enum.flat_map(fn skill_id ->
        skill_configs
        |> Map.get(skill_id, %{})
        |> configured_list("commercial_gmail_queries")
      end)
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)

    (@default_commercial_gmail_queries ++ configured)
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

  defp enrich_gmail_messages(messages, user_id, default_provider, plan)
       when is_list(messages) and is_binary(user_id) do
    {body_candidates, metadata_only} = Enum.split(messages, gmail_body_fetch_limit(plan))

    enriched =
      enrich_gmail_message_bodies(body_candidates, user_id, default_provider, plan)

    skipped = Enum.map(metadata_only, &mark_gmail_body_unavailable(&1, "not_fetched"))

    enriched ++ skipped
  end

  defp enrich_gmail_messages(messages, _user_id, _default_provider, _plan) when is_list(messages),
    do: Enum.map(messages, &stringify_keys/1)

  defp enrich_gmail_messages(_messages, _user_id, _default_provider, _plan), do: []

  defp enrich_gmail_message_bodies(messages, user_id, default_provider, plan) do
    results =
      Task.async_stream(
        messages,
        fn message -> enrich_gmail_message(user_id, message, default_provider) end,
        max_concurrency: 4,
        timeout: gmail_body_fetch_timeout_ms(plan),
        on_timeout: :kill_task
      )

    messages
    |> Enum.zip(results)
    |> Enum.map(fn
      {_original, {:ok, message}} ->
        message

      {original, {:exit, _reason}} ->
        mark_gmail_body_unavailable(original, "fetch_failed")
    end)
  end

  defp mark_gmail_body_unavailable(message, status) do
    message
    |> stringify_keys()
    |> Map.put("body_available", false)
    |> Map.put("body_status", status)
  end

  defp gmail_body_fetch_limit(plan) when is_map(plan) do
    plan
    |> Map.get(:gmail_body_fetch_limit, @default_gmail_body_fetch_limit)
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_gmail_body_fetch_limit
    end
  end

  defp gmail_body_fetch_limit(_plan), do: @default_gmail_body_fetch_limit

  defp gmail_body_fetch_timeout_ms(plan) when is_map(plan) do
    plan
    |> Map.get(:gmail_body_fetch_timeout_ms, configured_gmail_body_fetch_timeout_ms())
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> configured_gmail_body_fetch_timeout_ms()
    end
  end

  defp gmail_body_fetch_timeout_ms(_plan), do: configured_gmail_body_fetch_timeout_ms()

  defp configured_gmail_body_fetch_timeout_ms do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:gmail_body_fetch_timeout_ms, @default_gmail_body_fetch_timeout_ms)
    |> parse_integer()
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_gmail_body_fetch_timeout_ms
    end
  end

  defp fetch_commercial_gmail_messages(_user_id, _provider, []), do: []

  defp fetch_commercial_gmail_messages(user_id, provider, queries) when is_list(queries) do
    queries
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

  defp local_calendar_event_for_bundle(%Maraithon.LocalCalendar.LocalEvent{} = event) do
    %{
      "event_id" => event.guid || event.id,
      "source" => "local_calendar",
      "calendar_name" => event.calendar_name,
      "summary" => event.title || "Untitled event",
      "notes" => truncate_string(event.notes, 2_000),
      "start" => timestamp(event.start_at),
      "end" => timestamp(event.end_at),
      "location" => event.location,
      "attendees" => event.attendee_emails || [],
      "organizer" => event.organizer_email,
      "is_all_day" => event.is_all_day,
      "source_account_label" => event.calendar_name,
      "source_item_id" => event.guid || event.id,
      "source_occurred_at" => timestamp(event.start_at)
    }
  end

  defp local_calendar_event_for_bundle(event) when is_map(event), do: stringify_keys(event)

  defp local_message_for_bundle(user_id, %Maraithon.LocalMessages.LocalMessage{} = message)
       when is_binary(user_id) do
    user_id
    |> maybe_resolve_message_person(message.sender_handle)
    |> add_resolved_message_person(local_message_for_bundle(message))
  end

  defp local_message_for_bundle(_user_id, message), do: local_message_for_bundle(message)

  defp local_message_for_bundle(%Maraithon.LocalMessages.LocalMessage{} = message) do
    %{
      "message_id" => message.guid || message.id,
      "guid" => message.guid,
      "local_id" => message.local_id,
      "source" => message.source || "imessage",
      "chat_key" => message.chat_key,
      "chat_display_name" => message.chat_display_name,
      "chat_style" => message.chat_style,
      "sender_handle" => message.sender_handle,
      "is_from_me" => message.is_from_me,
      "text" => truncate_string(message.text, 2_000),
      "sent_at" => timestamp(message.sent_at),
      "has_attachments" => message.has_attachments,
      "attachments" => message.attachments || %{},
      "source_item_id" => message.guid || message.id,
      "source_occurred_at" => timestamp(message.sent_at)
    }
  end

  defp local_message_for_bundle(message) when is_map(message), do: stringify_keys(message)

  defp local_chat_for_bundle(user_id, %{chat_key: _chat_key} = chat) when is_binary(user_id) do
    chat
    |> local_chat_for_bundle()
    |> add_resolved_latest_sender(user_id)
  end

  defp local_chat_for_bundle(_user_id, chat), do: local_chat_for_bundle(chat)

  defp local_chat_for_bundle(%{chat_key: chat_key} = chat) do
    latest = Map.get(chat, :latest_message) || Map.get(chat, "latest_message")
    latest_message = if latest, do: local_message_for_bundle(latest), else: nil

    %{
      "chat_key" => chat_key,
      "chat_display_name" =>
        Map.get(chat, :chat_display_name) || Map.get(chat, "chat_display_name"),
      "message_count_last_7d" =>
        Map.get(chat, :message_count_last_7d) || Map.get(chat, "message_count_last_7d") || 0,
      "latest_message" => latest_message,
      "latest_snippet" => latest_message && Map.get(latest_message, "text"),
      "latest_sender" => latest_message && Map.get(latest_message, "sender_handle"),
      "latest_is_from_me" => latest_message && Map.get(latest_message, "is_from_me"),
      "latest_sent_at" => latest_message && Map.get(latest_message, "sent_at")
    }
  end

  defp local_chat_for_bundle(chat) when is_map(chat), do: stringify_keys(chat)

  defp maybe_resolve_message_person(user_id, handle) when is_binary(handle) do
    Crm.find_person_by_contact(user_id, handle)
  end

  defp maybe_resolve_message_person(_user_id, _handle), do: nil

  defp add_resolved_message_person(nil, message), do: message

  defp add_resolved_message_person(%Maraithon.Crm.Person{} = person, message) do
    message
    |> Map.put("sender_display_name", person.display_name)
    |> Map.put("sender_person_id", person.id)
    |> maybe_put("sender_relationship", person.relationship)
  end

  defp add_resolved_latest_sender(chat, user_id) when is_map(chat) and is_binary(user_id) do
    case maybe_resolve_message_person(user_id, Map.get(chat, "latest_sender")) do
      %Maraithon.Crm.Person{} = person ->
        chat
        |> Map.put("latest_sender_display_name", person.display_name)
        |> Map.put("latest_sender_person_id", person.id)

      nil ->
        chat
    end
  end

  defp add_resolved_latest_sender(chat, _user_id), do: chat

  defp voice_memo_for_bundle(%Maraithon.LocalVoiceMemos.LocalVoiceMemo{} = memo) do
    %{
      "memo_id" => memo.guid || memo.id,
      "guid" => memo.guid,
      "local_id" => memo.local_id,
      "source" => memo.source || "voice_memos",
      "title" => memo.title || "(untitled voice memo)",
      "snippet" => memo.snippet || "",
      "transcript" => truncate_string(memo.transcript, 4_000),
      "duration_seconds" => memo.duration_seconds,
      "created_at" => timestamp(memo.created_at),
      "has_transcript" => present_string?(memo.transcript),
      "transcript_engine" => memo.transcript_engine,
      "transcript_lang" => memo.transcript_lang,
      "source_item_id" => memo.guid || memo.id,
      "source_occurred_at" => timestamp(memo.created_at)
    }
  end

  defp voice_memo_for_bundle(memo) when is_map(memo), do: stringify_keys(memo)

  defp note_for_bundle(%Maraithon.LocalNotes.LocalNote{} = note) do
    %{
      "note_id" => note.guid || note.id,
      "guid" => note.guid,
      "local_id" => note.local_id,
      "source" => note.source || "notes",
      "title" => note.title || "(untitled note)",
      "snippet" => note.snippet || "",
      "body" => truncate_string(note.body, 4_000),
      "folder" => note.folder,
      "is_pinned" => note.is_pinned,
      "created_at" => timestamp(note.created_at),
      "modified_at" => timestamp(note.modified_at),
      "source_item_id" => note.guid || note.id,
      "source_occurred_at" => timestamp(note.modified_at || note.created_at)
    }
  end

  defp note_for_bundle(note) when is_map(note), do: stringify_keys(note)

  defp reminder_for_bundle(%Maraithon.LocalReminders.LocalReminder{} = reminder) do
    %{
      "reminder_id" => reminder.guid || reminder.id,
      "guid" => reminder.guid,
      "local_id" => reminder.local_id,
      "source" => reminder.source || "reminders",
      "title" => reminder.title || "(untitled reminder)",
      "notes" => truncate_string(reminder.notes, 2_000),
      "list_name" => reminder.list_name,
      "priority" => reminder.priority,
      "due_at" => timestamp(reminder.due_at),
      "is_completed" => reminder.is_completed,
      "has_alarm" => reminder.has_alarm,
      "url_attachment" => reminder.url_attachment,
      "created_at" => timestamp(reminder.created_at),
      "modified_at" => timestamp(reminder.modified_at),
      "source_item_id" => reminder.guid || reminder.id,
      "source_occurred_at" => timestamp(reminder.modified_at || reminder.created_at)
    }
  end

  defp reminder_for_bundle(reminder) when is_map(reminder), do: stringify_keys(reminder)

  defp file_for_bundle(%Maraithon.LocalFiles.LocalFile{} = file) do
    %{
      "file_id" => file.guid || file.id,
      "guid" => file.guid,
      "local_id" => file.local_id,
      "source" => file.source || "files",
      "filename" => file.filename,
      "path" => file.path,
      "extension" => file.extension,
      "mime_type" => file.mime_type,
      "byte_size" => file.byte_size,
      "text_content" => truncate_string(file.text_content, 3_000),
      "text_truncated" => file.text_truncated,
      "created_at" => timestamp(file.created_at),
      "modified_at" => timestamp(file.modified_at),
      "source_item_id" => file.guid || file.id,
      "source_occurred_at" => timestamp(file.modified_at || file.created_at)
    }
  end

  defp file_for_bundle(file) when is_map(file), do: stringify_keys(file)

  defp browser_visit_for_bundle(%Maraithon.LocalBrowserHistory.LocalVisit{} = visit) do
    %{
      "visit_id" => visit.guid || visit.id,
      "guid" => visit.guid,
      "local_id" => visit.local_id,
      "source" => visit.source || "browser_history",
      "browser" => visit.browser,
      "title" => visit.title,
      "url" => visit.url,
      "host" => visit.host,
      "last_visited_at" => timestamp(visit.last_visited_at),
      "visit_count" => visit.visit_count,
      "source_item_id" => visit.guid || visit.id,
      "source_occurred_at" => timestamp(visit.last_visited_at)
    }
  end

  defp browser_visit_for_bundle(visit) when is_map(visit), do: stringify_keys(visit)

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

  defp put_slack_channel_user_fields(channel_payload, channel, user_directory)
       when is_map(channel_payload) and is_map(channel) do
    counterparty_id = channel["user"]

    channel_payload
    |> maybe_put("counterparty_user_id", counterparty_id)
    |> maybe_put(
      "counterparty_display_name",
      UserDirectory.display_name(user_directory, counterparty_id)
    )
  end

  defp serialize_slack_message(message, channel, team_id, workspace, user_directory)
       when is_map(message) do
    user_id = message["user"]
    text = message["text"]

    %{
      "team_id" => team_id,
      "team_name" => Map.get(workspace, "team_name"),
      "channel_id" => channel["id"],
      "channel_name" => channel["name"] || slack_conversation_kind(channel),
      "conversation_kind" => slack_conversation_kind(channel),
      "ts" => message["ts"],
      "thread_ts" => message["thread_ts"],
      "user" => user_id,
      "user_display_name" => UserDirectory.display_name(user_directory, user_id),
      "mentioned_users" => UserDirectory.mentioned_users(text, user_directory),
      "text_resolved" => UserDirectory.replace_mentions(text, user_directory),
      "bot_id" => message["bot_id"],
      "subtype" => message["subtype"],
      "text" => text,
      "reply_count" => message["reply_count"],
      "latest_reply" => message["latest_reply"],
      "reactions" => normalize_list(message["reactions"])
    }
  end

  defp serialize_slack_match(match, team_id, workspace, user_directory) when is_map(match) do
    user_id = match["user"]
    text = match["text"]
    channel = match["channel"]

    %{
      "team_id" => team_id,
      "team_name" => Map.get(workspace, "team_name"),
      "channel_id" => slack_match_channel_id(channel),
      "channel_name" => slack_match_channel_name(channel),
      "ts" => match["ts"],
      "thread_ts" => match["thread_ts"],
      "user" => user_id,
      "user_display_name" => UserDirectory.display_name(user_directory, user_id),
      "mentioned_users" => UserDirectory.mentioned_users(text, user_directory),
      "text_resolved" => UserDirectory.replace_mentions(text, user_directory),
      "text" => text,
      "permalink" => match["permalink"]
    }
  end

  defp slack_user_directory(access_token, messages, channel, directory \\ %{}) do
    message_user_ids =
      messages
      |> normalize_list()
      |> Enum.flat_map(&slack_user_ids_from_message/1)

    user_ids = message_user_ids ++ slack_user_ids_from_channel(channel)
    missing_user_ids = missing_slack_user_ids(user_ids, directory)
    remaining_user_lookups = max(@slack_user_directory_limit - map_size(directory), 0)
    lookup_user_ids = Enum.take(missing_user_ids, remaining_user_lookups)

    resolved =
      if lookup_user_ids != [] do
        UserDirectory.resolve(access_token, lookup_user_ids,
          max_users: length(lookup_user_ids),
          max_concurrency: 8,
          timeout: @slack_user_directory_timeout_ms
        )
      else
        %{}
      end

    attempted = Map.new(lookup_user_ids, &{&1, nil})

    directory
    |> Map.merge(attempted)
    |> Map.merge(resolved)
  end

  defp missing_slack_user_ids(user_ids, directory) do
    user_ids
    |> UserDirectory.normalize_user_ids()
    |> Enum.reject(&Map.has_key?(directory, &1))
  end

  defp slack_user_ids_from_channel(channel) when is_map(channel) do
    [channel["user"]]
  end

  defp slack_user_ids_from_channel(_channel), do: []

  defp slack_user_ids_from_message(message) when is_map(message) do
    [
      message["user"],
      slack_message_channel_user(message["channel"])
    ] ++ UserDirectory.user_ids_from_text(message["text"])
  end

  defp slack_user_ids_from_message(_message), do: []

  defp slack_message_channel_user(%{} = channel), do: channel["user"]
  defp slack_message_channel_user(_channel), do: nil

  defp slack_match_channel_id(%{} = channel), do: channel["id"]
  defp slack_match_channel_id(channel) when is_binary(channel), do: channel
  defp slack_match_channel_id(_channel), do: nil

  defp slack_match_channel_name(%{} = channel), do: channel["name"]
  defp slack_match_channel_name(_channel), do: nil

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
    |> Map.get("channels", Map.get(workspace, "key_channels", []))
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

  defp list_all_slack_conversations(access_token, opts) when is_binary(access_token) do
    list_all_slack_conversations(access_token, opts, nil, [])
  end

  defp list_all_slack_conversations(access_token, opts, cursor, acc) do
    request_opts =
      opts
      |> Keyword.put(:exclude_archived, true)
      |> Keyword.put(:limit, @slack_conversations_page_limit)
      |> maybe_put_cursor(cursor)

    case slack_module().list_conversations(access_token, request_opts) do
      {:ok, response} ->
        channels =
          response
          |> Map.get("channels", [])
          |> normalize_list()

        next_cursor =
          response
          |> get_in(["response_metadata", "next_cursor"])
          |> normalize_string()

        acc = acc ++ channels

        if next_cursor do
          list_all_slack_conversations(access_token, opts, next_cursor, acc)
        else
          {:ok, acc}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_cursor(opts, nil), do: opts
  defp maybe_put_cursor(opts, cursor), do: Keyword.put(opts, :cursor, cursor)

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

  defp configured_list(config, key) when is_map(config) and is_binary(key) do
    top_level = Map.get(config, key)
    org_level = get_in(config, ["org", key])

    [top_level, org_level]
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.reject(&is_nil/1)
  end

  defp configured_list(_config, _key), do: []

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> timestamp()

  defp timestamp(value) when is_binary(value), do: normalize_string(value)
  defp timestamp(_value), do: nil

  defp truncate_string(value, limit) when is_binary(value) and is_integer(limit) and limit > 0 do
    value
    |> String.trim()
    |> String.slice(0, limit)
  end

  defp truncate_string(_value, _limit), do: nil

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

  defp weather_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:weather_module, Maraithon.Weather)
  end

  defp account_provider(%{"provider" => provider}) when is_binary(provider), do: provider
  defp account_provider(_source), do: nil

  defp account_email(%{"account_email" => account_email}) when is_binary(account_email),
    do: account_email

  defp account_email(_source), do: nil
end
