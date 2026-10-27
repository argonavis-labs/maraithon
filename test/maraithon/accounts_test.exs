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

  describe "app review bypass" do
    @bypass_email "reviewer@maraithon.test"
    @bypass_code "TESTK4V5"

    defp enable_bypass do
      prev = Application.get_env(:maraithon, :app_review_bypass)

      Application.put_env(:maraithon, :app_review_bypass,
        email: @bypass_email,
        code: @bypass_code
      )

      ExUnit.Callbacks.on_exit(fn ->
        Application.put_env(:maraithon, :app_review_bypass, prev)
      end)
    end

    defp disable_bypass do
      prev = Application.get_env(:maraithon, :app_review_bypass)
      Application.put_env(:maraithon, :app_review_bypass, email: nil, code: nil)

      ExUnit.Callbacks.on_exit(fn ->
        Application.put_env(:maraithon, :app_review_bypass, prev)
      end)
    end

    test "request_magic_code for the bypass email returns :bypass and inserts no MagicLink" do
      enable_bypass()

      assert {:ok, %{user: user, code: :bypass, expires_at: %DateTime{}}} =
               Accounts.request_magic_code(@bypass_email)

      assert user.email == @bypass_email
      assert Repo.get_by(MagicLink, sent_to_email: @bypass_email) == nil
    end

    test "consume_magic_code with the bypass code returns a session for the reviewer" do
      enable_bypass()
      {:ok, user} = Accounts.get_or_create_user_by_email(@bypass_email)

      assert {:ok, %{token: session_token, user: session_user}} =
               Accounts.consume_magic_code(@bypass_code)

      assert session_user.id == user.id
      assert %UserSession{user_id: user_id} = Accounts.get_active_session(session_token)
      assert user_id == user.id
    end

    test "consume_magic_code accepts the hyphenated/lowercased bypass code" do
      enable_bypass()
      {:ok, _} = Accounts.get_or_create_user_by_email(@bypass_email)

      assert {:ok, %{user: session_user}} = Accounts.consume_magic_code("test-k4v5")
      assert session_user.email == @bypass_email
    end

    test "with bypass disabled, the reviewer email goes through the normal Postmark path" do
      disable_bypass()

      assert {:ok, %{code: code, user: user}} = Accounts.request_magic_code(@bypass_email)
      assert code =~ ~r/^[A-Z0-9]{4}-[A-Z0-9]{4}$/
      assert %MagicLink{} = Repo.get_by(MagicLink, sent_to_email: user.email)
    end

    test "with bypass disabled, the bypass code is rejected" do
      disable_bypass()
      {:ok, _} = Accounts.get_or_create_user_by_email(@bypass_email)

      assert {:error, :invalid_or_expired_code} = Accounts.consume_magic_code(@bypass_code)
    end

    test "the bypass code is bound to the reviewer identity, not any other account" do
      enable_bypass()

      {:ok, reviewer} = Accounts.get_or_create_user_by_email(@bypass_email)

      other_email = "not-the-reviewer-#{System.unique_integer([:positive])}@example.com"
      {:ok, other_user} = Accounts.get_or_create_user_by_email(other_email)

      # The bypass code resolves via the configured bypass-user lookup, so it
      # can only ever mint a session for the reviewer — never the other user.
      assert {:ok, %{user: session_user}} = Accounts.consume_magic_code(@bypass_code)
      assert session_user.id == reviewer.id
      refute session_user.id == other_user.id
    end
  end
end
