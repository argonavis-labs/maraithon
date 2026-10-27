defmodule Maraithon.Memory.VoiceSamplesTest do
  use ExUnit.Case, async: true
  alias Maraithon.Memory.VoiceSamples

  @gmail %{
    "google:work" => %{
      "authors" => ["kent@example.invalid"],
      "signatures" => ["Kent Fenwick\nRunner"]
    }
  }
  @slack %{"slack" => %{"authors" => ["UKENT"], "team" => "TWORK"}}

  test "email samples retain authored text and count removed quotes, signatures and footers" do
    messages = [
      gmail(
        "Can do.\n\nKent Fenwick\n\nRunner\n\nOn Tuesday, Sam\n<sam@example.invalid> wrote:\nA request"
      ),
      gmail("Here's the answer.\n> Quoted question\n\nSent from my iPhone"),
      gmail("Third answer.\n\n+++\nKent"),
      gmail("Third answer.")
    ]

    assert {:ok, ["Can do.", "Here's the answer.", "Third answer."], counts} =
             VoiceSamples.collect(messages, "gmail", @gmail, [])

    assert counts["excluded"] == %{"duplicate" => 1}
    assert counts["cleaned"] == %{"quotes" => 2, "signature" => 1, "footer" => 2}
  end

  test "forwarded, automated, ambiguous, incoming and undated mail cannot teach voice" do
    messages = [
      gmail("FYI\n---------- Forwarded message ---------\nSomeone else's words"),
      gmail("Something", %{subject: "Fwd: A message"}),
      gmail("Something", %{auto_submitted: " Auto-Replied "}),
      gmail("Something", %{precedence: " BULK "}),
      gmail("Something", %{return_path: " <> "}),
      gmail("Something", %{list_id: "newsletter.example.invalid"}),
      gmail("Something", %{from: "Sam <sam@example.invalid>"}),
      gmail("Something", %{from: "kent@example.invalid, sam@example.invalid"}),
      gmail("Something", %{labels: ["INBOX"]}),
      gmail("Something", %{internal_date: nil}),
      gmail("> Only someone else's words"),
      gmail("Authored", %{auto_submitted: " No "})
    ]

    assert {:ok, ["Authored"], counts} = VoiceSamples.collect(messages, "gmail", @gmail, [])

    assert counts["excluded"] == %{
             "forwarded" => 2,
             "automated" => 4,
             "other_author" => 2,
             "not_sent" => 1,
             "unverified_date" => 1,
             "empty_after_cleaning" => 1
           }
  end

  test "HTML fallback removes quoted history and renders signatures without link annotations" do
    html =
      "<div>Let's do it.</div><div>Kent Fenwick<br>Runner</div><div class=\"gmail_quote\">Other person's words</div>"

    blockquote =
      "<p>Try the <a href=\"https://example.invalid\">link</a>.</p><blockquote>Quoted</blockquote>"

    assert {:ok, ["Let's do it.", "Try the link."], counts} =
             VoiceSamples.collect(
               [gmail(html, %{html_body: html}), gmail(nil, %{html_body: blockquote})],
               "gmail",
               @gmail,
               []
             )

    assert counts["cleaned"] == %{"signature" => 1, "quotes" => 2}
  end

  test "actual plain text preserves angle addresses and code" do
    text = "Use <code> and ask <sam@example.invalid>."

    assert {:ok, [^text], _} =
             VoiceSamples.collect(
               [gmail(text, %{html_body: "<p>Other version</p>"})],
               "gmail",
               @gmail,
               []
             )
  end

  test "both Gmail message IDs and provider receipts exclude generated mail" do
    action = %{
      id: "action",
      payload: %{"_maraithon_reconciliation_receipt" => %{"message_id" => "receipt"}}
    }

    messages = [
      gmail("Generated one", %{internet_message_id: " <Maraithon.one@maraithon.com> "}),
      gmail("Generated two", %{original_internet_message_id: "<maraithon.two@maraithon.com>"}),
      gmail("Generated three", %{message_id: "receipt"}),
      gmail("Human writing")
    ]

    assert {:ok, ["Human writing"], counts} =
             VoiceSamples.collect(messages, "gmail", @gmail, [action])

    assert counts["excluded"] == %{"generated" => 3}
  end

  test "Slack search evidence must belong to the frozen member and workspace" do
    messages = [
      slack("My answer.\n&gt; Quoted words"),
      slack("Other author", %{"user" => "UOTHER"}),
      slack("Other team", %{"team" => "TOTHER"}),
      slack("Bot", %{"bot_id" => "B123"}),
      slack("App", %{"app_id" => "A123"}),
      slack("System", %{"subtype" => "channel_join"}),
      slack("No author", %{"user" => nil})
    ]

    assert {:ok, ["My answer."], counts} = VoiceSamples.collect(messages, "slack", @slack, [])
    assert counts["excluded"] == %{"other_author" => 2, "other_workspace" => 1, "automated" => 3}
    assert counts["cleaned"] == %{"quotes" => 1}
  end

  test "Slack action ID, accepted receipt and uncertain body all exclude generated evidence" do
    actions = [
      %{id: "action-id", payload: %{}},
      %{
        id: "receipt-id",
        payload: %{
          "_maraithon_execution_result" => %{"ts" => "1789500000.000003", "channel" => "CWORK"}
        }
      },
      %{id: "uncertain-id", payload: %{"text" => "Generated  pending text"}}
    ]

    messages = [
      slack("First", %{"client_msg_id" => "action-id"}),
      slack("Second", %{"ts" => "1789500000.000003"}),
      slack("Generated pending text"),
      slack("Human reply")
    ]

    assert {:ok, ["Human reply"], counts} =
             VoiceSamples.collect(messages, "slack", @slack, actions)

    assert counts["excluded"] == %{"generated" => 3}
  end

  defp gmail(text, attrs \\ %{}),
    do:
      Map.merge(
        %{
          google_provider: "google:work",
          internal_date: ~U[2026-09-15 19:00:00Z],
          labels: ["SENT"],
          from: "Kent <KENT@example.invalid>",
          text_body: text
        },
        attrs
      )

  defp slack(text, attrs \\ %{}),
    do:
      Map.merge(
        %{
          "team" => "TWORK",
          "user" => "UKENT",
          "ts" => "1789500000.000001",
          "channel" => %{"id" => "CWORK"},
          "text" => text
        },
        attrs
      )
end
