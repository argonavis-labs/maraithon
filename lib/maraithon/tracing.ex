defmodule Maraithon.Tracing do
  @moduledoc """
  Thin wrapper over OpenTelemetry span macros.

  Centralises the OTel API surface so the rest of the codebase has one small,
  testable interface. When the OTel exporter is disabled (`:none`, the default
  in dev/test), span operations are effectively no-ops; this module still
  returns the wrapped value unchanged and never raises into caller code.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Run `fun` inside a span named `name` with `attributes`.

  Returns `fun`'s value unchanged. Exceptions are recorded on the span and
  re-raised so control flow is never altered.
  """
  @spec with_span(String.t(), map(), (-> result)) :: result when result: term()
  def with_span(name, attributes, fun)
      when is_binary(name) and is_map(attributes) and is_function(fun, 0) do
    Tracer.with_span name, %{attributes: normalize_attributes(attributes)} do
      try do
        fun.()
      rescue
        exception ->
          error_class = Maraithon.Redaction.error_class(exception)
          Tracer.add_event("exception", %{"error_class" => error_class})
          Tracer.set_status(OpenTelemetry.status(:error, error_class))
          reraise exception, __STACKTRACE__
      end
    end
  end

  @doc """
  Mark the current span as failed and attach `reason` as a span event.

  Safe to call when there is no active span. Always returns `:ok`.
  """
  @spec record_error(term()) :: :ok
  def record_error(reason) do
    description = Maraithon.Redaction.error_summary(reason)
    Tracer.add_event("error", %{"reason" => description})
    Tracer.set_status(OpenTelemetry.status(:error, description))
    :ok
  rescue
    _ -> :ok
  end

  @identifier_attribute_keys ~w(user_id chat_id telegram_chat_id account_id owner_user_id)
  @label_attribute_keys ~w(
    provider model reasoning_effort finish_reason status source kind stage operation
    task_class route_reason model_tier prompt_kind failure_code error_class request_focus
    job_type calendar_source streaming
  )

  # Span attributes are an exported trust boundary. Numeric telemetry is safe;
  # identifiers are pseudonymized; only closed label fields may retain strings.
  defp normalize_attributes(attributes) do
    Map.new(attributes, fn {key, value} -> {key, normalize_attribute(key, value)} end)
  end

  defp normalize_attribute(key, value) do
    normalized_key = if is_atom(key) or is_binary(key), do: to_string(key), else: ""

    cond do
      normalized_key in @identifier_attribute_keys ->
        identifier_fingerprint(value)

      is_integer(value) or is_float(value) or is_boolean(value) ->
        value

      normalized_key in @label_attribute_keys ->
        normalize_label(value)

      true ->
        "redacted_detail"
    end
  end

  defp identifier_fingerprint(value) when is_binary(value),
    do: Maraithon.Redaction.fingerprint(value)

  defp identifier_fingerprint(value) when is_integer(value),
    do: value |> Integer.to_string() |> Maraithon.Redaction.fingerprint()

  defp identifier_fingerprint(_value), do: "redacted_detail"

  defp normalize_label(value) when is_atom(value), do: normalize_label(Atom.to_string(value))

  defp normalize_label(value) when is_binary(value) do
    if byte_size(value) <= 128 and String.valid?(value) and
         Regex.match?(~r/^[A-Za-z0-9._:\/-]+$/, value),
       do: value,
       else: "redacted_detail"
  end

  defp normalize_label(_value), do: "redacted_detail"
end
