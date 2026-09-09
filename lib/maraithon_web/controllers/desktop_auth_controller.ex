defmodule MaraithonWeb.DesktopAuthController do
  @moduledoc "Browser sign-in handoff. PKCE protects the existing single-use magic-link record."
  use MaraithonWeb, :controller
  alias Maraithon.Accounts
  alias MaraithonWeb.Endpoint

  @salt "desktop-auth-v1"
  @token_pattern ~r/\A[A-Za-z0-9_-]{43}\z/

  def show(conn, params) do
    with {:ok, request} <- validate_request(params) do
      conn = put_resp_header(conn, "cache-control", "no-store")

      render(conn, :show,
        current_user: conn.assigns.current_user,
        request: Phoenix.Token.sign(Endpoint, @salt, request)
      )
    else
      _ ->
        conn |> put_status(:bad_request) |> text("Open sign-in from the Maraithon desktop app.")
    end
  end

  def approve(conn, %{"request" => signed_request})
      when is_binary(signed_request) and byte_size(signed_request) < 4096 do
    with {:ok, request} <- Phoenix.Token.verify(Endpoint, @salt, signed_request, max_age: 600),
         {:ok, %{token: token}} <- Accounts.request_magic_link(conn.assigns.current_user.email) do
      # Encrypt the magic token: exposing it would bypass PKCE through /auth/magic.
      ticket =
        Phoenix.Token.encrypt(Endpoint, @salt, %{token: token, challenge: request.challenge})

      query = URI.encode_query(%{ticket: ticket, state: request.state})

      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> redirect(external: request.callback <> "?" <> query)
    else
      _ ->
        conn
        |> put_status(:bad_request)
        |> text("Sign-in expired. Start again in the desktop app.")
    end
  end

  def approve(conn, _), do: conn |> put_status(:bad_request) |> text("Invalid sign-in request.")

  # This endpoint authenticates with a one-use ticket plus PKCE, never with cookies.
  # The Electron main process owns the verifier; renderer content never sees it.
  def exchange(conn, %{"ticket" => ticket, "verifier" => verifier})
      when is_binary(ticket) and byte_size(ticket) < 4096 and is_binary(verifier) do
    with true <- Regex.match?(@token_pattern, verifier),
         {:ok, %{token: token, challenge: challenge}} <-
           Phoenix.Token.decrypt(Endpoint, @salt, ticket, max_age: 120),
         true <- Plug.Crypto.secure_compare(challenge, challenge(verifier)),
         {:ok, %{token: session_token}} <- Accounts.consume_magic_link(token) do
      conn
      |> clear_session()
      |> configure_session(renew: true)
      |> put_session("user_session_token", session_token)
      |> put_resp_header("cache-control", "no-store")
      |> json(%{ok: true})
    else
      _ -> invalid_exchange(conn)
    end
  end

  def exchange(conn, _), do: invalid_exchange(conn)

  defp invalid_exchange(conn) do
    conn |> put_status(:unauthorized) |> json(%{error: "Sign-in expired. Please try again."})
  end

  defp challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp validate_request(%{"state" => state, "challenge" => challenge, "callback" => callback})
       when is_binary(state) and is_binary(challenge) and is_binary(callback) and
              byte_size(callback) < 128 do
    uri = URI.parse(callback)

    if Regex.match?(@token_pattern, state) && Regex.match?(@token_pattern, challenge) &&
         uri.scheme == "http" && uri.host == "127.0.0.1" && uri.port in 1024..65535 &&
         uri.path == "/callback" && is_nil(uri.userinfo) && is_nil(uri.query) &&
         is_nil(uri.fragment) do
      {:ok, %{state: state, challenge: challenge, callback: callback}}
    else
      :error
    end
  end

  defp validate_request(_), do: :error
end
