defmodule Maraithon.Tools.GmailHelpersTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.OAuth
  alias Maraithon.Tools.GmailHelpers

  setup do
    original_gmail = Application.get_env(:maraithon, :gmail, [])
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :gmail, original_gmail)
    end)

    %{bypass: bypass}
  end

  test "list_messages fetches full email bodies for model review", %{bypass: bypass} do
    user_id = "gmail-helper-body-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google:school@example.com", %{
               access_token: "gmail-helper-token",
               refresh_token: "gmail-helper-refresh"
             })

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
      ["Bearer gmail-helper-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "maxResults=1"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"messages" => [%{"id" => "msg-school"}]}))
    end)

    body = Base.url_encode64("Class newsletter: field trip form due Friday.", padding: false)

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/msg-school", fn conn ->
      ["Bearer gmail-helper-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string == "format=full"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "msg-school",
          "threadId" => "thread-school",
          "snippet" => "Weekly update",
          "labelIds" => ["INBOX"],
          "internalDate" => "1778260800000",
          "payload" => %{
            "headers" => [
              %{"name" => "From", "value" => "Marla Maharaj <teacher@example.com>"},
              %{"name" => "Subject", "value" => "4M Weekly Newsletter May 11-15"}
            ],
            "mimeType" => "text/plain",
            "body" => %{"data" => body}
          }
        })
      )
    end)

    assert {:ok, [message]} =
             GmailHelpers.list_messages(user_id,
               max_results: 1,
               label_ids: [],
               provider: "google:school@example.com"
             )

    assert message.text_body =~ "field trip form due Friday"
    assert message.google_provider == "google:school@example.com"
    assert message.google_account_email == "school@example.com"
  end
end
