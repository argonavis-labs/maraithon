defmodule Maraithon.OperatorMemoryTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.OperatorMemory

  test "fallback summaries avoid internal durable-memory language" do
    user_id = "operator-memory-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert :ok =
             OperatorMemory.refresh_user_summaries(user_id,
               llm_complete: fn _prompt -> {:error, :summary_unavailable} end
             )

    summaries = OperatorMemory.summaries_for_prompt(user_id)

    assert length(summaries) == 4
    assert Enum.any?(summaries, &(&1.content == "No confirmed content preferences yet."))
    assert Enum.any?(summaries, &(&1.content == "No confirmed interruption policy yet."))
    assert Enum.any?(summaries, &(&1.content == "No confirmed action-style preferences yet."))
    assert Enum.any?(summaries, &(&1.content == "No confirmed Telegram behavior summary yet."))
    refute Enum.any?(summaries, &String.contains?(&1.content, "durable"))
  end
end
