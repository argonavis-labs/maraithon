defmodule Maraithon.Runtime.BootGate do
  @moduledoc false

  @key {__MODULE__, :effect_admission_open}

  def close do
    :persistent_term.put(@key, false)
    :ok
  end

  def open do
    :persistent_term.put(@key, true)
    :ok
  end

  def open? do
    :persistent_term.get(@key, false) == true
  end
end
