defmodule Maraithon.TelegramResponderTest do
  use ExUnit.Case, async: false

  alias Maraithon.TelegramResponder
  alias Maraithon.TestSupport.CapturingTelegram

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights_config = Application.get_env(:maraithon, :insights, [])
    Application.put_env(:maraithon, :insights, telegram_module: CapturingTelegram)

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights_config)
    end)

    :ok
  end

  test "send converts markdown to Telegram HTML by default" do
    assert {:ok, %{"message_id" => "1"}} =
             TelegramResponder.send("123", "## Today's Schedule\n- **Dawn** and `getdelegates`")

    [message] = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert message.opts[:parse_mode] == "HTML"
    assert message.text =~ "<b>Today's Schedule</b>"
    assert message.text =~ "• <b>Dawn</b> and <code>getdelegates</code>"
    refute message.text =~ "##"
    refute message.text =~ "**Dawn**"
  end

  test "send preserves explicit HTML payloads" do
    assert {:ok, %{"message_id" => "1"}} =
             TelegramResponder.send("123", "<b>Already HTML</b>", parse_mode: "HTML")

    [message] = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert message.opts[:parse_mode] == "HTML"
    assert message.text == "<b>Already HTML</b>"
  end

  test "reply and edit convert markdown to Telegram HTML by default" do
    assert {:ok, _result} = TelegramResponder.reply("123", "456", "- **Reply**")
    assert {:ok, _result} = TelegramResponder.edit("123", "789", "## Updated")

    [reply, edit] = Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)

    assert reply.opts[:parse_mode] == "HTML"
    assert reply.opts[:reply_to] == "456"
    assert reply.text == "• <b>Reply</b>"

    assert edit.opts[:parse_mode] == "HTML"
    assert edit.text == "<b>Updated</b>"
  end
end
