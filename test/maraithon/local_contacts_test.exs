defmodule Maraithon.LocalContactsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.LocalContacts
  alias Maraithon.LocalContacts.LocalContact
  alias Maraithon.Repo

  test "merges Apple Contacts rows into an exact specific CRM name after identifiers differ" do
    user_id = "local-contacts-name-dedupe-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, existing} =
      Crm.upsert_person(user_id, %{
        "display_name" => "Charlie Feng",
        "email" => "charlie@runner.now",
        "relationship" => "Co-founder"
      })

    contact =
      %LocalContact{}
      |> LocalContact.changeset(%{
        user_id: user_id,
        device_id: Ecto.UUID.generate(),
        source: "contacts",
        guid: "apple-charlie-feng",
        display_name: "Charlie Feng",
        first_name: "Charlie",
        last_name: "Feng",
        phones: ["+1 (415) 425-7866"],
        postal_addresses: %{"items" => []}
      })
      |> Repo.insert!()

    assert {:ok, %{merged: 1, failed: 0}} =
             LocalContacts.merge_contacts_into_crm(user_id, [contact.id])

    [person] = Crm.list_people(user_id, query: "Charlie Feng", limit: 5)
    assert person.id == existing.id
    assert "charlie@runner.now" in person.contact_details["emails"]
    assert "+1 (415) 425-7866" in person.contact_details["phones"]
    assert "apple-charlie-feng" in person.contact_details["apple_contact_ids"]
  end
end
