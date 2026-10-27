defmodule Maraithon.TestSupport.ContinuationToolbox do
  @moduledoc false
  def execute(tool, arguments, _context) do
    pid = Application.fetch_env!(:maraithon, :continuation_test_pid)
    send(pid, {:continuation_tool, tool, arguments, self()})

    if tool == "get_person" and Application.get_env(:maraithon, :continuation_test_pause) do
      receive do
        :release -> :ok
      end
    end

    if arguments["lose_response"],
      do: {:error, {:network_error, :closed}},
      else: {:ok, %{"found" => true, "source" => tool}}
  end
end
