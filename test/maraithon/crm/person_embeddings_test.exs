defmodule Maraithon.Crm.PersonEmbeddingsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.PersonEmbeddings

  setup do
    user_id = "person-embed-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  describe "source_text/1" do
    test "combines name, relationship, contact, and notes excerpt", %{user_id: user_id} do
      {:ok, person} =
        Crm.upsert_person(user_id, %{
          "first_name" => "Charlie",
          "last_name" => "Smith",
          "display_name" => "Charlie Smith",
          "relationship" => "Runner GTM teammate",
          "preferred_communication_method" => "slack",
          "communication_frequency" => "weekly",
          "email" => "charlie@example.com",
          "notes" => "Prefers short Slack pings."
        })

      text = PersonEmbeddings.source_text(person)
      assert text =~ "Charlie Smith"
      assert text =~ "Runner GTM teammate"
      assert text =~ "prefers slack"
      assert text =~ "talks weekly"
      assert text =~ "charlie@example.com"
      assert text =~ "Prefers short Slack pings"
    end

    test "returns empty string for an unsaved struct" do
      assert PersonEmbeddings.source_text(%Maraithon.Crm.Person{}) == ""
    end
  end

  describe "refresh/2" do
    test "writes an embedding using a custom provider", %{user_id: user_id} do
      {:ok, person} =
        Crm.upsert_person(user_id, %{
          "display_name" => "Charlie Smith",
          "relationship" => "Runner GTM teammate"
        })

      provider = fn _text ->
        {:ok, List.duplicate(0.1, Maraithon.LLM.Embeddings.dimension())}
      end

      assert {:ok, refreshed} = PersonEmbeddings.refresh(person, provider: provider)
      assert refreshed.embedding_source_hash == PersonEmbeddings.source_hash(person)
      assert refreshed.embedding_refreshed_at
      refute is_nil(refreshed.embedding)
    end

    test "skips when source is unchanged", %{user_id: user_id} do
      {:ok, person} = Crm.upsert_person(user_id, %{"display_name" => "Charlie Smith"})

      provider = fn _text ->
        {:ok, List.duplicate(0.1, Maraithon.LLM.Embeddings.dimension())}
      end

      {:ok, refreshed} = PersonEmbeddings.refresh(person, provider: provider)

      # Calling again with the same source text should be a no-op.
      counter_pid = self()

      counting_provider = fn text ->
        send(counter_pid, :provider_called)
        provider.(text)
      end

      assert {:ok, :unchanged} =
               PersonEmbeddings.refresh(refreshed, provider: counting_provider)

      refute_receive :provider_called, 100
    end
  end
end
