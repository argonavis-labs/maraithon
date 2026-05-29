defmodule Maraithon.DeliveryErrorCopyTest do
  use ExUnit.Case, async: true

  alias Maraithon.DeliveryErrorCopy

  test "stores product-safe copy instead of provider bodies or tokens" do
    copy =
      DeliveryErrorCopy.storage_message(
        {:telegram_error, 500, "RuntimeError token=secret stacktrace %{chat_id: 123}"}
      )

    assert copy == "Telegram is temporarily unavailable. Try again in a minute."
    refute copy =~ "token"
    refute copy =~ "stacktrace"
    refute copy =~ "chat_id"
  end

  test "maps terminal Telegram delivery failures to stable copy" do
    missing_chat = DeliveryErrorCopy.storage_message(:missing_chat_id)
    blocked = DeliveryErrorCopy.storage_message({:telegram_error, 403, "bot was blocked by user"})

    assert missing_chat ==
             "Telegram is not linked yet. Connect Telegram before sending this message."

    assert blocked == "Telegram needs reconnecting before delivery can continue."
    assert DeliveryErrorCopy.terminal?(missing_chat)
    assert DeliveryErrorCopy.terminal?(blocked)
  end

  test "keeps legacy terminal values recognized for retry suppression" do
    assert DeliveryErrorCopy.terminal?(":missing_chat_id")
    assert DeliveryErrorCopy.terminal?("missing_chat_id")
    assert DeliveryErrorCopy.terminal?(":telegram_not_connected")
  end
end
