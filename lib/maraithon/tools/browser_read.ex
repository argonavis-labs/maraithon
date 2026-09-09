defmodule Maraithon.Tools.BrowserRead do
  @moduledoc "Read, navigate, or reveal a todo's dedicated browser on the paired Mac."
  def execute(args) do
    case Maraithon.TodoBrowser.execute(args, :read) do
      {:error, {:browser_unknown, message}} ->
        Maraithon.Tools.provider_error("browser", :timeout, message)

      result ->
        result
    end
  end
end
