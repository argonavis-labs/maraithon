defmodule Maraithon.PrivacyErasure.ProviderRevoker do
  @moduledoc """
  Fixed, bounded OAuth revocation adapters used only by privacy erasure.

  Every adapter uses `Req`; response bodies and provider identifiers are never
  persisted. Only the caller's fixed outcome/error code is durable.
  """

  @timeout_ms 5_000
  @github_api_version "2022-11-28"

  @type outcome :: :confirmed | {:unavailable, atom()}

  @spec revoke(String.t(), binary()) :: outcome()
  def revoke(provider, token) when is_binary(provider) and is_binary(token) and token != "" do
    provider
    |> base_provider()
    |> do_revoke(token)
  rescue
    _error -> {:unavailable, :provider_unavailable}
  catch
    :exit, _reason -> {:unavailable, :provider_unavailable}
  end

  def revoke(_provider, _token), do: {:unavailable, :credential_unreadable}

  defp do_revoke("google", token) do
    url = config_url(:google, :revoke_url, "https://oauth2.googleapis.com/revoke")
    request(:post, url, form: [token: token])
  end

  defp do_revoke("slack", token) do
    url = config_url(:slack, :revoke_url, "https://slack.com/api/auth.revoke")

    case request_response(:post, url,
           headers: [{"authorization", "Bearer #{token}"}],
           form: []
         ) do
      {:ok, %Req.Response{status: status, body: %{"ok" => true}}} when status in 200..299 ->
        :confirmed

      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:unavailable, :provider_rejected}

      other ->
        classify(other)
    end
  end

  defp do_revoke("github", token) do
    config = Application.get_env(:maraithon, :github, [])
    client_id = Keyword.get(config, :client_id, "")
    client_secret = Keyword.get(config, :client_secret, "")

    if client_id == "" or client_secret == "" do
      {:unavailable, :provider_not_configured}
    else
      base = Keyword.get(config, :api_base_url, "https://api.github.com")
      url = String.trim_trailing(base, "/") <> "/applications/#{client_id}/token"

      request(:delete, url,
        headers: [
          {"accept", "application/vnd.github+json"},
          {"authorization", "Basic #{Base.encode64("#{client_id}:#{client_secret}")}"},
          {"x-github-api-version", @github_api_version}
        ],
        json: %{access_token: token}
      )
    end
  end

  defp do_revoke("linear", token) do
    url = config_url(:linear, :revoke_url, "https://api.linear.app/oauth/revoke")
    request(:post, url, headers: [{"authorization", "Bearer #{token}"}], json: %{})
  end

  defp do_revoke("notion", token) do
    config = Application.get_env(:maraithon, :notion, [])
    client_id = Keyword.get(config, :client_id, "")
    client_secret = Keyword.get(config, :client_secret, "")

    if client_id == "" or client_secret == "" do
      {:unavailable, :provider_not_configured}
    else
      url = Keyword.get(config, :revoke_url, "https://api.notion.com/v1/oauth/revoke")

      request(:post, url,
        headers: [
          {"authorization", "Basic #{Base.encode64("#{client_id}:#{client_secret}")}"},
          {"accept", "application/json"}
        ],
        json: %{token: token}
      )
    end
  end

  defp do_revoke("notaui", token) do
    config = Application.get_env(:maraithon, :notaui, [])

    case Keyword.get(config, :revoke_url, "") do
      "" ->
        {:unavailable, :provider_unsupported}

      url ->
        client_id = Keyword.get(config, :client_id, "")
        client_secret = Keyword.get(config, :client_secret, "")

        request(:post, url,
          headers: [
            {"authorization", "Basic #{Base.encode64("#{client_id}:#{client_secret}")}"},
            {"accept", "application/json"}
          ],
          form: [token: token]
        )
    end
  end

  defp do_revoke(_provider, _token), do: {:unavailable, :provider_unsupported}

  defp request(method, url, opts) do
    method
    |> request_response(url, opts)
    |> classify()
  end

  defp request_response(method, url, opts) do
    Req.request(
      [
        method: method,
        url: url,
        receive_timeout: @timeout_ms,
        connect_options: [timeout: @timeout_ms],
        retry: false,
        max_redirects: 0
      ] ++ opts
    )
  end

  defp classify({:ok, %Req.Response{status: status}}) when status in 200..299, do: :confirmed
  defp classify({:ok, %Req.Response{}}), do: {:unavailable, :provider_rejected}

  defp classify({:error, %Req.TransportError{reason: :timeout}}),
    do: {:unavailable, :provider_timeout}

  defp classify({:error, _reason}), do: {:unavailable, :provider_unavailable}
  defp classify(_other), do: {:unavailable, :provider_unavailable}

  defp config_url(application_key, key, default) do
    Application.get_env(:maraithon, application_key, [])
    |> Keyword.get(key, default)
  end

  defp base_provider(provider) do
    provider
    |> String.split(":", parts: 2)
    |> List.first()
    |> String.downcase()
  end
end
