defmodule Maraithon.Accounts.EmailTemplatesTest do
  use ExUnit.Case, async: true

  alias Maraithon.Accounts.EmailTemplates

  test "magic_link returns branded reusable content" do
    link = "https://maraithon.fly.dev/auth/magic/test-token"

    email = EmailTemplates.magic_link(link)

    assert email.subject == "Your Maraithon sign-in link"
    assert email.text_body =~ "Sign in to Maraithon"
    assert email.text_body =~ link
    assert email.html_body =~ "Maraithon"
    assert email.html_body =~ link
    assert email.html_body =~ "If the button does not work"
  end

  test "magic_code returns mobile-friendly code content without a magic URL" do
    code = "ABCD-2345"

    email = EmailTemplates.magic_code(code)

    assert email.subject == "Your Maraithon sign-in code"
    assert email.text_body =~ "Sign in to Maraithon"
    assert email.text_body =~ code
    refute email.text_body =~ "/auth/magic/"
    assert email.html_body =~ code
    refute email.html_body =~ "/auth/magic/"
  end
end
