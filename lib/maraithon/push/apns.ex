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
  # APNs caps alert payloads at 4KB; byte caps leave ample envelope headroom.
  @title_limit_bytes 140
  @body_limit_bytes 900
  @thread_id_limit_bytes 128
  @deeplink_limit_bytes 512
  @title_encoded_budget 400
  @body_encoded_budget 2_600
  @thread_id_encoded_budget 250
  @deeplink_encoded_budget 500

  def configured? do
    match?({:ok, _config}, config())
  end

  @doc """
  Sends one alert push to one device token.

  Returns `:ok`, a definitive rejection such as `{:error, :unregistered}` or
  `{:error, :retryable}`, or `{:error, :delivery_unknown}` when transport
  crossed the external-send boundary but no conclusive APNS response arrived.
  """
  def send(device_token, payload, opts \\ [])
      when is_binary(device_token) and is_map(payload) and is_list(opts) do
    case config() do
      :disabled ->
        {:error, :not_configured}

      {:ok, config} ->
        with {:ok, {url, headers, body}} <- build_request(config, device_token, payload, opts) do
          case post_once(url, headers, body) do
            {:ok, 200, _body} ->
              :ok

            {:ok, status, response_body} ->
              classify_failure(status, response_body)

            {:error, :delivery_unknown} ->
              Logger.warning("APNs delivery result is unknown",
                failure_code: "delivery_unknown"
              )

              {:error, :delivery_unknown}
          end
        end
    end
  end

  defp build_request(config, device_token, payload, opts) do
    try do
      headers =
        [
          {"authorization", "bearer " <> provider_jwt(config)},
          {"apns-topic", config.topic},
          {"apns-push-type", "alert"},
          {"apns-priority", "10"}
        ]
        |> maybe_collapse_id(opts[:collapse_id])

      url = "#{host(config)}/3/device/#{device_token}"
      {:ok, {url, headers, Jason.encode!(payload)}}
    rescue
      _exception -> {:error, :request_rejected}
    catch
      _kind, _reason -> {:error, :request_rejected}
    end
  end

  # A transport error may mean APNS accepted the request but its response was
  # lost. Collapse IDs coalesce notifications but are not an idempotency key,
  # so never issue a second external POST after crossing this boundary.
  defp post_once(url, headers, body) do
    case safe_post(url, headers, body) do
      {:error, reason} ->
        Logger.debug("APNs transport result is ambiguous",
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        {:error, :delivery_unknown}

      result ->
        result
    end
  end

  defp safe_post(url, headers, body) do
    try do
      case http_module().post(url, headers, body) do
        {:ok, status, response_body} when is_integer(status) ->
          {:ok, status, response_body}

        {:error, reason} ->
          {:error, reason}

        _invalid ->
          {:error, :invalid_transport_response}
      end
    rescue
      _exception -> {:error, :transport_exception}
    catch
      _kind, _reason -> {:error, :transport_exit}
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
      |> maybe_put(
        "title",
        clamp(attrs[:title], @title_limit_bytes, @title_encoded_budget)
      )
      |> maybe_put("body", clamp(attrs[:body], @body_limit_bytes, @body_encoded_budget))

    aps =
      %{"alert" => alert, "sound" => "default"}
      |> maybe_put(
        "thread-id",
        clamp(attrs[:thread_id], @thread_id_limit_bytes, @thread_id_encoded_budget)
      )

    %{"aps" => aps}
    |> maybe_put(
      "deeplink",
      clamp(attrs[:deeplink], @deeplink_limit_bytes, @deeplink_encoded_budget)
    )
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

  defp trimmed(value) when is_binary(value) and byte_size(value) <= 16_384 do
    if String.valid?(value) do
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
    end
  end

  defp trimmed(_value), do: nil

  # Fly secrets flatten newlines; a PEM pasted with literal \n must still parse.
  defp normalize_pem(value)
       when is_binary(value) and byte_size(value) <= 16_384 do
    if String.valid?(value) do
      value
      |> String.replace("\\n", "\n")
      |> trimmed()
    end
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
        Logger.warning("APNs rejected provider token", failure_code: "provider_token_rejected")
        {:error, :retryable}

      status == 429 or status >= 500 ->
        {:error, :retryable}

      true ->
        Logger.warning("APNs rejected push", status: status, failure_code: "push_rejected")
        {:error, {:apns, status, :redacted}}
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
    # Hashing stays within APNs' 64-byte cap while avoiding PII in the header.
    value = Base.encode16(:crypto.hash(:sha256, collapse_id), case: :lower)
    headers ++ [{"apns-collapse-id", value}]
  end

  defp maybe_collapse_id(headers, _collapse_id), do: headers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when map_size(value) == 0 and is_map(value), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp clamp(nil, _raw_limit, _encoded_budget), do: nil

  defp clamp(value, raw_limit, encoded_budget) when is_binary(value) do
    value
    |> Maraithon.PromptBudget.truncate_utf8(raw_limit)
    |> Maraithon.PromptBudget.encoded_string(encoded_budget)
  end

  defp clamp(_value, _raw_limit, _encoded_budget), do: nil

  defp http_module do
    Application.get_env(:maraithon, :apns, [])
    |> Keyword.get(:http_module, Maraithon.Push.APNS.HTTP)
  end
end
