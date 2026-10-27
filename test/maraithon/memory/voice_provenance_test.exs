defmodule Maraithon.Memory.VoiceProvenanceTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{Accounts, TelegramAssistant}
  alias Maraithon.Memory.VoiceSamples

  @moduletag database_role: :session

  setup do
    user = "voice-provenance-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)
    Maraithon.TestSupport.DelegationRuntime.exact_authority(user)

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user,
        chat_id: "voice-provenance",
        surface: "mobile",
        trigger_type: "inbound_message",
        status: "completed",
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        started_at: DateTime.utc_now()
      })

    %{user: user, run: run}
  end

  test "send history is user and channel scoped and reads authenticated durable payloads", c do
    action = action(c, "gmail_send")
    action(c, "slack_post")
    sample = %{internal_date: DateTime.utc_now()}
    assert {:ok, [stored]} = VoiceSamples.generated_writes(c.user, "gmail", [sample])
    assert stored.id == action.id
    assert stored.payload["body"] == "Generated sample"
    assert stored.payload_binding_mac
    assert {:ok, []} = VoiceSamples.generated_writes("other@example.invalid", "gmail", [sample])

    # A purged history entry cannot prove that a candidate was human-authored.
    action
    |> Ecto.Changeset.change(updated_at: DateTime.add(DateTime.utc_now(), -400, :day))
    |> Repo.update!()

    assert {:ok, _} = Maraithon.PrivacyRetention.run_handler(:prepared_actions)

    assert %DateTime{} =
             Repo.get!(Maraithon.TelegramAssistant.PreparedAction, action.id).payload_purged_at

    assert {:error, :voice_provenance_unavailable} =
             VoiceSamples.generated_writes(c.user, "gmail", [sample])
  end

  test "overflow holds the refresh instead of silently dropping generated-send evidence", c do
    for _ <- 1..128, do: action(c, "gmail_send")
    sample = %{internal_date: DateTime.utc_now()}
    assert {:ok, actions} = VoiceSamples.generated_writes(c.user, "gmail", [sample])
    assert length(actions) == 128
    action(c, "gmail_send")

    assert {:error, :voice_provenance_unavailable} =
             VoiceSamples.generated_writes(c.user, "gmail", [sample])
  end

  defp action(c, type) do
    {:ok, action} =
      TelegramAssistant.create_prepared_action(%{
        user_id: c.user,
        chat_id: c.run.chat_id,
        run_id: c.run.id,
        surface: "mobile",
        action_type: type,
        target_type: "voice_fixture",
        payload: %{"body" => "Generated sample"},
        preview_text: "Voice provenance fixture",
        status: "rejected",
        expires_at: DateTime.add(DateTime.utc_now(), 600)
      })

    action
  end
end
