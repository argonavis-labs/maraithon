defmodule Maraithon.DraftsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Drafts
  alias Maraithon.Memory.UserVoice

  test "refresh_profile stores channel-specific user voice in durable memory" do
    user_id = "draft-voice-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    llm_complete = fn prompt ->
      assert prompt =~ "Build a durable gmail writing voice profile"
      assert prompt =~ "Sent message samples JSON"

      {:ok,
       ~s({"summary":"Short direct email voice.","content":"Use short, direct replies with concrete next steps. No em dashes.","do":["be direct"],"avoid":["filler"],"confidence":0.86})}
    end

    assert {:ok, memory} =
             UserVoice.refresh_profile(user_id, "email",
               sample_texts: ["Yep, sounds good. I'll send it tomorrow."],
               llm_complete: llm_complete
             )

    assert memory.kind == "instruction"
    assert memory.source == "user_voice"
    assert memory.source_ref_type == "user_voice_profile"
    assert memory.source_ref_id == "gmail"
    assert memory.dedupe_key == "user_voice:gmail"
    assert "user_voice" in memory.tags
    assert "gmail" in memory.tags
    assert memory.metadata["sample_count"] == 1

    context = UserVoice.prompt_context(user_id, "gmail")
    assert context["status"] == "available"
    assert context["memory_id"] == memory.id
    assert context["content"] =~ "short, direct"
  end

  test "create generates a voice-aware Gmail draft and removes em dashes and assistant sign-offs" do
    user_id = "draft-create-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _memory} =
      UserVoice.refresh_profile(user_id, "gmail",
        sample_texts: ["Can do. I'll send the details this afternoon."],
        llm_complete: fn _prompt ->
          {:ok,
           ~s({"summary":"Direct concise email voice.","content":"Write short replies with concrete next steps. No em dashes.","do":["be specific"],"avoid":["generic filler"],"confidence":0.9})}
        end
      )

    test_pid = self()

    draft_llm = fn params ->
      prompt = params |> Map.fetch!("messages") |> List.last() |> Map.fetch!("content")
      send(test_pid, {:draft_prompt, prompt})

      {:ok,
       %{
         content:
           ~s({"subject":"Re: Launch — next steps","body":"Hi Sam,\\n\\nI'll send the launch note today — then follow with the pricing detail tomorrow.\\n\\nBest,\\nMaraithon"})
       }}
    end

    assert {:ok, result} =
             Drafts.create(
               user_id,
               %{
                 "channel" => "gmail",
                 "purpose" => "reply about the launch note and pricing detail",
                 "recipient" => "Sam",
                 "subject" => "Launch next steps",
                 "context" => %{"source" => "test"}
               },
               llm_complete: draft_llm
             )

    assert_receive {:draft_prompt, prompt}
    assert prompt =~ "User voice and memory JSON"
    assert prompt =~ "Write short replies with concrete next steps"
    assert prompt =~ "Do not use em dashes"

    assert result.channel == "gmail"
    assert result.voice_profile.status == "available"
    refute result.draft["subject"] =~ "—"
    refute result.draft["body"] =~ "—"
    refute result.draft["body"] =~ "Maraithon"
    assert result.draft["body"] =~ "I'll send the launch note today"
  end

  test "create returns Slack draft text without posting when provider save is requested" do
    user_id = "draft-slack-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    draft_llm = fn _params ->
      {:ok, %{content: ~s({"text":"I can take this — ETA is tomorrow."})}}
    end

    assert {:ok, result} =
             Drafts.create(
               user_id,
               %{
                 "channel" => "slack",
                 "purpose" => "reply with ownership and ETA",
                 "save_to_provider" => true
               },
               llm_complete: draft_llm
             )

    assert result.channel == "slack"
    assert result.provider_draft == nil
    assert :slack_provider_drafts_not_supported in result.warnings
    refute result.draft["text"] =~ "—"
    assert result.draft["text"] =~ "I can take this"
  end
end
