defmodule Maraithon.TelegramAssistant.PushReceiptCompatibilityTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.PushReceipt

  test "in-flight and ambiguous decisions block older delivery workers" do
    user_id = "push-receipt-compat-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    for decision <- ["reserved", "sending", "delivery_unknown"] do
      dedupe_key = "compat:#{decision}"

      assert {:ok, %PushReceipt{decision: ^decision}} =
               TelegramAssistant.record_push_receipt(%{
                 user_id: user_id,
                 dedupe_key: dedupe_key,
                 origin_type: "brief",
                 origin_id: Ecto.UUID.generate(),
                 decision: decision
               })

      assert %PushReceipt{decision: ^decision} =
               TelegramAssistant.push_receipt_for(user_id, dedupe_key)
    end
  end
end
