defmodule Maraithon.RedactionTest do
  use ExUnit.Case, async: true

  alias Maraithon.Redaction

  describe "redact/1 with maps" do
    test "redacts known sensitive field names" do
      assert Redaction.redact(%{"api_key" => "sk-real", "name" => "kent"}) ==
               %{"api_key" => "<redacted>", "name" => "kent"}
    end

    test "is case-insensitive on field names" do
      assert Redaction.redact(%{"ApiKey" => "x", "Password" => "y"}) ==
               %{"ApiKey" => "<redacted>", "Password" => "<redacted>"}
    end

    test "redacts atom keys too" do
      assert Redaction.redact(%{access_token: "x", note: "ok"}) ==
               %{access_token: "<redacted>", note: "ok"}
    end

    test "recurses into nested maps" do
      input = %{
        "user" => %{"refresh_token" => "real", "name" => "kent"},
        "ok" => true
      }

      assert Redaction.redact(input) ==
               %{"user" => %{"refresh_token" => "<redacted>", "name" => "kent"}, "ok" => true}
    end

    test "leaves non-sensitive primitives alone" do
      assert Redaction.redact(%{"count" => 5, "active" => true, "name" => nil}) ==
               %{"count" => 5, "active" => true, "name" => nil}
    end
  end

  describe "redact_string/1" do
    test "scrubs Bearer tokens" do
      assert Redaction.redact_string("Authorization: Bearer abc.def.ghi") =~ "<redacted-auth>"
    end

    test "scrubs JWTs" do
      jwt =
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

      assert Redaction.redact_string(jwt) == "<redacted-jwt>"
    end

    test "scrubs OpenAI keys" do
      assert Redaction.redact_string("key=sk-proj-AAAAAAAAAAAAAAAAAAAAAA more text") =~
               "<redacted-openai-key>"
    end

    test "scrubs Anthropic keys" do
      assert Redaction.redact_string("sk-ant-api03-AAAAAAAAAAAAAAAAAAAA") =~
               "<redacted-anthropic-key>"
    end

    test "scrubs OpenRouter keys" do
      assert Redaction.redact_string("sk-or-v1-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") =~
               "<redacted-openrouter-key>"
    end

    test "scrubs Slack tokens" do
      assert Redaction.redact_string("xoxb-1234567890-ABCDEFGHIJ") =~ "<redacted-slack-token>"
    end

    test "scrubs cookie values" do
      assert Redaction.redact_string("set-cookie: session=abc123; Path=/") =~
               "set-cookie: session=<redacted>"
    end

    test "scrubs assignment-style secrets in error strings" do
      text =
        ~s({:api_failed, "OPENROUTER_API_KEY=sk-live token=secret client_secret='hidden'"})

      result = Redaction.redact_string(text)

      assert result =~ "OPENROUTER_API_KEY=<redacted>"
      assert result =~ "token=<redacted>"
      assert result =~ "client_secret=<redacted>"
      refute result =~ "sk-live"
      refute result =~ "token=secret"
      refute result =~ "hidden"
    end

    test "leaves clean strings alone" do
      assert Redaction.redact_string("hello world") == "hello world"
    end
  end

  describe "redact/1 against complex payloads" do
    test "scrubs both shaped fields and embedded credential strings" do
      payload = %{
        "request" => %{
          "headers" => "Authorization: Bearer xyz123",
          "api_key" => "secret"
        },
        "messages" => [
          %{"content" => "Hi, my OpenAI key is sk-proj-DEADBEEFDEADBEEFDEADBEEF"}
        ]
      }

      result = Redaction.redact(payload)

      assert result["request"]["api_key"] == "<redacted>"
      assert result["request"]["headers"] =~ "<redacted-auth>"
      assert hd(result["messages"])["content"] =~ "<redacted-openai-key>"
    end
  end
end
