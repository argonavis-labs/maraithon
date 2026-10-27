defmodule MaraithonWeb.TelegramLink do
  @moduledoc """
  Signed Telegram deep links for self-serve chat linking.
  """

  @salt "telegram-link"
  @max_age_seconds 15 * 60
  @max_start_param_length 64

  alias MaraithonWeb.Endpoint

  @doc """
  Builds a Telegram bot deep link carrying a short-lived signed token.
  """
  def deep_link(user_id) when is_binary(user_id) do
    with username when is_binary(username) <- bot_username(),
         token when byte_size(token) <= @max_start_param_length <- sign_token(user_id) do
      "https://t.me/#{username}?start=#{URI.encode_www_form(token)}"
    else
      _missing_or_too_long ->
        nil
    end
  end

  def deep_link(_user_id), do: nil

  @doc """
  Signs a user id for Telegram chat linking.
  """
  def sign_token(user_id) when is_binary(user_id) do
    Phoenix.Token.sign(Endpoint, @salt, user_id)
  end

  @doc """
  Verifies a Telegram chat-link token and returns the encoded user id.
  """
  def verify_token(token, opts \\ [])

  def verify_token(token, opts) when is_binary(token) do
    max_age = Keyword.get(opts, :max_age, @max_age_seconds)
    Phoenix.Token.verify(Endpoint, @salt, token, max_age: max_age)
  end

  def verify_token(_token, _opts), do: {:error, :invalid}

  @doc """
  Returns the configured bot username without a leading `@`.
  """
  def bot_username do
    :maraithon
    |> Application.get_env(:telegram, [])
    |> Keyword.get(:bot_username, "")
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> case do
      "" -> nil
      username -> username
    end
  end
end
