defmodule Maraithon.TestSupport.DiscardBackgroundJobTestHandler do
  @moduledoc false

  def execute(%Maraithon.Runtime.BackgroundJob{}) do
    {:error, {:discard, :permanent_background_failure}}
  end
end
