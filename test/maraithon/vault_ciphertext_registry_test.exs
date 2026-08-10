defmodule Maraithon.VaultCiphertextRegistryTest do
  use ExUnit.Case, async: true

  alias Maraithon.DurablePayloadRegistry
  alias Maraithon.VaultCiphertextRegistry

  test "closed Vault registry covers every encrypted Ecto field" do
    {:ok, modules} = :application.get_key(:maraithon, :modules)

    discovered =
      for module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :__schema__, 1),
          field <- module.__schema__(:fields),
          module.__schema__(:type, field) in [Maraithon.Encrypted.Binary, Maraithon.Encrypted.Map] do
        {module, field, module.__schema__(:field_source, field) |> to_string()}
      end
      |> MapSet.new()

    registered =
      VaultCiphertextRegistry.all()
      |> Enum.map(&{&1.module, &1.field, &1.column})
      |> MapSet.new()

    assert registered == discovered
  end

  test "durable registry is identical to every schema binding contract" do
    for source <- DurablePayloadRegistry.all() do
      spec = source.module.payload_binding_spec()

      assert spec.table == source.table
      assert spec.identity_fields == source.identity
      assert spec.scope_fields == source.scope
      assert spec.fields == Enum.map(source.fields, &elem(&1, 0))
      assert spec.purge_field == source.purge
    end
  end
end
