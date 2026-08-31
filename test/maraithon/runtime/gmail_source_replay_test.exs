defmodule Maraithon.Runtime.GmailSourceReplayTest do
  use ExUnit.Case, async: true

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Runtime.GmailSourceReplay

  test "derives bounded role-specific cursor chains and verifies its payload" do
    account = %ConnectedAccount{
      id: 42,
      user_id: "replay@example.com",
      provider: "google:replay@example.com",
      status: "connected"
    }

    now = ~U[2026-08-31 12:00:00Z]
    lower = DateTime.to_unix(~U[2026-08-30 04:00:00Z])
    upper = DateTime.to_unix(~U[2026-08-31 04:00:00Z])

    assert {:ok, replay} = GmailSourceReplay.build(account, lower, upper, now)
    assert GmailSourceReplay.watermark_kind?(replay.discovery_kind, "discovery")
    assert GmailSourceReplay.watermark_kind?(replay.closure_kind, "closure")
    refute GmailSourceReplay.watermark_kind?(replay.discovery_kind, "closure")

    discovery_payload =
      replay
      |> GmailSourceReplay.payload()
      |> Map.put("role", "discovery")

    assert {:ok, verified} =
             GmailSourceReplay.from_payload(account, discovery_payload, "discovery", now)

    assert verified.kind == replay.discovery_kind
    assert verified.lower == lower
    assert verified.upper == upper

    assert {:ok, ^verified} =
             GmailSourceReplay.from_payload(
               account,
               discovery_payload,
               "discovery",
               DateTime.add(upper |> DateTime.from_unix!(), -1, :second)
             )

    assert {:error, :invalid_gmail_source_replay_payload} =
             discovery_payload
             |> Map.put("source_replay_reference", "tampered")
             |> then(&GmailSourceReplay.from_payload(account, &1, "discovery", now))

    assert {:error, :invalid_gmail_source_replay_payload} =
             GmailSourceReplay.validate_runtime_replay(
               account,
               %{verified | reference: "tampered"},
               "discovery"
             )
  end

  test "rejects future, oversized, disconnected, and non-Gmail windows" do
    now = ~U[2026-08-31 12:00:00Z]
    lower = DateTime.to_unix(~U[2026-08-30 04:00:00Z])
    upper = DateTime.to_unix(~U[2026-08-31 04:00:00Z])

    gmail = %ConnectedAccount{
      id: 42,
      user_id: "replay@example.com",
      provider: "google:replay@example.com",
      status: "connected"
    }

    assert {:error, :invalid_gmail_source_replay} =
             GmailSourceReplay.build(gmail, lower, DateTime.to_unix(now) + 1, now)

    assert {:error, :invalid_gmail_source_replay} =
             GmailSourceReplay.build(gmail, lower - 32 * 24 * 60 * 60, upper, now)

    assert {:error, :invalid_gmail_source_replay} =
             GmailSourceReplay.build(%{gmail | status: "disconnected"}, lower, upper, now)

    assert {:error, :invalid_gmail_source_replay} =
             GmailSourceReplay.build(
               %{gmail | provider: "slack:workspace"},
               lower,
               upper,
               now
             )
  end
end
