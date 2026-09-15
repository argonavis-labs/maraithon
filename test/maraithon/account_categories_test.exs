defmodule Maraithon.AccountCategoriesTest do
  use Maraithon.DataCase, async: false
  alias Maraithon.{AccountCategories, Accounts, OAuth, ConnectedAccounts, Todos}

  test "account categories update existing todos, preserve unassigned work and survive token refresh" do
    user = "categories-#{Ecto.UUID.generate()}@example.invalid"
    other = "other-#{Ecto.UUID.generate()}@example.invalid"
    for email <- [user, other], do: Accounts.get_or_create_user_by_email(email)

    {:ok, _} =
      OAuth.store_tokens(user, "google:personal@example.invalid", %{
        access_token: "fixture",
        metadata: %{}
      })

    account = ConnectedAccounts.get(user, "google:personal@example.invalid")

    {:ok, [linked, manual]} =
      Todos.upsert_many(user, [
        %{
          "title" => "Reply to the message",
          "source" => "gmail",
          "source_account_id" => account.id,
          "dedupe_key" => "category-linked"
        },
        %{"title" => "Buy groceries", "source" => "manual", "dedupe_key" => "category-manual"}
      ])

    assert AccountCategories.for_todo(linked) == "unassigned"
    assert {:error, :not_found} = AccountCategories.update(other, account.id, "work")
    assert {:error, :invalid_category} = AccountCategories.update(user, account.id, "invalid")
    assert {:ok, _} = AccountCategories.update(user, account.id, "personal")
    assert [found] = Todos.list_for_user(user, category: "personal")
    assert found.id == linked.id
    assert Todos.count_for_user(user, category: "personal") == 1
    assert Todos.list_for_user(user, category: "work") == []
    assert Todos.count_for_user(user) == 2
    assert AccountCategories.for_todo(manual) == "unassigned"

    {:ok, _} =
      OAuth.store_tokens(user, account.provider, %{access_token: "refreshed", metadata: %{}})

    assert AccountCategories.for_todo(linked) == "personal"
    assert {:ok, _} = AccountCategories.update(user, account.id, "work")
    assert Todos.list_for_user(user, category: "personal") == []
    assert [found] = Todos.list_for_user(user, category: "work")
    assert found.id == linked.id
  end
end
