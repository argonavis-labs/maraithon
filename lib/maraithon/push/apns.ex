defmodule Maraithon.Push.APNS do
  @moduledoc """
  Direct APNs client (HTTP/2, provider-token auth).

  Signs ES256 provider JWTs with `:public_key`/`:crypto` — no JWT dependency.
  The JWT is cached in `:persistent_term` and reminted after ~50 minutes
  (Apple rejects tokens older than 60 and newer-than-once-per-20-minutes
  reminting, so one cached token per interval is exactly right).

  Configuration is environment-driven and the client is inert until all of
  it is present:

    * `APNS_TEAM_ID` — Apple developer team id
    * `APNS_KEY_ID` — key id of the `.p8` auth key
    * `APNS_PRIVATE_KEY` — PEM contents of the `.p8`
    * `APNS_TOPIC` — bundle id (default `com.bliss.maraithonmobile`)
    * `APNS_ENVIRONMENT` — `production` (default) or `sandbox`
  """

  require Logger

  @default_topic "com.bliss.maraithonmobile"
  @jwt_ttl_seconds 50 * 60
  @jwt_cache_key {__MODULE__, :provider_jwt}
  @production_host "https://api.push.apple.com"
  @sandbox_host "https://api.sandbox.push.apple.com"
  # APNs caps alert payloads at 4KB; leave headroom for the envelope.
  @body_limit 900

  def configured? do
    match?({:ok, _config}, config())
  end

  @doc """
  Sends one alert push to one device token.

  Returns `:ok`, `{:error, :unregistered}` (token is dead — caller prunes),
  `{:error, :retryable}` (APNs hiccup — the broker's next cycle retries), or
  `{:error, term}` for the rest.
  """
  def send(device_token, payload, opts \\ [])
      when is_binary(device_token) and is_map(payload) and is_list(opts) do
    case config() do
      :disabled ->
        {:error, :not_configured}

      {:ok, config} ->
        headers =
          [
            {"authorization", "bearer " <> provider_jwt(config)},
            {"apns-topic", config.topic},
            {"apns-push-type", "alert"},
            {"apns-priority", "10"}
          ]
          |> maybe_collapse_id(opts[:collapse_id])

        url = "#{host(config)}/3/device/#{device_token}"
        body = Jason.encode!(payload)

        case post_with_retry(url, headers, body) do
          {:ok, 200, _body} ->
            :ok

          {:ok, status, response_body} ->
            classify_failure(status, response_body)

          {:error, reason} ->
            Logger.warning("APNs request failed after retry", reason: inspect(reason))
            {:error, :retryable}
        end
    end
  end

  # Sends to APNs are sparse, and the pool holds one HTTP/2 connection that
  # Apple closes when idle — so the first request after a quiet stretch
  # routinely dies at the transport layer. One immediate retry lands on a
  # fresh connection. HTTP-status failures are not retried here; they
  # reached APNs and classify_failure/2 decides.
  defp post_with_retry(url, headers, body) do
    case http_module().post(url, headers, body) do
      {:error, reason} ->
        Logger.debug("APNs transport failure, retrying on a fresh connection",
          reason: inspect(reason)
        )

        http_module().post(url, headers, body)

      result ->
        result
    end
  end

  @doc """
  Builds the standard Maraithon alert payload. `deeplink` rides outside the
  `aps` envelope for the client's notification router; `thread_id` groups
  notifications by origin in Notification Center.
  """
  def payload(attrs) when is_map(attrs) do
    alert =
      %{}
      |> maybe_put("title", clamp(attrs[:title], 140))
      |> maybe_put("body", clamp(attrs[:body], @body_limit))

    aps =
      %{"alert" => alert, "sound" => "default"}
      |> maybe_put("thread-id", attrs[:thread_id])

    %{"aps" => aps}
    |> maybe_put("deeplink", attrs[:deeplink])
  end

  # ---------------------------------------------------------------------------
  # Provider JWT (ES256)
  # ---------------------------------------------------------------------------

  defp provider_jwt(config) do
    now = System.system_time(:second)

    case :persistent_term.get(@jwt_cache_key, nil) do
      {jwt, issued_at, key_id}
      when now - issued_at < @jwt_ttl_seconds and key_id == config.key_id ->
        jwt

      _stale_or_missing ->
        jwt = mint_jwt(config, now)
        :persistent_term.put(@jwt_cache_key, {jwt, now, config.key_id})
        jwt
    end
  end

  # Public for the 403 InvalidProviderToken path and tests.
  @doc false
  def reset_jwt_cache do
    :persistent_term.erase(@jwt_cache_key)
    :ok
  end

  defp mint_jwt(config, issued_at) do
    header = base64url(Jason.encode!(%{"alg" => "ES256", "kid" => config.key_id}))
    claims = base64url(Jason.encode!(%{"iss" => config.team_id, "iat" => issued_at}))
    signing_input = header <> "." <> claims

    signing_input <> "." <> base64url(sign_es256(signing_input, config.private_key))
  end

  defp sign_es256(data, pem) when is_binary(pem) do
    [entry | _rest] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)

    data
    |> :public_key.sign(:sha256, key)
    |> der_signature_to_raw()
  end

  # JOSE ES256 signatures are raw r||s (32 bytes each); :public_key emits DER.
  defp der_signature_to_raw(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    pad_to_32(r) <> pad_to_32(s)
  end

  defp pad_to_32(integer) when is_integer(integer) do
    integer
    |> :binary.encode_unsigned()
    |> then(fn binary -> :binary.copy(<<0>>, 32 - byte_size(binary)) <> binary end)
  end

  defp base64url(binary), do: Base.url_encode64(binary, padding: false)

  # ---------------------------------------------------------------------------
  # Config / transport
  # ---------------------------------------------------------------------------

  defp config do
    env = Application.get_env(:maraithon, :apns, [])

    team_id = trimmed(Keyword.get(env, :team_id))
    key_id = trimmed(Keyword.get(env, :key_id))
    private_key = normalize_pem(Keyword.get(env, :private_key))

    if team_id && key_id && private_key do
      {:ok,
       %{
         team_id: team_id,
         key_id: key_id,
         private_key: private_key,
         topic: trimmed(Keyword.get(env, :topic)) || @default_topic,
         environment: trimmed(Keyword.get(env, :environment)) || "production"
       }}
    else
      :disabled
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trimmed(_value), do: nil

  # Fly secrets flatten newlines; a PEM pasted with literal \n must still parse.
  defp normalize_pem(value) when is_binary(value) do
    value
    |> String.replace("\\n", "\n")
    |> trimmed()
  end

  defp normalize_pem(_value), do: nil

  defp host(%{environment: "sandbox"}), do: @sandbox_host
  defp host(_config), do: @production_host

  defp classify_failure(status, response_body) do
    reason = decode_reason(response_body)

    cond do
      status == 410 or
          reason in ["Unregistered", "BadDeviceToken", "ExpiredToken", "DeviceTokenNotForTopic"] ->
        {:error, :unregistered}

      status == 403 and reason in ["InvalidProviderToken", "ExpiredProviderToken"] ->
        # A bad cached token must not poison every send for 50 minutes.
        reset_jwt_cache()
        Logger.warning("APNs rejected provider token", reason: reason)
        {:error, :retryable}

      status == 429 or status >= 500 ->
        {:error, :retryable}

      true ->
        Logger.warning("APNs rejected push", status: status, reason: reason)
        {:error, {:apns, status, reason}}
    end
  end

  defp decode_reason(body) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} -> reason
      _other -> nil
    end
  end

  defp decode_reason(_body), do: nil

  defp maybe_collapse_id(headers, collapse_id) when is_binary(collapse_id) do
    # APNs caps apns-collapse-id at 64 bytes.
    headers ++ [{"apns-collapse-id", String.slice(collapse_id, 0, 64)}]
  end

  defp maybe_collapse_id(headers, _collapse_id), do: headers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when map_size(value) == 0 and is_map(value), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp clamp(nil, _limit), do: nil

  defp clamp(value, limit) when is_binary(value) do
    if String.length(value) > limit do
      String.slice(value, 0, limit - 1) <> "…"
    else
      value
    end
  end

  defp clamp(_value, _limit), do: nil

  defp http_module do
    Application.get_env(:maraithon, :apns, [])
    |> Keyword.get(:http_module, Maraithon.Push.APNS.HTTP)
  end
end
