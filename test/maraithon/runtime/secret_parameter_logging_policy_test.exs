defmodule Maraithon.Runtime.SecretParameterLoggingPolicyTest do
  use ExUnit.Case, async: true

  alias Maraithon.Runtime.SecretParameterLoggingPolicy

  test "accepts zero core parameter logging only when extension routes are also safe" do
    profile =
      safe_managed_profile()
      |> Map.put(:parameter_max, "0")
      |> Map.put(:statement, "all")

    assert SecretParameterLoggingPolicy.safe_profile?(profile)
    refute SecretParameterLoggingPolicy.safe_profile?(%{profile | pgaudit_parameter: "on"})

    refute SecretParameterLoggingPolicy.safe_profile?(%{
             profile
             | auto_explain_minimum_duration: "0",
               auto_explain_parameter_max: "-1"
           })
  end

  test "accepts the managed PostgreSQL profile only when every normal route is off" do
    profile = safe_managed_profile()
    assert SecretParameterLoggingPolicy.safe_profile?(profile)

    unsafe_routes = [
      {:statement, "all"},
      {:duration, "on"},
      {:minimum_duration, "0"},
      {:minimum_sample_duration, "0"},
      {:transaction_sample_rate, "1"},
      {:error_parameter_max, "-1"},
      {:pgaudit_parameter, "on"}
    ]

    Enum.each(unsafe_routes, fn {setting, value} ->
      refute SecretParameterLoggingPolicy.safe_profile?(Map.put(profile, setting, value))
    end)
  end

  test "accepts auto-explain only when inactive or parameter logging is zero" do
    profile = safe_managed_profile()

    assert SecretParameterLoggingPolicy.safe_profile?(profile)

    assert SecretParameterLoggingPolicy.safe_profile?(%{
             profile
             | auto_explain_minimum_duration: "0",
               auto_explain_parameter_max: "0"
           })

    refute SecretParameterLoggingPolicy.safe_profile?(%{
             profile
             | auto_explain_minimum_duration: "0",
               auto_explain_parameter_max: "-1"
           })
  end

  defp safe_managed_profile do
    %{
      parameter_max: "-1",
      error_parameter_max: "0",
      statement: "none",
      duration: "off",
      minimum_duration: "-1",
      minimum_sample_duration: "-1",
      transaction_sample_rate: "0",
      pgaudit_parameter: nil,
      auto_explain_minimum_duration: nil,
      auto_explain_parameter_max: nil
    }
  end
end
