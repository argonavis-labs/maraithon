defmodule Maraithon.TelegramAssistant.LivenessSessionStreamingTest do
  use ExUnit.Case, async: false

  alias Maraithon.TelegramAssistant.LivenessSession

  defmodule FakeTelegram do
    @moduledoc false

    def send_message(chat_id, text, _opts \\ []) do
      send(test_pid(), {:telegram_send, chat_id, text})
      {:ok, %{"message_id" => 9_999}}
    end

    def edit_message_text(chat_id, message_id, text, opts \\ []) do
      send(test_pid(), {:telegram_edit, chat_id, message_id, text, opts})
      {:ok, %{"message_id" => message_id}}
    end

    def send_chat_action(chat_id, action) do
      send(test_pid(), {:telegram_chat_action, chat_id, action})
      {:ok, %{}}
    end

    def answer_callback_query(_callback_id, _opts), do: {:ok, %{}}

    defp test_pid, do: Application.get_env(:maraithon, :liveness_test_pid, self())
  end

  setup do
    original_insights = Application.get_env(:maraithon, :insights)
    original_assistant = Application.get_env(:maraithon, :telegram_assistant)

    Application.put_env(:maraithon, :insights, telegram_module: FakeTelegram)

    Application.put_env(:maraithon, :telegram_assistant,
      typing_initial_delay_ms: 60_000,
      contextual_progress_delay_ms: 60_000,
      timeout_notice_ms: 60_000,
      typing_refresh_ms: 60_000
    )

    on_exit(fn ->
      if original_insights do
        Application.put_env(:maraithon, :insights, original_insights)
      else
        Application.delete_env(:maraithon, :insights)
      end

      if original_assistant do
        Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      else
        Application.delete_env(:maraithon, :telegram_assistant)
      end
    end)

    :ok
  end

  defp start_session(run_id) do
    Application.put_env(:maraithon, :liveness_test_pid, self())

    {:ok, _pid} =
      LivenessSession.start_link(%{
        run_id: run_id,
        user_id: "u1",
        chat_id: "c1",
        reply_to_message_id: 42
      })

    :ok
  end

  test "stream_chunk creates a placeholder message and edits with buffered text" do
    run_id = "run-#{System.unique_integer([:positive])}"
    start_session(run_id)

    LivenessSession.stream_chunk(run_id, "Hello ")
    LivenessSession.stream_chunk(run_id, "there")

    # Placeholder send happens immediately on first chunk.
    assert_receive {:telegram_send, "c1", "…"}, 1_000

    # Throttled flush fires within ~1s.
    assert_receive {:telegram_edit, "c1", "9999", "Hello there", _opts}, 2_000
  end

  test "additional chunks after a flush wait for the next throttle window" do
    run_id = "run-#{System.unique_integer([:positive])}"
    start_session(run_id)

    LivenessSession.stream_chunk(run_id, "first")
    assert_receive {:telegram_send, "c1", "…"}, 1_000
    assert_receive {:telegram_edit, "c1", "9999", "first", _opts}, 2_000

    LivenessSession.stream_chunk(run_id, " second")
    assert_receive {:telegram_edit, "c1", "9999", "first second", _opts}, 2_500
  end

  test "stream_done cancels pending flushes and clears stream_active" do
    run_id = "run-#{System.unique_integer([:positive])}"
    start_session(run_id)

    LivenessSession.stream_chunk(run_id, "abc")
    assert_receive {:telegram_send, "c1", "…"}, 1_000

    LivenessSession.stream_done(run_id)

    refute_receive {:telegram_edit, "c1", _, _, _}, 1_500
  end
end
