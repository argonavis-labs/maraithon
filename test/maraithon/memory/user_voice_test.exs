defmodule Maraithon.Memory.UserVoiceTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.{Accounts, ConnectedAccounts, OAuth}
  alias Maraithon.Delegations.Voice
  alias Maraithon.Memory.UserVoice

  setup do
    user = "voice-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(user)
    config = Application.get_env(:maraithon, Maraithon.Memory.Embedding, [])
    Application.put_env(:maraithon, Maraithon.Memory.Embedding, async_enabled: false)
    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Memory.Embedding, config) end)
    %{user: user}
  end

  test "mailbox profiles never overwrite or fall back to another account or legacy voice", c do
    work = account(c.user, "work")
    personal = account(c.user, "personal")
    refresh(c.user, nil, "Legacy style")
    first = refresh(c.user, work.provider, "Work style")

    assert {:error, :voice_profile_not_found} =
             UserVoice.get_profile(c.user, "gmail", provider: personal.provider)

    second = refresh(c.user, personal.provider, "Personal style")
    assert first.id != second.id
    assert first.metadata["account_id"] == work.id
    assert second.metadata["account_id"] == personal.id
    assert UserVoice.prompt_context(c.user, "gmail")["content"] == "Legacy style"

    assert UserVoice.prompt_context(c.user, "gmail", provider: work.provider)["content"] ==
             "Work style"

    assert UserVoice.prompt_context(c.user, "gmail", provider: personal.provider)["content"] ==
             "Personal style"

    assert {:ok, draft} =
             Maraithon.Drafts.create(
               c.user,
               %{
                 "channel" => "gmail",
                 "google_provider" => work.provider,
                 "purpose" => "Reply in my style"
               },
               llm_complete: fn params ->
                 prompt = List.last(params["messages"])["content"]
                 assert prompt =~ "Work style"
                 refute prompt =~ "Personal style"
                 refute prompt =~ "Legacy style"

                 {:ok,
                  %{
                    content:
                      Jason.encode!(%{"subject" => "Re: Question", "body" => "Yes, I can help."})
                  }}
               end
             )

    assert draft.voice_profile.memory_id == first.id
  end

  test "foreign, assistant, disconnected and ambiguous accounts cannot teach or expose user voice",
       c do
    other = "voice-other-#{Ecto.UUID.generate()}@example.invalid"
    {:ok, _} = Accounts.get_or_create_user_by_email(other)
    foreign = account(other, "foreign")
    assistant = account(c.user, "assistant", true)
    disconnected = account(c.user, "disconnected")
    disconnected |> Ecto.Changeset.change(status: "disconnected") |> Repo.update!()
    refresh(c.user, nil, "Legacy must not leak")

    for provider <- [foreign.provider, assistant.provider, disconnected.provider, "google"] do
      assert {:error, :voice_account_unavailable} =
               UserVoice.refresh_from_connectors(c.user, "gmail",
                 provider: provider,
                 sample_texts: ["Do not use these samples"],
                 llm_complete: fn _ -> flunk("unavailable account reached model") end
               )

      assert UserVoice.prompt_context(c.user, "gmail", provider: provider)["status"] == "missing"
    end
  end

  test "a turn keeps its voice across profile updates; new turns use the new version", c do
    work = account(c.user, "work")

    scope = %{
      "actor" => "as_user",
      "provider" => "gmail",
      "identity" => %{"provider" => work.provider}
    }

    refresh(c.user, work.provider, "Original style")
    frozen = Voice.freeze(%{}, c.user, scope)
    assert frozen["voice"]["source"] == "account_profile"
    assert frozen["voice"]["account_id"] == work.id

    refresh(c.user, work.provider, String.duplicate("Updated style. ", 100))
    assert Voice.freeze(frozen, c.user, scope) == frozen
    next = Voice.freeze(%{}, c.user, scope)
    assert next["voice"]["version"] != frozen["voice"]["version"]
    assert String.length(next["voice"]["content"]) == 800

    assistant = Voice.freeze(%{}, c.user, Map.put(scope, "actor", "as_assistant"))
    assert assistant["voice"]["source"] == "house"
    refute assistant["voice"]["content"] =~ "Updated style"
    assert assistant["voice"]["memory_id"] == nil
  end

  test "Gmail training consumes only human Sent mail, including when Google rewrites Message-ID",
       c do
    work = account(c.user, "work")
    account(c.user, "personal")
    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :gmail, [])
    Application.put_env(:maraithon, :gmail, api_base_url: "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:maraithon, :gmail, original) end)

    messages = [
      {"aa11", ["SENT"], "Human sample", "<human@example.invalid>", nil},
      {"aa22", ["SENT", "DRAFT"], "Draft sample", "<draft@example.invalid>", nil},
      {"aa33", ["SENT"], "Agent sample", "<Maraithon.action@maraithon.com>", nil},
      {"aa44", ["SENT"], "Rewritten agent sample", "<changed@gmail.com>",
       "<maraithon.old@maraithon.com>"},
      {"aa55", ["INBOX"], "Incoming sample", "<incoming@example.invalid>", nil}
    ]

    Bypass.expect_once(bypass, "GET", "/users/me/messages", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer voice-work"]
      respond(conn, %{"messages" => Enum.map(messages, fn {id, _, _, _, _} -> %{"id" => id} end)})
    end)

    for {id, labels, body, message_id, original_id} <- messages do
      Bypass.expect_once(bypass, "GET", "/users/me/messages/#{id}", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer voice-work"]

        headers = [
          %{"name" => "Message-ID", "value" => message_id},
          %{"name" => "From", "value" => "Kent <work@example.invalid>"}
        ]

        headers =
          if original_id,
            do: [%{"name" => "X-Google-Original-Message-ID", "value" => original_id} | headers],
            else: headers

        respond(conn, %{
          "id" => id,
          "threadId" => id,
          "internalDate" => "1789500000000",
          "labelIds" => labels,
          "payload" => %{
            "mimeType" => "text/plain",
            "headers" => headers,
            "body" => %{"data" => Base.url_encode64(body, padding: false)}
          }
        })
      end)
    end

    Bypass.expect_once(bypass, "GET", "/users/me/settings/sendAs", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer voice-work"]

      respond(conn, %{
        "sendAs" => [
          %{
            "sendAsEmail" => "work@example.invalid",
            "isPrimary" => true,
            "signature" => "<div>Kent</div>"
          }
        ]
      })
    end)

    assert {:ok, profile} =
             UserVoice.refresh_from_connectors(c.user, "gmail",
               provider: work.provider,
               sample_texts: ["Unverified supplied sample must not bypass provider authorship"],
               llm_complete: fn prompt ->
                 assert prompt =~ "Human sample"

                 for excluded <- [
                       "Draft sample",
                       "Agent sample",
                       "Rewritten agent sample",
                       "Incoming sample",
                       "Unverified supplied sample"
                     ],
                     do: refute(prompt =~ excluded)

                 {:ok, Jason.encode!(%{"content" => "Learned human style"})}
               end
             )

    assert profile.metadata["sample_count"] == 1

    assert profile.metadata["source_counts"] == %{
             "gmail" => 1,
             "cleaning_version" => 1,
             "excluded" => %{"not_sent" => 2, "generated" => 2},
             "cleaned" => %{}
           }

    assert profile.metadata["account_id"] == work.id
  end

  test "a failed voice refresh uses explicit style instead of its generic fallback", c do
    work = account(c.user, "work")

    assert {:ok, profile} =
             UserVoice.refresh_profile(c.user, "gmail",
               provider: work.provider,
               sample_texts: ["Human writing sample"],
               llm_complete: fn _ -> {:error, :rate_limited} end
             )

    assert profile.metadata["fallback_reason"]

    assert UserVoice.prompt_context(c.user, "gmail", provider: work.provider)["status"] ==
             "missing"

    snapshot =
      Voice.freeze(%{}, c.user, %{
        "actor" => "as_user",
        "provider" => "gmail",
        "identity" => %{"provider" => work.provider}
      })

    assert snapshot["voice"]["source"] == "explicit_style"
    refute snapshot["voice"]["memory_id"]
  end

  test "valid JSON without a learned profile cannot promote generic fallback guidance", c do
    work = account(c.user, "work")

    assert {:ok, profile} =
             UserVoice.refresh_profile(c.user, "gmail",
               provider: work.provider,
               sample_texts: ["A human writing sample"],
               llm_complete: fn _ -> {:ok, ~s({"summary":"No actual guidance"})} end
             )

    assert profile.metadata["fallback_reason"] == ":missing_voice_profile_content"

    assert UserVoice.prompt_context(c.user, "gmail", provider: work.provider)["status"] ==
             "missing"
  end

  test "an older unaudited profile remains stored but cannot guide a new turn", c do
    work = account(c.user, "work")
    profile = refresh(c.user, work.provider, "An old profile containing quoted text")

    profile
    |> Maraithon.Memory.Item.changeset(%{
      metadata: Map.delete(profile.metadata, "sample_cleaning_version")
    })
    |> Repo.update!()

    assert {:ok, _} = UserVoice.get_profile(c.user, "gmail", provider: work.provider)
    context = UserVoice.prompt_context(c.user, "gmail", provider: work.provider)
    assert context["status"] == "missing"
    assert context["reason"] == ":voice_profile_needs_refresh"
    refute context["content"] =~ "quoted text"

    snapshot =
      Voice.freeze(%{}, c.user, %{
        "actor" => "as_user",
        "provider" => "gmail",
        "identity" => %{"provider" => work.provider}
      })

    assert snapshot["voice"]["source"] == "explicit_style"
  end

  test "Slack refresh verifies token identity and each returned author before the model", c do
    bypass = slack_account(c.user)

    Bypass.expect_once(bypass, "POST", "/api/auth.test", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer voice-slack"]
      respond(conn, %{"ok" => true, "team_id" => "TWORK", "user_id" => "UKENT"})
    end)

    Bypass.expect_once(bypass, "GET", "/api/search.messages", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer voice-slack"]
      assert URI.decode_query(conn.query_string)["query"] == "a broad query"
      base = %{"user" => "UKENT", "team" => "TWORK", "ts" => "1789500000.000001"}

      messages = [
        Map.put(base, "text", "My actual answer.\n> Another person's question"),
        Map.merge(base, %{"user" => "USAM", "text" => "Someone else's style"}),
        Map.merge(base, %{"team" => "TOTHER", "text" => "Other workspace"}),
        Map.merge(base, %{"bot_id" => "B123", "text" => "Bot writing"})
      ]

      respond(conn, %{"ok" => true, "messages" => %{"matches" => messages}})
    end)

    assert {:ok, profile} =
             UserVoice.refresh_from_connectors(c.user, "slack",
               provider: "slack:TWORK:user:UKENT",
               slack_query: "a broad query",
               llm_complete: fn prompt ->
                 assert prompt =~ "My actual answer."

                 for excluded <- [
                       "Another person's",
                       "Someone else's",
                       "Other workspace",
                       "Bot writing"
                     ],
                     do: refute(prompt =~ excluded)

                 {:ok, Jason.encode!(%{"content" => "Short Slack answers"})}
               end
             )

    assert profile.metadata["sample_count"] == 1

    assert profile.metadata["source_counts"]["excluded"] == %{
             "other_author" => 1,
             "other_workspace" => 1,
             "automated" => 1
           }

    assert profile.metadata["source_counts"]["cleaned"] == %{"quotes" => 1}
  end

  for auth <- [
        %{"team_id" => "TWORK", "user_id" => "UOTHER"},
        %{"team_id" => "TOTHER", "user_id" => "UKENT"},
        %{"team_id" => "TWORK", "user_id" => "UKENT", "bot_id" => "B123"}
      ] do
    test "Slack identity mismatch #{inspect(auth)} never searches or calls a model", c do
      bypass = slack_account(c.user)

      Bypass.expect_once(bypass, "POST", "/api/auth.test", fn conn ->
        respond(conn, Map.put(unquote(Macro.escape(auth)), "ok", true))
      end)

      assert {:error, :voice_identity_unavailable} =
               UserVoice.refresh_from_connectors(c.user, "slack",
                 provider: "slack:TWORK:user:UKENT",
                 llm_complete: fn _ -> flunk("wrong Slack identity reached voice model") end
               )
    end
  end

  defp slack_account(user) do
    {:ok, _} =
      OAuth.store_tokens(user, "slack:TWORK:user:UKENT", %{
        access_token: "voice-slack",
        scopes: ["search:read"],
        expires_in: 3600
      })

    bypass = Bypass.open()
    original = Application.get_env(:maraithon, :slack, [])
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}/api")
    on_exit(fn -> Application.put_env(:maraithon, :slack, original) end)
    bypass
  end

  defp account(user, name, assistant? \\ false) do
    provider = "google:#{name}@example.invalid"

    {:ok, _} =
      OAuth.store_tokens(user, provider, %{
        access_token: "voice-#{name}",
        expires_in: 3600,
        metadata: %{"assistant_account" => assistant?}
      })

    ConnectedAccounts.get(user, provider)
  end

  defp refresh(user, provider, content) do
    {:ok, profile} =
      UserVoice.refresh_profile(user, "gmail",
        provider: provider,
        sample_texts: ["Human writing sample"],
        llm_complete: fn _ -> {:ok, Jason.encode!(%{"content" => content})} end
      )

    profile
  end

  defp respond(conn, payload),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(payload))
end
