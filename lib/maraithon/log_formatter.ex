defmodule Maraithon.LogFormatter do
  @moduledoc """
  JSON log formatter for Cloud Logging (GCP).
  Outputs structured logs that Cloud Logging can parse automatically.
  """

  @structured_metadata_fields [
    :request_id,
    :agent_id,
    :effect_id,
    :job_id,
    :job_type,
    :error,
    :reason,
    :provider,
    :user_id,
    :status,
    :duration_ms,
    :model,
    :reasoning_effort,
    :input_tokens,
    :output_tokens,
    :finish_reason,
    :detail_failure_count,
    :truncated,
    :backfill_needed
  ]

  def format(level, message, timestamp, metadata) do
    {date, {hour, minute, second, millisecond}} = timestamp

    iso_timestamp =
      NaiveDateTime.new!(
        Date.from_erl!(date),
        Time.new!(hour, minute, second, {millisecond * 1_000, 3})
      )
      |> NaiveDateTime.to_iso8601()

    log_entry = %{
      severity: severity(level),
      message: message |> IO.iodata_to_binary() |> Maraithon.Redaction.redact_string(),
      timestamp: iso_timestamp,
      "logging.googleapis.com/labels": metadata_to_labels(metadata)
    }

    log_entry =
      metadata
      |> Keyword.take(@structured_metadata_fields)
      |> Enum.reduce(log_entry, fn {key, value}, acc ->
        Map.put(acc, key, metadata_value(value))
      end)

    [Jason.encode!(log_entry), "\n"]
  rescue
    _ ->
      # Keep the emergency fallback credential-safe too.
      safe_message = message |> IO.iodata_to_binary() |> Maraithon.Redaction.redact_string()
      "#{level} #{safe_message}\n"
  end

  defp severity(:debug), do: "DEBUG"
  defp severity(:info), do: "INFO"
  defp severity(:warn), do: "WARNING"
  defp severity(:warning), do: "WARNING"
  defp severity(:error), do: "ERROR"
  defp severity(_), do: "DEFAULT"

  defp metadata_to_labels(metadata) do
    labels =
      metadata
      |> Keyword.take([:module, :function, :line])
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)

    case Keyword.get(metadata, :mfa) do
      {module, function, arity}
      when is_atom(module) and is_atom(function) and is_integer(arity) ->
        labels
        |> Map.put_new("module", Atom.to_string(module))
        |> Map.put_new("function", "#{function}/#{arity}")

      _other ->
        labels
    end
  end

  defp metadata_value(value) when is_binary(value),
    do: Maraithon.Redaction.redact_string(value)

  defp metadata_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp metadata_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp metadata_value(value) do
    value
    |> Maraithon.Redaction.redact()
    |> inspect(pretty: false, limit: 20, printable_limit: 500)
    |> Maraithon.Redaction.redact_string()
  end
end
