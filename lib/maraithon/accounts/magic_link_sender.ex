defmodule Maraithon.Accounts.MagicLinkSender do
  @moduledoc """
  Sends magic sign-in links.

  Uses Postmark when configured, otherwise records a redacted development
  fallback without exposing the credential or recipient.
  """

  require Logger

  alias Maraithon.Accounts.EmailTemplates
  alias Maraithon.LLM.BoundedResponse
  alias Maraithon.Redaction

  @postmark_api_url "https://api.postmarkapp.com/email"
  @request_timeout_ms 10_000
  @receive_timeout_ms 9_000
  @max_email_bytes 320
  @max_link_bytes 4_096
  @max_code_bytes 64
  @max_request_body_bytes 64_000
  @max_response_body_bytes 16_000
  @max_server_token_bytes 1_024
  @max_from_bytes 512
  @max_message_stream_bytes 128
  @max_api_url_bytes 2_048
  @allow_insecure_api_url Mix.env() == :test
  @allow_log_only Mix.env() in [:dev, :test]

  def deliver(email, link) when is_binary(email) and is_binary(link) do
    with :ok <- validate_delivery_inputs(email, link, @max_link_bytes) do
      deliver_content(email, :link, EmailTemplates.magic_link(link))
    end
  end

  def deliver(_email, _link), do: {:error, :invalid_delivery_payload}

  def deliver_code(email, code) when is_binary(email) and is_binary(code) do
    with :ok <- validate_delivery_inputs(email, code, @max_code_bytes) do
      deliver_content(email, :code, EmailTemplates.magic_code(code))
    end
  end

  def deliver_code(_email, _code), do: {:error, :invalid_delivery_payload}

  defp deliver_content(email, kind, content) do
    case postmark_config() do
      {:ok, config} ->
        send_via_postmark(config, email, content)

      :disabled ->
        if @allow_log_only,
          do: log_only(email, kind),
          else: configuration_error(:delivery_disabled)

      {:error, failure_code} ->
        configuration_error(failure_code)
    end
  end

  defp postmark_config do
    case Application.get_env(:maraithon, __MODULE__, []) do
      config when is_list(config) ->
        if Keyword.keyword?(config),
          do: configured_postmark(config),
          else: {:error, :invalid_configuration}

      _invalid ->
        {:error, :invalid_configuration}
    end
  end

  defp configured_postmark(config) do
    raw_server_token = config_value(config, :server_token, "POSTMARK_SERVER_TOKEN", "")
    raw_from = config_value(config, :from, "AUTH_EMAIL_FROM", "")

    cond do
      raw_server_token in [nil, ""] or raw_from in [nil, ""] ->
        :disabled

      true ->
        with {:ok, server_token} <- bounded_trim(raw_server_token, @max_server_token_bytes),
             {:ok, from} <- bounded_trim(raw_from, @max_from_bytes),
             {:ok, message_stream} <-
               config
               |> config_value(:message_stream, "POSTMARK_MESSAGE_STREAM", "outbound")
               |> bounded_trim(@max_message_stream_bytes),
             {:ok, api_url} <-
               config
               |> Keyword.get(:api_url, @postmark_api_url)
               |> valid_api_url() do
          if server_token == "" or from == "" do
            :disabled
          else
            {:ok,
             %{
               server_token: server_token,
               from: from,
               message_stream: if(message_stream == "", do: "outbound", else: message_stream),
               api_url: api_url
             }}
          end
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp config_value(config, key, env_name, default) do
    case Keyword.fetch(config, key) do
      {:ok, value} -> value
      :error -> System.get_env(env_name, default)
    end
  end

  defp bounded_trim(value, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value), do: {:ok, String.trim(value)}, else: {:error, :invalid_encoding}
  end

  defp bounded_trim(_value, _max_bytes), do: {:error, :invalid_configuration}

  defp valid_api_url(value)
       when is_binary(value) and byte_size(value) <= @max_api_url_bytes do
    if String.valid?(value) do
      case URI.new(value) do
        {:ok, %URI{scheme: scheme, host: host, userinfo: nil}}
        when (scheme == "https" or (@allow_insecure_api_url and scheme == "http")) and
               is_binary(host) and host != "" ->
          {:ok, value}

        _other ->
          {:error, :invalid_api_url}
      end
    else
      {:error, :invalid_encoding}
    end
  end

  defp valid_api_url(_value), do: {:error, :invalid_api_url}

  defp validate_delivery_inputs(email, value, value_limit) do
    cond do
      byte_size(email) == 0 or byte_size(email) > @max_email_bytes ->
        {:error, :invalid_delivery_payload}

      byte_size(value) == 0 or byte_size(value) > value_limit ->
        {:error, :invalid_delivery_payload}

      not String.valid?(email) or not String.valid?(value) ->
        {:error, :invalid_delivery_payload}

      true ->
        :ok
    end
  end

  defp send_via_postmark(config, email, %{
         subject: subject,
         text_body: text_body,
         html_body: html_body
       }) do
    body = %{
      "From" => config.from,
      "To" => email,
      "Subject" => subject,
      "TextBody" => text_body,
      "HtmlBody" => html_body,
      "MessageStream" => config.message_stream
    }

    with {:ok, encoded_body} <- Jason.encode(body),
         true <- byte_size(encoded_body) <= @max_request_body_bytes do
      request = fn ->
        Req.post(config.api_url,
          headers: [
            {"x-postmark-server-token", config.server_token},
            {"content-type", "application/json"}
          ],
          body: encoded_body,
          retry: false,
          redirect: false,
          receive_timeout: @receive_timeout_ms,
          decode_body: false,
          compressed: false,
          into: BoundedResponse.collector(@max_response_body_bytes)
        )
      end

      request
      |> BoundedResponse.run(@request_timeout_ms)
      |> handle_postmark_response()
    else
      _invalid -> {:error, :invalid_delivery_payload}
    end
  end

  defp handle_postmark_response({:ok, %Req.Response{status: status}})
       when status in 200..299,
       do: :ok

  defp handle_postmark_response({:ok, %Req.Response{status: status}}) when status >= 500 do
    Logger.warning("Magic sign-in email result is unknown",
      provider: "postmark",
      response_status: status,
      failure_code: "email_delivery_unknown"
    )

    {:error, :email_delivery_unknown}
  end

  defp handle_postmark_response({:ok, %Req.Response{status: status} = response}) do
    error_code = postmark_error_code(response)
    reason = rejected_reason(status, error_code)

    Logger.warning("Magic sign-in email rejected",
      provider: "postmark",
      response_status: status,
      provider_error_code: error_code,
      failure_code: Atom.to_string(reason)
    )

    {:error, reason}
  end

  defp handle_postmark_response({:error, reason}) do
    Logger.warning("Magic sign-in email result is unknown",
      provider: "postmark",
      failure_code: Redaction.error_class(reason)
    )

    {:error, :email_delivery_unknown}
  end

  defp handle_postmark_response(_invalid) do
    log_delivery_unknown("invalid_transport_response")
  end

  defp log_delivery_unknown(failure_code) do
    Logger.warning("Magic sign-in email result is unknown",
      provider: "postmark",
      failure_code: failure_code
    )

    {:error, :email_delivery_unknown}
  end

  defp postmark_error_code(response) do
    case BoundedResponse.decode_json(response) do
      {:ok, %{"ErrorCode" => code}} when is_integer(code) and code >= 0 and code <= 999_999 ->
        code

      _other ->
        nil
    end
  end

  defp rejected_reason(_status, 406), do: :email_suppressed

  defp rejected_reason(status, _error_code) when status in [401, 403],
    do: :email_provider_auth_failed

  defp rejected_reason(_status, 10), do: :email_provider_auth_failed
  defp rejected_reason(429, _error_code), do: :email_provider_rate_limited
  defp rejected_reason(_status, _error_code), do: :email_delivery_rejected

  defp configuration_error(reason) do
    Logger.error("Magic sign-in email configuration is invalid",
      provider: "postmark",
      failure_code: Redaction.error_class(reason)
    )

    {:error, :email_provider_unavailable}
  end

  defp log_only(email, kind) do
    Logger.info("Magic sign-in delivery fallback (log-only)",
      user_id_hash: Redaction.fingerprint(email),
      status: kind
    )

    :ok
  end
end
