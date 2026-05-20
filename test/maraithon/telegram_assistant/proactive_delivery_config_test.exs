defmodule Maraithon.TelegramAssistant.ProactiveDeliveryConfigTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.ProactiveCandidate

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    %{original_assistant: original_assistant}
  end

  test "proactive delivery planner flag is dormant by default", %{
    original_assistant: original_assistant
  } do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.delete(original_assistant, :proactive_delivery_planner_enabled)
    )

    refute TelegramAssistant.proactive_delivery_planner_enabled?()
  end

  test "proactive delivery planner flag accepts explicit true values", %{
    original_assistant: original_assistant
  } do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant, proactive_delivery_planner_enabled: "yes")
    )

    assert TelegramAssistant.proactive_delivery_planner_enabled?()
  end

  test "enqueue_proactive_candidate delegates to the durable queue" do
    user_id = "delivery-config-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, %ProactiveCandidate{} = candidate} =
             TelegramAssistant.enqueue_proactive_candidate(%{
               user_id: user_id,
               source: "insight",
               source_id: "source-1",
               dedupe_key: "delegate:source-1",
               title: "Delegated candidate",
               body: "This candidate was enqueued through TelegramAssistant.",
               urgency: 0.5
             })

    assert candidate.status == "pending"
    assert candidate.dedupe_key == "delegate:source-1"
  end
end
