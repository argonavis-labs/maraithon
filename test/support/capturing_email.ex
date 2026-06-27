defmodule Maraithon.TestSupport.CapturingEmail do
  @moduledoc false

  def configured?, do: true

  def send(to, content) when is_binary(to) and is_map(content) do
    if pid = Process.whereis(:capturing_email_recorder) do
      Agent.update(pid, fn emails -> [%{to: to, content: content} | emails] end)
    end

    :ok
  end
end
