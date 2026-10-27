defmodule Maraithon.EmailDelivery do
  @moduledoc """
  Shared Postmark transport for transactional email.

  Returns `:ok` on delivery, `{:error, reason}` on failure, and
  `:disabled` when Postmark is not configured (callers decide whether
  to log-only or skip).
  """

  require Logger

  @postmark_api_url "https://api.postmarkapp.com/email"

  def send(to, %{subject: subject, text_body: text_body, html_body: html_body})
      when is_binary(to) do
    case config() do
      :disabled ->
        :disabled

      {:ok, config} ->
        body = %{
          "From" => config.from,
          "To" => to,
          "Subject" => subject,
          "TextBody" => text_body,
          "HtmlBody" => html_body,
          "MessageStream" => config.message_stream
        }

        case Req.post(@postmark_api_url,
               headers: [{"X-Postmark-Server-Token", config.server_token}],
               json: body
             ) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Req.Response{status: status, body: response_body}} ->
            Logger.warning("Email delivery rejected",
              status: status,
              body: inspect(response_body, printable_limit: 200)
            )

            {:error, {:postmark_status, status}}

          {:error, reason} ->
            Logger.warning("Email delivery failed", reason: inspect(reason))
            {:error, :email_delivery_failed}
        end
    end
  end

  def configured? do
    match?({:ok, _config}, config())
  end

  defp config do
    server_token = System.get_env("POSTMARK_SERVER_TOKEN", "") |> String.trim()
    from = System.get_env("AUTH_EMAIL_FROM", "") |> String.trim()
    message_stream = System.get_env("POSTMARK_MESSAGE_STREAM", "outbound") |> String.trim()

    cond do
      server_token == "" -> :disabled
      from == "" -> :disabled
      true -> {:ok, %{server_token: server_token, from: from, message_stream: message_stream}}
    end
  end
end
