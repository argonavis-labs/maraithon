defmodule Maraithon.ChiefOfStaff.SourceBundleTest do
  use ExUnit.Case, async: true

  alias Maraithon.ChiefOfStaff.SourceBundle

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
end
