defmodule Maraithon.Runtime.GmailSourceReplayTest do
  use ExUnit.Case, async: true

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Runtime.GmailSourceReplay
  alias Maraithon.Runtime.GmailSourceReplayAudit

  test "keeps a replay database failure category in the operational error code" do
    assert GmailSourceReplayAudit.error_code({:database_error, :lock_not_available}) ==
             "database_error_lock_not_available"

    assert GmailSourceReplayAudit.error_code({:database_error, "connection_error"}) ==
             "database_error_connection_error"
  end

  test "treats irreducible closure fan-out as neutral while requiring real reductions" do
    assert {:ok, %{applicable: false, strictly_improved: false, reduction_percent: nil}} =
             GmailSourceReplayAudit.closure_fanout_efficiency(0, 0)

    assert {:ok, %{applicable: true, strictly_improved: true, reduction_percent: 80.0}} =
             GmailSourceReplayAudit.closure_fanout_efficiency(10, 2)

    assert {:ok, %{applicable: false, strictly_improved: false, reduction_percent: nil}} =
             GmailSourceReplayAudit.closure_fanout_efficiency(1, 1)

    assert {:error, :gmail_source_replay_not_more_efficient} =
             GmailSourceReplayAudit.closure_fanout_efficiency(0, 1)

    assert {:error, :gmail_source_replay_not_more_efficient} =
             GmailSourceReplayAudit.closure_fanout_efficiency(2, 2)
  end

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
