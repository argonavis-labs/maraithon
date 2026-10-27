defmodule Maraithon.Runtime.SecretParameterLoggingPolicy do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Maraithon.Repo

  @doc false
  def verify!(unsafe_reason) when is_atom(unsafe_reason) do
    _ =
      SQL.query!(
        Repo,
        "SELECT set_config('log_parameter_max_length_on_error', '0', true) IS NOT NULL",
        [],
        log: false,
        telemetry_event: false
      )

    profile =
      case SQL.query!(
             Repo,
             """
             SELECT current_setting('log_parameter_max_length'),
                    current_setting('log_parameter_max_length_on_error'),
                    current_setting('log_statement'),
                    current_setting('log_duration'),
                    current_setting('log_min_duration_statement'),
                    current_setting('log_min_duration_sample'),
                    current_setting('log_transaction_sample_rate'),
                    current_setting('pgaudit.log_parameter', true),
                    current_setting('auto_explain.log_min_duration', true),
                    current_setting('auto_explain.log_parameter_max_length', true)
             """,
             [],
             log: false,
             telemetry_event: false
           ).rows do
        [
          [
            parameter_max,
            error_parameter_max,
            statement,
            duration,
            minimum_duration,
            minimum_sample_duration,
            transaction_sample_rate,
            pgaudit_parameter,
            auto_explain_minimum_duration,
            auto_explain_parameter_max
          ]
        ] ->
          %{
            parameter_max: parameter_max,
            error_parameter_max: error_parameter_max,
            statement: statement,
            duration: duration,
            minimum_duration: minimum_duration,
            minimum_sample_duration: minimum_sample_duration,
            transaction_sample_rate: transaction_sample_rate,
            pgaudit_parameter: pgaudit_parameter,
            auto_explain_minimum_duration: auto_explain_minimum_duration,
            auto_explain_parameter_max: auto_explain_parameter_max
          }

        _ ->
          %{}
      end

    unless safe_profile?(profile), do: Repo.rollback(unsafe_reason)
    :ok
  end

  @doc false
  def safe_profile?(profile) when is_map(profile) do
    profile[:error_parameter_max] == "0" and
      pgaudit_safe?(profile) and
      auto_explain_safe?(profile) and
      (profile[:parameter_max] == "0" or normal_statement_logging_off?(profile))
  end

  def safe_profile?(_profile), do: false

  defp normal_statement_logging_off?(profile) do
    profile[:statement] == "none" and
      profile[:duration] == "off" and
      profile[:minimum_duration] == "-1" and
      profile[:minimum_sample_duration] == "-1" and
      profile[:transaction_sample_rate] == "0"
  end

  defp pgaudit_safe?(profile), do: profile[:pgaudit_parameter] in [nil, "off"]

  defp auto_explain_safe?(profile) do
    profile[:auto_explain_minimum_duration] in [nil, "-1"] or
      profile[:auto_explain_parameter_max] == "0"
  end
end
