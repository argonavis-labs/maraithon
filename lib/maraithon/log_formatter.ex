defmodule Maraithon.LogFormatter do
  @moduledoc """
  JSON log formatter for Cloud Logging (GCP).
  Outputs structured logs that Cloud Logging can parse automatically.
  """

  def format(level, message, timestamp, metadata) do
    {date, {hour, minute, second, millisecond}} = timestamp

    iso_timestamp =
      DateTime.new!(
        Date.from_erl!(date),
        Time.new!(hour, minute, second, {millisecond * 1_000, 3}),
        "Etc/UTC"
      )
      |> DateTime.to_iso8601()

    log_entry = %{
      severity: severity(level),
      message: message |> IO.iodata_to_binary() |> Maraithon.Redaction.redact_string(),
      timestamp: iso_timestamp,
      "logging.googleapis.com/labels": metadata_to_labels(metadata)
    }

    log_entry =
      metadata
      |> Keyword.take(Maraithon.SafeLogMetadata.structured_fields())
      |> Enum.reduce(log_entry, fn {key, value}, acc ->
        Map.put(acc, key, metadata_value(key, value))
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
      %{}
      |> maybe_put_source_module(Keyword.get(metadata, :module))
      |> maybe_put_source_line(Keyword.get(metadata, :line))

    case Keyword.get(metadata, :mfa) do
      {module, function, arity}
      when is_atom(module) and is_atom(function) and is_integer(arity) and arity in 0..255 ->
        labels
        |> maybe_put_source_module(module)
        |> maybe_put_source_function(function, arity)

      _other ->
        labels
    end
  end

  defp maybe_put_source_module(labels, module)
       when is_atom(module) and module not in [nil, true, false] do
    case safe_source_label(Atom.to_string(module), 255) do
      nil -> labels
      value -> Map.put_new(labels, "module", value)
    end
  end

  defp maybe_put_source_module(labels, _module), do: labels

  defp maybe_put_source_function(labels, function, arity)
       when is_atom(function) and is_integer(arity) do
    case safe_source_label("#{function}/#{arity}", 255) do
      nil -> labels
      value -> Map.put_new(labels, "function", value)
    end
  end

  defp maybe_put_source_line(labels, line) when is_integer(line) and line in 0..10_000_000,
    do: Map.put(labels, "line", Integer.to_string(line))

  defp maybe_put_source_line(labels, _line), do: labels

  defp safe_source_label(value, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value) and Regex.match?(~r/^[A-Za-z0-9._:\/-]+$/, value),
      do: value,
      else: nil
  end

  defp safe_source_label(_value, _max_bytes), do: nil

  defp metadata_value(key, value) do
    key
    |> Maraithon.Redaction.log_metadata_value(value)
    |> do_metadata_value()
  end

  defp do_metadata_value(value) when is_binary(value),
    do: Maraithon.Redaction.redact_string(value)

  defp do_metadata_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp do_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp do_metadata_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp do_metadata_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp do_metadata_value(value) do
    value
    |> Maraithon.Redaction.redact()
    |> inspect(pretty: false, limit: 20, printable_limit: 500)
    |> Maraithon.Redaction.redact_string()
  end
end
