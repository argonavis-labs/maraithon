defmodule Maraithon.AccountsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Accounts.{MagicLink, UserSession}

  test "request_magic_code returns a copyable single-use code that creates a session" do
    email = "mobile-code-#{System.unique_integer([:positive])}@example.com"

    assert {:ok, %{code: code, user: user}} = Accounts.request_magic_code(email)
    assert code =~ ~r/^[A-Z0-9]{4}-[A-Z0-9]{4}$/

    pasted_code =
      code
      |> String.replace("-", " ")
      |> String.downcase()

    assert {:ok, %{token: session_token, user: session_user}} =
             Accounts.consume_magic_code(pasted_code)

    assert session_user.id == user.id
    assert %UserSession{user_id: user_id} = Accounts.get_active_session(session_token)
    assert user_id == user.id

    assert {:error, :invalid_or_expired_code} = Accounts.consume_magic_code(code)
  end

  test "consume_magic_code rejects expired codes" do
    email = "mobile-expired-code-#{System.unique_integer([:positive])}@example.com"
    assert {:ok, %{code: code}} = Accounts.request_magic_code(email)

    magic_link = Repo.get_by!(MagicLink, sent_to_email: email)

    magic_link
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :invalid_or_expired_code} = Accounts.consume_magic_code(code)
  end

  test "consume_magic_code rejects malformed codes" do
    assert {:error, :invalid_or_expired_code} = Accounts.consume_magic_code("not a code")
  end
end
