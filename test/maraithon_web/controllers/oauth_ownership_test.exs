defmodule MaraithonWeb.OAuthOwnershipTest do
  use MaraithonWeb.ConnCase, async: false

  @user "oauth-ownership@example.com"

  setup %{conn: conn} do
    previous = Application.fetch_env(:maraithon, :google)

    Application.put_env(:maraithon, :google,
      client_id: "ownership-test",
      redirect_uri: "http://localhost:4000/auth/google/callback"
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:maraithon, :google, value)
        :error -> Application.delete_env(:maraithon, :google)
      end
    end)

    {:ok, conn: log_in_test_user(conn, @user)}
  end

  test "settings connection uses the authenticated user when no user ID is supplied", %{
    conn: conn
  } do
    conn = get(conn, "/auth/google", %{scopes: "gmail_compose"})
    query = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:ok, %{"user_id" => @user, "services" => ["gmail_compose"]}} =
             Phoenix.Token.verify(MaraithonWeb.Endpoint, "oauth_state", query["state"])
  end

  test "a caller cannot connect credentials to another user", %{conn: conn} do
    conn = get(conn, "/auth/google", %{scopes: "gmail_compose", user_id: "other@example.com"})
    assert json_response(conn, 400)["error"] =~ "different user"
  end

  test "assistant setup freezes its account purpose in signed OAuth state", %{conn: conn} do
    keys = [:delegations_enabled, :delegation_user_allowlist]
    previous = Map.new(keys, &{&1, Application.fetch_env(:maraithon, &1)})
    Application.put_env(:maraithon, :delegations_enabled, true)
    Application.put_env(:maraithon, :delegation_user_allowlist, [@user])

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:maraithon, key, value)
        {key, :error} -> Application.delete_env(:maraithon, key)
      end)
    end)

    conn = get(conn, "/auth/google", %{scopes: "gmail_compose", purpose: "assistant"})
    query = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:ok, %{"user_id" => @user, "purpose" => "assistant"}} =
             Phoenix.Token.verify(MaraithonWeb.Endpoint, "oauth_state", query["state"])
  end

  test "a signed callback for another user is rejected before token exchange", %{conn: conn} do
    state =
      Phoenix.Token.sign(MaraithonWeb.Endpoint, "oauth_state", %{
        "provider" => "google",
        "user_id" => "other@example.com",
        "services" => ["gmail_compose"]
      })

    conn = get(conn, "/auth/google/callback", %{code: "must-not-exchange", state: state})
    assert json_response(conn, 400)["error"] =~ "different user"
  end
end
