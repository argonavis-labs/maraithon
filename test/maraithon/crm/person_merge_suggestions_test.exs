defmodule Maraithon.Crm.PersonMergeSuggestionsTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Crm
  alias Maraithon.Crm.PersonEmbeddings
  alias Maraithon.Crm.PersonMergeSuggestions
  alias Maraithon.TelegramAssistant.PreparedAction

  setup do
    original_insights = Application.get_env(:maraithon, :insights, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: Maraithon.TestSupport.FakeTelegram)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
    end)

    user_id = "merge-suggest-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "54321",
        metadata: %{"username" => "merge-suggest"}
      })

    %{user_id: user_id}
  end

  test "a model-confirmed soft pair produces a PreparedAction, never a direct merge; deduper-eligible pairs are excluded",
       %{user_id: user_id} do
    # Soft pair: "Dan" (Slack only) and "Dan Bourke" (email only) — no shared
    # durable identifier, not an exact multi-token name match, so the
    # deterministic deduper deliberately stays silent on them.
    {:ok, dan_short} =
      Crm.create_person(user_id, %{"display_name" => "Dan", "slack_id" => "UDAN"})

    {:ok, dan_full} =
      Crm.create_person(user_id, %{"display_name" => "Dan Bourke", "email" => "dan@runner.now"})

    # Deduper-eligible pair: shared durable email — must be excluded from the
    # soft-match tier even though their embeddings are identical.
    {:ok, eve_a} =
      Crm.create_person(user_id, %{"display_name" => "Eve Chan", "email" => "eve@runner.now"})

    {:ok, eve_b} =
      Crm.create_person(user_id, %{"display_name" => "Evelyn Chan", "email" => "eve@runner.now"})

    seed_embedding([dan_short, dan_full], basis_vector(0))
    seed_embedding([eve_a, eve_b], basis_vector(1))

    llm_calls = :counters.new(1, [])

    llm_complete = fn params ->
      :counters.add(llm_calls, 1, 1)
      content = get_in(params, ["messages", Access.at(0), "content"])
      assert content =~ "PERSON_MERGE_JUDGMENT_JSON_V1"
      assert content =~ "Dan Bourke"
      # The deduper-eligible pair never reaches the model.
      refute content =~ "Eve Chan"

      {:ok,
       %{
         content:
           Jason.encode!(%{
             "judgments" => [
               %{
                 "pair_index" => 0,
                 "same_person" => true,
                 "confidence" => 0.9,
                 "evidence" => "Same person across Slack and email in the GTM launch threads.",
                 "rationale" => "Dan on Slack signs off as Dan Bourke."
               }
             ]
           })
       }}
    end

    assert {:ok, summary} = PersonMergeSuggestions.run(user_id, llm_complete: llm_complete)

    assert summary.pairs_found == 2
    assert summary.excluded_deterministic == 1
    assert summary.judged == 1
    assert summary.proposed == 1
    assert :counters.get(llm_calls, 1) == 1

    pair_ids = MapSet.new([dan_short.id, dan_full.id])

    assert [prepared_action] =
             Repo.all(
               from(pa in PreparedAction,
                 where: pa.user_id == ^user_id and pa.action_type == "merge_people"
               )
             )

    assert prepared_action.status == "awaiting_confirmation"

    assert MapSet.new([
             prepared_action.payload["surviving_person_id"],
             prepared_action.payload["merged_person_id"]
           ]) == pair_ids

    assert prepared_action.payload["evidence"] =~ "GTM launch"
    assert prepared_action.payload["performed_by"] == "person_merge_suggestions"

    # Never auto-merged: both records must still be active, untouched.
    assert Crm.get_person_for_user(user_id, dan_short.id).status == "active"
    assert Crm.get_person_for_user(user_id, dan_full.id).status == "active"

    # R11: both people carry the pending candidate marker for the read path.
    reloaded_dan = Crm.get_person_for_user(user_id, dan_full.id)
    assert %{"status" => "pending"} = reloaded_dan.metadata["merge_suggestion"]

    assert {:ok, context} = Crm.relationship_context(user_id, %{"person_id" => dan_full.id})
    assert context.possible_duplicate.person_id == dan_short.id
  end

  test "a low-confidence or unconfirmed judgment produces no prepared action", %{
    user_id: user_id
  } do
    {:ok, dan_short} = Crm.create_person(user_id, %{"display_name" => "Dan"})
    {:ok, dan_full} = Crm.create_person(user_id, %{"display_name" => "Dan Bourke"})

    seed_embedding([dan_short, dan_full], basis_vector(0))

    low_llm = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "judgments" => [
               %{
                 "pair_index" => 0,
                 "same_person" => true,
                 "confidence" => 0.4,
                 "evidence" => "Names look similar."
               }
             ]
           })
       }}
    end

    assert {:ok, summary} = PersonMergeSuggestions.run(user_id, llm_complete: low_llm)
    assert summary.judged == 1
    assert summary.proposed == 0
    assert summary.declined == 1

    assert Repo.all(
             from(pa in PreparedAction,
               where: pa.user_id == ^user_id and pa.action_type == "merge_people"
             )
           ) == []
  end

  test "a rejected pair is not re-surfaced on the next run", %{user_id: user_id} do
    {:ok, dan_short} = Crm.create_person(user_id, %{"display_name" => "Dan"})
    {:ok, dan_full} = Crm.create_person(user_id, %{"display_name" => "Dan Bourke"})

    seed_embedding([dan_short, dan_full], basis_vector(0))

    confident_llm = fn _params ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "judgments" => [
               %{
                 "pair_index" => 0,
                 "same_person" => true,
                 "confidence" => 0.95,
                 "evidence" => "Clearly the same person."
               }
             ]
           })
       }}
    end

    assert {:ok, first} = PersonMergeSuggestions.run(user_id, llm_complete: confident_llm)
    assert first.proposed == 1

    [prepared_action] =
      Repo.all(
        from(pa in PreparedAction,
          where: pa.user_id == ^user_id and pa.action_type == "merge_people"
        )
      )

    # The user taps Cancel: the "no" must not be re-litigated every cycle.
    {:ok, _rejected} =
      prepared_action
      |> Ecto.Changeset.change(%{status: "rejected"})
      |> Repo.update()

    assert {:ok, second} = PersonMergeSuggestions.run(user_id, llm_complete: confident_llm)
    assert second.excluded_previously_surfaced == 1
    assert second.judged == 0
    assert second.proposed == 0

    assert Repo.aggregate(
             from(pa in PreparedAction,
               where: pa.user_id == ^user_id and pa.action_type == "merge_people"
             ),
             :count
           ) == 1
  end

  defp seed_embedding(people, vector) do
    Enum.each(people, fn person ->
      {:ok, _refreshed} =
        PersonEmbeddings.refresh(person, provider: fn _text -> {:ok, vector} end)
    end)
  end

  defp basis_vector(index) do
    Maraithon.LLM.Embeddings.dimension()
    |> then(&List.duplicate(0.0, &1))
    |> List.replace_at(index, 1.0)
  end
end
