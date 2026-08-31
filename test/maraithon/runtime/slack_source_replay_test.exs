defmodule Maraithon.Runtime.SlackSourceReplayTest do
  use ExUnit.Case, async: true

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Runtime.SlackSourceReplay

  test "derives bounded role-specific Slack cursor chains and verifies its payload" do
    account = %ConnectedAccount{
      id: 42,
      user_id: "replay@example.com",
      provider: "slack:T-REPLAY",
      status: "connected"
    }

    now = ~U[2026-08-31 12:00:00Z]
    lower = DateTime.to_unix(~U[2026-08-30 04:00:00Z])
    upper = DateTime.to_unix(~U[2026-08-31 04:00:00Z])

    assert {:ok, replay} = SlackSourceReplay.build(account, lower, upper, now)
    assert SlackSourceReplay.watermark_kind?(replay.discovery_kind, "discovery")
    assert SlackSourceReplay.watermark_kind?(replay.closure_kind, "closure")
    refute SlackSourceReplay.watermark_kind?(replay.discovery_kind, "closure")

    payload = replay |> SlackSourceReplay.payload() |> Map.put("role", "discovery")

    assert {:ok, verified} =
             SlackSourceReplay.from_payload(account, payload, "discovery", now)

    assert verified.kind == replay.discovery_kind
    assert verified.lower == lower
    assert verified.upper == upper

    assert {:error, :invalid_slack_source_replay_payload} =
             SlackSourceReplay.from_payload(
               account,
               Map.put(payload, "source_replay_reference", "tampered"),
               "discovery",
               now
             )
  end

  test "rejects future, oversized, disconnected, and non-Slack windows" do
    now = ~U[2026-08-31 12:00:00Z]
    lower = DateTime.to_unix(~U[2026-08-30 04:00:00Z])
    upper = DateTime.to_unix(~U[2026-08-31 04:00:00Z])

    slack = %ConnectedAccount{
      id: 42,
      user_id: "replay@example.com",
      provider: "slack:T-REPLAY",
      status: "connected"
    }

    assert {:error, :invalid_slack_source_replay} =
             SlackSourceReplay.build(slack, lower, DateTime.to_unix(now) + 1, now)

    assert {:error, :invalid_slack_source_replay} =
             SlackSourceReplay.build(slack, lower - 32 * 24 * 60 * 60, upper, now)

    assert {:error, :invalid_slack_source_replay} =
             SlackSourceReplay.build(%{slack | status: "disconnected"}, lower, upper, now)

    assert {:error, :invalid_slack_source_replay} =
             SlackSourceReplay.build(
               %{slack | provider: "google:replay@example.com"},
               lower,
               upper,
               now
             )
  end
end
