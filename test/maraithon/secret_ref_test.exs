defmodule Maraithon.SecretRefTest do
  use ExUnit.Case, async: false

  alias Maraithon.SecretRef

  setup do
    previous_config = Application.get_env(:maraithon, SecretRef)
    previous_env = System.get_env("MARAITHON_SECRET_REF_TEST")

    System.put_env("MARAITHON_SECRET_REF_TEST", "super-secret-value")

    on_exit(fn ->
      case previous_config do
        nil -> Application.delete_env(:maraithon, SecretRef)
        config -> Application.put_env(:maraithon, SecretRef, config)
      end

      case previous_env do
        nil -> System.delete_env("MARAITHON_SECRET_REF_TEST")
        value -> System.put_env("MARAITHON_SECRET_REF_TEST", value)
      end
    end)

    :ok
  end

  test "resolves env and file refs while snapshots stay redacted" do
    path = Path.join(System.tmp_dir!(), "maraithon-secret-ref-#{System.unique_integer()}")
    File.write!(path, "file-secret\n")

    assert {:ok, resolved} = SecretRef.resolve("env:MARAITHON_SECRET_REF_TEST")
    assert resolved.value == "super-secret-value"
    assert is_binary(resolved.fingerprint)

    assert {:ok, resolved_file} = SecretRef.resolve("file:#{path}")
    assert resolved_file.value == "file-secret"

    snapshot =
      SecretRef.snapshot(%{
        telegram: %{
          token: "env:MARAITHON_SECRET_REF_TEST",
          missing: "env:MARAITHON_SECRET_REF_MISSING"
        }
      })

    assert [
             %{name: "missing", status: "missing", reason_code: "missing_env"},
             %{name: "token", status: "resolved", fingerprint: fingerprint}
           ] = Enum.sort_by(snapshot["telegram"], & &1.name)

    assert is_binary(fingerprint)
    refute inspect(snapshot) =~ "super-secret-value"
  end

  test "validates active surfaces and rejects exec refs without an allowlist" do
    surfaces = %{
      "telegram" => %{"token" => "env:MARAITHON_SECRET_REF_TEST"},
      "slack" => %{"token" => "env:MARAITHON_SECRET_REF_MISSING"},
      "exec" => %{"provider" => "exec:/bin/echo secret"}
    }

    assert {:error, result} = SecretRef.validate_active_surfaces(surfaces, ["telegram", "slack"])
    assert result.status == "blocked"
    assert [%{surface: "slack", reason_code: "missing_env"}] = result.findings

    snapshot = SecretRef.snapshot(surfaces)
    exec_entry = snapshot["exec"] |> List.first()
    assert exec_entry.status == "error"
    assert exec_entry.reason_code == "exec_not_allowed"
  end
end
