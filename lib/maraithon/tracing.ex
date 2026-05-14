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
          Tracer.record_exception(exception, __STACKTRACE__)
          Tracer.set_status(OpenTelemetry.status(:error, Exception.message(exception)))
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
    description = inspect(reason)
    Tracer.add_event("error", %{"reason" => description})
    Tracer.set_status(OpenTelemetry.status(:error, description))
    :ok
  rescue
    _ -> :ok
  end

  # OTel attribute values must be primitives (or lists of primitives); coerce
  # anything else to an inspected string.
  defp normalize_attributes(attributes) do
    Map.new(attributes, fn {key, value} -> {key, normalize_value(value)} end)
  end

  defp normalize_value(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value),
       do: value

  defp normalize_value(value) when is_atom(value), do: to_string(value)
  defp normalize_value(value), do: inspect(value)
end
