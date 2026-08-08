defmodule Maraithon.Accounts.MagicLinkSenderTest do
  use ExUnit.Case, async: true

  alias Maraithon.Accounts.MagicLinkSender

  test "classifies inactive recipients without retaining the provider body" do
    response = %{
      "ErrorCode" => 406,
      "Message" => "inactive recipient: private@example.com"
    }

    assert MagicLinkSender.provider_failure_code(response) == "inactive_recipient"
  end

  test "classifies other bounded Postmark codes and malformed bodies safely" do
    assert MagicLinkSender.provider_failure_code(%{"ErrorCode" => 405}) ==
             "postmark_error_405"

    assert MagicLinkSender.provider_failure_code(%{"Message" => "private content"}) ==
             "provider_rejected"
  end
end
