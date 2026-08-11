defmodule Maraithon.PrivacyErasureTest.UnavailableRevoker do
  def revoke(_provider, _token), do: {:unavailable, :provider_unavailable}
end

defmodule Maraithon.PrivacyErasureTest.ExactConversationAdapter do
  def erase_user_batch(user_id, request_id, claim_token, opts) do
    send(Application.fetch_env!(:maraithon, :privacy_erasure_test_pid), {
      :exact_conversation_erasure,
      user_id,
      request_id,
      claim_token,
      opts
    })

    key = {__MODULE__, request_id}
    attempt = Process.get(key, 0)
    Process.put(key, attempt + 1)

    if attempt == 0 do
      {:ok, %{processed: 1, deferred: %{turns: 0}, retained_authority_rows: true}}
    else
      {:ok, %{processed: 0, deferred: %{turns: 0}, retained_authority_rows: true}}
    end
  end
end

defmodule Maraithon.PrivacyErasureTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Accounts.User
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.OAuth.Token
  alias Maraithon.Privacy.ErasureProviderRevocation
  alias Maraithon.Privacy.ErasureRequest
  alias Maraithon.PrivacyErasure
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.TelegramAssistant.PreparedAction
  alias Maraithon.TelegramAssistant.Run, as: AssistantRun
  alias Maraithon.TelegramConversations.Conversation

  @activation_evidence [
    evidence_id: "test:stopped-fleet:privacy-erasure",
    evidence_digest: :crypto.hash(:sha256, "privacy erasure stopped fleet evidence"),
    activated_by: "privacy-erasure@example.test",
    revision: String.duplicate("e", 40)
  ]

  setup context do
    previous = Application.get_env(:maraithon, PrivacyErasure)
    previous_test_pid = Application.get_env(:maraithon, :privacy_erasure_test_pid)

    on_exit(fn ->
      restore_env(PrivacyErasure, previous)
      restore_env(:privacy_erasure_test_pid, previous_test_pid)
    end)

    if context[:exact_runtime], do: activate_exact!()
    :ok
  end

  test "user request is monotonic, revokes access, and enqueues one stable job" do
    user = user_fixture("idempotent")
    {:ok, %{token: token}} = Accounts.create_session_for_user(user)

    {:ok, first} = PrivacyErasure.request_user(user.id, idempotency_key: "mobile-1")
    {:ok, second} = PrivacyErasure.request_user(user.id, idempotency_key: "mobile-1")

    assert first.id == second.id
    assert Accounts.get_active_session(token) == nil
    assert %User{privacy_erasure_requested_at: requested_at} = Accounts.get_user(user.id)
    assert %DateTime{} = requested_at

    job_query =
      from(job in BackgroundJob,
        where: job.dedupe_key == ^"privacy-erasure:#{first.id}"
      )

    assert Repo.aggregate(job_query, :count) == 1
    Repo.delete_all(job_query)
    assert {:ok, %{repaired: 1}} = PrivacyErasure.discover_missing_jobs(1)
    assert Repo.aggregate(job_query, :count) == 1
  end

  @tag exact_runtime: true
  test "Agent intent is durably fenced and deletion uses the Runtime lifecycle" do
    user = user_fixture("agent")

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user.id,
        behavior: "prompt_agent",
        status: "stopped"
      })

    {:ok, first} = PrivacyErasure.request_agent(agent.id, user_id: user.id)
    {:ok, second} = PrivacyErasure.request_agent(agent.id, user_id: user.id)

    assert first.id == second.id

    assert {:error, :privacy_erasure_requested} =
             Repo.transaction(fn -> WriteFence.ensure_agent_writable!(agent.id) end)

    final = drive_to_completion(first.id)
    assert final.state == "completed"
    assert final.scope == "agent"
    assert final.target_agent_count == 1
    assert final.receipt.classification == "content_free_erasure_authority_v1"
    assert final.receipt.local_data_deleted
    assert final.receipt.erased_agent_count == 1
    assert Repo.get(Agent, agent.id) == nil

    stored = Repo.get!(ErasureRequest, first.id)
    assert stored.subject_user_id == nil
    assert stored.subject_agent_id == nil
    assert stored.idempotency_digest == nil
  end

  @tag exact_runtime: true
  test "exact conversation erasure receives the live claim and bounded budget before final proof" do
    Application.put_env(:maraithon, :privacy_erasure_test_pid, self())

    Application.put_env(:maraithon, PrivacyErasure,
      conversation_erasure_adapter: Maraithon.PrivacyErasureTest.ExactConversationAdapter
    )

    user = user_fixture("exact-conversation")
    now = DatabaseClock.now!()

    conversation =
      %Conversation{}
      |> Conversation.changeset(%{
        user_id: user.id,
        chat_id: "privacy-chat",
        status: "open"
      })
      |> Repo.insert!()

    background_job =
      %BackgroundJob{}
      |> BackgroundJob.changeset(%{
        user_id: user.id,
        queue: "privacy-test",
        job_type: "privacy_test_work",
        scheduled_at: DateTime.add(now, 3_600, :second)
      })
      |> Repo.insert!()

    {:ok, request} = PrivacyErasure.request_user(user.id)
    assert Repo.get!(BackgroundJob, background_job.id).status == "cancelled"
    assert %{state: "erasing"} = drive_to_state(request.id, "erasing")

    assert {:ok, %{state: "erasing", blocker_code: "conversation_close_pending"}} =
             PrivacyErasure.perform(request.id)

    assert Repo.get!(Conversation, conversation.id).status == "closed"
    refute_received {:exact_conversation_erasure, _, _, _, _}

    assert {:ok,
            %{
              state: "erasing",
              blocker_code: "conversation_copy_cleanup_pending"
            }} = PrivacyErasure.perform(request.id)

    assert_receive {
      :exact_conversation_erasure,
      user_id,
      request_id,
      claim_token,
      [limit: 100, now: %DateTime{}]
    }

    assert user_id == user.id
    assert request_id == request.id
    assert {:ok, ^claim_token} = Ecto.UUID.cast(claim_token)

    final = drive_to_completion(request.id)
    assert final.state == "completed"
  end

  test "externally ambiguous prepared action blocks exact erasure without deleting authority" do
    Application.put_env(:maraithon, :privacy_erasure_test_pid, self())

    Application.put_env(:maraithon, PrivacyErasure,
      conversation_erasure_adapter: Maraithon.PrivacyErasureTest.ExactConversationAdapter
    )

    user = user_fixture("ambiguous-action")
    now = DatabaseClock.now!()

    conversation =
      %Conversation{}
      |> Conversation.changeset(%{
        user_id: user.id,
        chat_id: "ambiguous-chat",
        status: "awaiting_confirmation"
      })
      |> Repo.insert!()

    run =
      %AssistantRun{}
      |> AssistantRun.changeset(%{
        user_id: user.id,
        conversation_id: conversation.id,
        chat_id: "ambiguous-chat",
        surface: "telegram",
        trigger_type: "inbound_message",
        status: "waiting_confirmation",
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        started_at: now
      })
      |> Repo.insert!()

    action =
      %PreparedAction{}
      |> PreparedAction.changeset(%{
        user_id: user.id,
        conversation_id: conversation.id,
        run_id: run.id,
        chat_id: "ambiguous-chat",
        surface: "telegram",
        action_type: "send_external",
        target_type: "external",
        payload: %{"fixed" => true},
        preview_text: "confirmation",
        status: "confirmed",
        expires_at: DateTime.add(now, 300, :second)
      })
      |> Repo.insert!()

    {:ok, request} = PrivacyErasure.request_user(user.id)
    assert %{state: "erasing"} = drive_to_state(request.id, "erasing")

    assert {:ok,
            %{
              state: "erasing",
              blocker_code: "prepared_action_external_proof_required",
              receipt: nil
            }} = PrivacyErasure.perform(request.id)

    assert Repo.get!(PreparedAction, action.id).status == "confirmed"
    assert Repo.get!(AssistantRun, run.id).status == "waiting_confirmation"
    refute_received {:exact_conversation_erasure, _, _, _, _}
  end

  test "an unexpired claim is busy and an expired PostgreSQL-clock claim is reclaimed" do
    user = user_fixture("reclaim")
    {:ok, request} = PrivacyErasure.request_user(user.id)
    now = DatabaseClock.now!()

    Repo.update_all(
      from(candidate in ErasureRequest, where: candidate.id == ^request.id),
      set: [
        claim_token: Ecto.UUID.generate(),
        claimed_at: now,
        claim_expires_at: DateTime.add(now, 60, :second),
        updated_at: now
      ]
    )

    assert {:ok, %{busy: true, state: "requested"}} = PrivacyErasure.perform(request.id)

    db_now = DatabaseClock.now!()

    Repo.update_all(
      from(candidate in ErasureRequest, where: candidate.id == ^request.id),
      set: [
        claimed_at: DateTime.add(db_now, -2, :second),
        claim_expires_at: DateTime.add(db_now, -1, :second),
        updated_at: db_now
      ]
    )

    assert {:ok, %{state: "draining"}} = PrivacyErasure.perform(request.id)
  end

  test "corrupt credential ciphertext is raw-deleted and never blocks local erasure" do
    user = user_fixture("corrupt")

    {:ok, token} =
      %Token{}
      |> Token.changeset(%{
        user_id: user.id,
        provider: "google",
        access_token: "corrupt-after-insert"
      })
      |> Repo.insert()

    [[ciphertext]] =
      Repo.query!("SELECT access_token FROM oauth_tokens WHERE id = $1", [token.id]).rows

    last_index = byte_size(ciphertext) - 1

    corrupted_ciphertext =
      binary_part(ciphertext, 0, last_index) <>
        <<Bitwise.bxor(:binary.at(ciphertext, last_index), 1)>>

    Repo.query!(
      "UPDATE oauth_tokens SET access_token = $2, updated_at = clock_timestamp() WHERE id = $1",
      [token.id, corrupted_ciphertext]
    )

    {:ok, request} = PrivacyErasure.request_user(user.id)
    final = drive_to_completion(request.id)

    assert final.state == "completed"
    assert final.provider_revocation_outcome == "partial_unverified"
    assert final.receipt.provider_revocation_outcome == "partial_unverified"
    assert final.receipt.outcome == "completed"
    refute Repo.exists?(from(token in Token, where: token.user_id == ^user.id))

    assert %ErasureProviderRevocation{
             state: "unavailable",
             error_code: "credential_unreadable",
             attempt_count: 1
           } = Repo.get_by!(ErasureProviderRevocation, request_id: request.id)
  end

  test "provider unavailability is content-free partial proof and local deletion continues" do
    Application.put_env(:maraithon, PrivacyErasure,
      provider_revoker: Maraithon.PrivacyErasureTest.UnavailableRevoker
    )

    user = user_fixture("provider-unavailable")

    {:ok, _token} =
      %Token{}
      |> Token.changeset(%{
        user_id: user.id,
        provider: "google",
        access_token: "do-not-persist-this"
      })
      |> Repo.insert()

    {:ok, request} = PrivacyErasure.request_user(user.id)
    final = drive_to_completion(request.id)

    assert final.state == "completed"
    assert final.provider_revocation_outcome == "partial_unverified"
    assert final.receipt.provider_revocation_outcome == "partial_unverified"
    assert final.receipt.outcome == "completed"
    refute Repo.exists?(from(token in Token, where: token.user_id == ^user.id))

    assert %ErasureProviderRevocation{
             state: "unavailable",
             error_code: "provider_unavailable",
             attempt_count: 1
           } = Repo.get_by!(ErasureProviderRevocation, request_id: request.id)
  end

  defp activate_exact! do
    assert {:ok, attestation} =
             reset_runtime_role_after(fn ->
               CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)
             end)

    assert attestation in [:attested, :already_attested]

    assert {:ok, effect_activation} =
             reset_runtime_role_after(fn ->
               ProtocolCutover.activate(
                 [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
               )
             end)

    assert effect_activation in [:activated, :already_active]

    assert {:ok, runtime_activation} =
             reset_runtime_role_after(fn ->
               Repo.query!("SET LOCAL ROLE maraithon_activation_operator", [], log: false)

               CoordinationProtocol.activate(
                 [confirmation: CoordinationProtocol.activation_confirmation()] ++
                   @activation_evidence
               )
             end)

    assert runtime_activation in [:activated, :already_active]
  end

  defp reset_runtime_role_after(fun) do
    try do
      fun.()
    after
      Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    end
  end

  defp drive_to_state(request_id, desired_state) do
    Enum.reduce_while(1..20, nil, fn _attempt, _status ->
      assert {:ok, status} = PrivacyErasure.perform(request_id)

      if status.state == desired_state,
        do: {:halt, status},
        else: {:cont, status}
    end)
    |> case do
      %{state: ^desired_state} = status -> status
      _other -> flunk("erasure did not reach #{desired_state}")
    end
  end

  defp drive_to_completion(request_id) do
    Enum.reduce_while(1..200, nil, fn _attempt, _status ->
      assert {:ok, status} = PrivacyErasure.perform(request_id)

      if status.state == "completed",
        do: {:halt, status},
        else: {:cont, status}
    end)
    |> case do
      %{state: "completed"} = status -> status
      _other -> flunk("erasure did not complete in its bounded work budget")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:maraithon, key)
  defp restore_env(key, value), do: Application.put_env(:maraithon, key, value)

  defp user_fixture(prefix) do
    email = "privacy-#{prefix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    user
  end
end
