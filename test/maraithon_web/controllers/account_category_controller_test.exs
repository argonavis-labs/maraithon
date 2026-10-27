defmodule MaraithonWeb.AccountCategoryControllerTest do
  use MaraithonWeb.ConnCase, async: false
  alias Maraithon.{Accounts, AccountCategories, ConnectedAccounts, OAuth, Todos}
  alias Maraithon.Companion.Devices

  test "paired devices share category filters and cache invalidation without exposing other accounts",
       %{conn: conn} do
    user = "category-device-#{Ecto.UUID.generate()}@example.invalid"
    other = "other-device-#{Ecto.UUID.generate()}@example.invalid"
    for email <- [user, other], do: Accounts.get_or_create_user_by_email(email)

    {:ok, %{token: token}} =
      Devices.register(user, Ecto.UUID.generate(), device_name: "Category Mac")

    for email <- [user, other],
        do: OAuth.store_tokens(email, "google:#{email}", %{access_token: "fixture"})

    account = ConnectedAccounts.get(user, "google:#{user}")
    foreign = ConnectedAccounts.get(other, "google:#{other}")

    {:ok, [_]} =
      Todos.upsert_many(user, [
        %{"title" => "Reply to email", "source" => "gmail", "source_account_id" => account.id}
      ])

    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    listed = get(conn, "/api/v1/companion/account-categories")

    assert %{"accounts" => [%{"id" => id, "category" => "unassigned"}]} =
             json_response(listed, 200)

    assert id == account.id
    original = get(recycle(listed), "/api/v1/companion/todos?status=all&include_cards=false")
    [etag] = get_resp_header(original, "etag")

    changed =
      post(recycle(original), "/api/v1/companion/account-categories/#{id}", %{
        "category" => "work",
        "user_id" => other
      })

    assert %{"accounts" => [%{"category" => "work"}]} = json_response(changed, 200)

    refreshed =
      recycle(changed)
      |> put_req_header("if-none-match", etag)
      |> get("/api/v1/companion/todos?status=all&include_cards=false")

    assert %{"todos" => [%{"account_category" => "work"}]} = json_response(refreshed, 200)

    personal =
      get(
        recycle(refreshed),
        "/api/v1/companion/todos?status=all&category=personal&include_cards=false"
      )

    assert %{"todos" => []} = json_response(personal, 200)

    denied =
      post(recycle(personal), "/api/v1/companion/account-categories/#{foreign.id}", %{
        "category" => "work"
      })

    assert json_response(denied, 422)["error"]
    assert [%{category: "unassigned"}] = AccountCategories.list(other)
  end

  test "personal settings are available to a signed-in non-admin", %{conn: conn} do
    conn = log_in_test_user(conn, "category-settings@example.invalid")
    assert get(conn, "/settings/accounts") |> html_response(200) =~ "Account settings"
  end
end
