defmodule Maraithon.TestSupport.FailingTelegram do
  @moduledoc false

  def configured?, do: true

  def send_message(_chat_id, _text, _opts \\ []) do
    {:error, failure_reason()}
  end

  def send_chat_action(_chat_id, _action), do: {:error, failure_reason()}
  def answer_callback_query(_callback_query_id, _opts \\ []), do: {:error, failure_reason()}
  def edit_message_text(_chat_id, _message_id, _text, _opts \\ []), do: {:error, failure_reason()}

  defp failure_reason do
    Application.get_env(:maraithon, :failing_telegram, [])
    |> Keyword.get(:reason, {:telegram_error, 403, "Forbidden: bot was blocked by the user"})
  end
end
