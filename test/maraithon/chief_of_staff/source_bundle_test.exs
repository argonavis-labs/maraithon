defmodule Maraithon.ChiefOfStaff.SourceBundleTest do
  use ExUnit.Case, async: true

  alias Maraithon.ChiefOfStaff.SourceBundle

  test "prioritizes deeply searched Gmail asks before routine recent mail" do
    messages = [
      %{"message_id" => "newest"},
      %{"message_id" => "buried", "search_mode" => "targeted_actionable"},
      %{"message_id" => "older"}
    ]

    assert ["buried", "newest", "older"] ==
             messages
             |> SourceBundle.prioritize_gmail_actionable()
             |> Enum.map(& &1["message_id"])
  end

  test "normalizes Slack workspaces, messages, mentions, and freshness" do
    bundle =
      %{}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_slack(%{
        "workspaces" => [
          %{
            "team_id" => "T123",
            "team_name" => "Agora",
            "key_channels" => [
              %{
                "id" => "C1",
                "name" => "runner-general",
                "messages" => [
                  %{"ts" => "1.0", "text" => "Kent can you review this?", "user" => "U1"}
                ]
              }
            ]
          }
        ],
        "mentions" => [%{"ts" => "1.0", "text" => "<@UKENT> ping"}],
        "providers" => ["T123"],
        "status" => "ready",
        "fetched_at" => ~U[2026-05-07 14:00:00Z]
      })

    assert [%{"team_id" => "T123"}] = SourceBundle.slack_workspaces(bundle)

    assert [%{"channel_name" => "runner-general", "text" => "Kent can you review this?"}] =
             SourceBundle.slack_messages(bundle)

    assert [%{"text" => "<@UKENT> ping"}] = SourceBundle.slack_mentions(bundle)
    assert get_in(SourceBundle.freshness(bundle), ["slack", "counts", "message_count"]) == 1
  end

  test "indexes Gmail, calendar, and Slack content for cycle-local id lookups" do
    gmail = %{"message_id" => "m-1", "thread_id" => "t-1", "body_text" => "full body"}
    event = %{"event_id" => "e-1", "summary" => "Planning"}

    bundle =
      %{}
      |> SourceBundle.empty(%{})
      |> SourceBundle.put_gmail(%{"messages" => [gmail]})
      |> SourceBundle.put_calendar(%{"events" => [event]})
      |> SourceBundle.put_slack(%{
        "workspaces" => [
          %{
            "team_id" => "T1",
            "key_channels" => [
              %{"id" => "C1", "messages" => [%{"ts" => "10.0", "text" => "full text"}]}
            ]
          }
        ]
      })
      |> SourceBundle.with_index()

    assert SourceBundle.gmail_message(bundle, "m-1")["body_text"] == "full body"
    assert SourceBundle.calendar_event(bundle, "e-1")["summary"] == "Planning"
    assert SourceBundle.slack_message(bundle, "C1", "10.0")["text"] == "full text"
    assert SourceBundle.gmail_message(bundle, "missing") == nil
  end
end
