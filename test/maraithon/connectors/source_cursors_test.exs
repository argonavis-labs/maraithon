defmodule Maraithon.Connectors.SourceCursorsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors

  setup do
    user_id = "source-cursors-#{System.unique_integer([:positive])}@example.com"
    provider = "google:#{System.unique_integer([:positive])}@example.com"

    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_from_oauth(user_id, provider, %{
        access_token: "token",
        scopes: ["gmail"]
      })

    %{account: account}
  end

  describe "monotonic guard for poll-watermark kinds" do
    test "never moves gmail_poll_watermark backwards", %{account: account} do
      {:ok, _cursor} = SourceCursors.put(account, "gmail_poll_watermark", %{"value" => "2000"})

      {:ok, _cursor} = SourceCursors.put(account, "gmail_poll_watermark", %{"value" => "1000"})

      assert %{value: "2000"} = SourceCursors.get(account.id, "gmail_poll_watermark")
    end

    test "still advances gmail_poll_watermark forward", %{account: account} do
      {:ok, _cursor} = SourceCursors.put(account, "gmail_poll_watermark", %{"value" => "1000"})

      {:ok, _cursor} = SourceCursors.put(account, "gmail_poll_watermark", %{"value" => "2000"})

      assert %{value: "2000"} = SourceCursors.get(account.id, "gmail_poll_watermark")
    end

    test "never moves slack_watermark backwards", %{account: account} do
      {:ok, _cursor} = SourceCursors.put(account, "slack_watermark", %{"value" => "2000"})

      {:ok, _cursor} = SourceCursors.put(account, "slack_watermark", %{"value" => "1500"})

      assert %{value: "2000"} = SourceCursors.get(account.id, "slack_watermark")
    end

    test "keeps discovery and closure role cursors independently monotonic", %{account: account} do
      {:ok, _cursor} =
        SourceCursors.put(account, "gmail_discovery_watermark", %{"value" => "2000"})

      {:ok, _cursor} =
        SourceCursors.put(account, "gmail_closure_watermark", %{"value" => "1500"})

      {:ok, _cursor} =
        SourceCursors.put(account, "gmail_discovery_watermark", %{"value" => "1000"})

      {:ok, _cursor} =
        SourceCursors.put(account, "gmail_closure_watermark", %{"value" => "2500"})

      assert %{value: "2000"} =
               SourceCursors.get(account.id, "gmail_discovery_watermark")

      assert %{value: "2500"} =
               SourceCursors.get(account.id, "gmail_closure_watermark")
    end

    test "does not guard non-numeric values, matching the prior unconditional replace", %{
      account: account
    } do
      {:ok, _cursor} = SourceCursors.put(account, "gmail_poll_watermark", %{"value" => "2000"})

      {:ok, _cursor} =
        SourceCursors.put(account, "gmail_poll_watermark", %{"value" => "not-a-number"})

      assert %{value: "not-a-number"} = SourceCursors.get(account.id, "gmail_poll_watermark")
    end

    test "leaves other attrs (e.g. watch bookkeeping) intact when the value would rewind", %{
      account: account
    } do
      {:ok, _cursor} = SourceCursors.put(account, "gmail_poll_watermark", %{"value" => "2000"})

      {:ok, cursor} =
        SourceCursors.put(account, "gmail_poll_watermark", %{
          "value" => "1000",
          "watch_channel_id" => "chan-1"
        })

      assert cursor.value == "2000"
      assert cursor.watch_channel_id == "chan-1"
    end

    test "gmail_history_id is not subject to the monotonic guard", %{account: account} do
      {:ok, _cursor} = SourceCursors.put(account, "gmail_history_id", %{"value" => "99999"})

      {:ok, cursor} = SourceCursors.put(account, "gmail_history_id", %{"value" => "42"})

      assert cursor.value == "42"
    end
  end
end
