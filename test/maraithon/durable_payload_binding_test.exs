defmodule Maraithon.DurablePayloadBindingTest do
  use ExUnit.Case, async: false

  alias Maraithon.DurablePayloadBinding

  setup do
    names = [
      "DURABLE_PAYLOAD_BINDING_CURRENT_TAG",
      "DURABLE_PAYLOAD_BINDING_CURRENT_KEY",
      "DURABLE_PAYLOAD_BINDING_PREVIOUS_KEYS"
    ]

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "binding is canonical and rejects row, tenant, and field substitution" do
    fields = [{"request", %{answer: 42}}, {"response", %{"ok" => true}}]
    binding = DurablePayloadBinding.sign("agent_run_steps", "row-1", "agent-1", fields)

    assert :ok =
             DurablePayloadBinding.verify(
               "agent_run_steps",
               "row-1",
               "agent-1",
               [{"request", %{"answer" => 42}}, {"response", %{ok: true}}],
               binding.version,
               binding.key_tag,
               binding.mac
             )

    assert {:error, :binding_mismatch} =
             DurablePayloadBinding.verify(
               "agent_run_steps",
               "row-2",
               "agent-1",
               fields,
               binding.version,
               binding.key_tag,
               binding.mac
             )

    assert {:error, :binding_mismatch} =
             DurablePayloadBinding.verify(
               "agent_run_steps",
               "row-1",
               "agent-2",
               fields,
               binding.version,
               binding.key_tag,
               binding.mac
             )

    assert {:error, :binding_mismatch} =
             DurablePayloadBinding.verify(
               "agent_run_steps",
               "row-1",
               "agent-1",
               Enum.reverse(fields),
               binding.version,
               binding.key_tag,
               binding.mac
             )
  end
end
