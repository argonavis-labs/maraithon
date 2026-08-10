defmodule Maraithon.Runtime.TokenRefresher do
  @moduledoc """
  Executes one durably partitioned OAuth refresh at a time.

  Cadence and ownership live in `background_jobs`; this module has no process,
  mailbox, or timer authority. The provider lane serializes each logical
  account and applies provider-wide durable cooldowns.
  """

  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Token
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config

  require Logger

  @default_lookahead_seconds 15 * 60
  @default_batch_size 100

  @doc "Runs the bounded compatibility sweep synchronously."
  def run_once(opts \\ []) do
    lookahead_seconds =
      positive_integer_opt(
        opts,
        :lookahead_seconds,
        Config.positive_integer(:oauth_refresh_lookahead_seconds, @default_lookahead_seconds)
      )

    batch_size =
      positive_integer_opt(
        opts,
        :batch_size,
        Config.positive_integer(:oauth_refresh_batch_size, @default_batch_size)
      )

    lookahead_seconds
    |> OAuth.list_expiring_tokens()
    |> Enum.filter(&refresh_supported_provider?(&1.provider))
    |> Enum.take(batch_size)
    |> Enum.reduce(%{attempted: 0, refreshed: 0, failed: 0}, fn token, acc ->
      case refresh_token(token, lookahead_seconds) do
        {:ok, _result} ->
          %{acc | attempted: acc.attempted + 1, refreshed: acc.refreshed + 1}

        {:error, _reason} ->
          %{acc | attempted: acc.attempted + 1, failed: acc.failed + 1}
      end
    end)
  end

  @doc "Executes the durable partition for one OAuth token row."
  def run_token(token_id, opts \\ [])

  def run_token(token_id, opts) when is_integer(token_id) do
    lookahead_seconds =
      positive_integer_opt(
        opts,
        :lookahead_seconds,
        Config.positive_integer(:oauth_refresh_lookahead_seconds, @default_lookahead_seconds)
      )

    case Repo.get(Token, token_id) do
      nil ->
        {:ok, %{outcome: "missing", token_id: token_id}}

      %Token{} = token ->
        if refresh_supported_provider?(token.provider) do
          refresh_token(token, lookahead_seconds)
        else
          {:ok, %{outcome: "unsupported", token_id: token_id}}
        end
    end
  end

  def run_token(_token_id, _opts), do: {:error, :invalid_token_partition}

  defp refresh_token(%Token{} = token, lookahead_seconds) do
    case OAuth.refresh_if_expiring(token.user_id, token.provider, lookahead_seconds) do
      {:ok, _updated} ->
        {:ok, %{outcome: "refreshed", provider: provider_family(token.provider)}}

      {:error, reason} = error ->
        Logger.warning("OAuth token refresh failed",
          user_id: token.user_id,
          provider: token.provider,
          reason: inspect(reason)
        )

        report_refresh_issue(token.user_id, token.provider, reason)
        error
    end
  end

  defp report_refresh_issue(user_id, provider, reason) do
    ConnectedAccounts.report_access_issue(user_id, provider, reason)
  rescue
    _ -> :ok
  end

  def provider_family(provider) when is_binary(provider) do
    provider
    |> String.split(":", parts: 2)
    |> List.first()
  end

  def provider_family(_provider), do: "unknown"

  def refresh_supported_provider?("google"), do: true
  def refresh_supported_provider?("notion"), do: true

  def refresh_supported_provider?(provider) when is_binary(provider) do
    String.starts_with?(provider, "google:") or String.starts_with?(provider, "slack:")
  end

  def refresh_supported_provider?(_provider), do: false

  defp positive_integer_opt(opts, key, default) when is_list(opts) and is_atom(key) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
