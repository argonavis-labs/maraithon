defmodule Maraithon.ControlCalls do
  @moduledoc """
  Idempotency support for side-effecting control protocol calls.
  """

  import Ecto.Query

  alias Maraithon.ControlCalls.ControlCall
  alias Maraithon.Normalization
  alias Maraithon.Redaction
  alias Maraithon.Repo
  alias Maraithon.Tools.ToolErrorCopy

  @default_ttl_seconds 24 * 60 * 60
  @generic_control_error "Action did not complete. No confirmed change was recorded."

  def run(attrs, fun) when is_map(attrs) and is_function(fun, 0) do
    method = read_string(attrs, :method)
    idempotency_key = read_string(attrs, :idempotency_key)
    user_id = read_string(attrs, :user_id)
    request_hash = request_hash(Map.get(attrs, :request, %{}))

    cond do
      is_nil(method) ->
        {:error, :missing_method}

      is_nil(idempotency_key) ->
        run_without_idempotency(fun)

      true ->
        run_idempotent(method, idempotency_key, user_id, request_hash, fun)
    end
  end

  def run(_attrs, fun) when is_function(fun, 0), do: run_without_idempotency(fun)

  def request_hash(request) do
    request
    |> stable_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def purge_expired(now \\ DateTime.utc_now()) do
    {count, _rows} =
      ControlCall
      |> where([call], call.expires_at < ^now)
      |> Repo.delete_all()

    {:ok, count}
  end

  defp run_idempotent(method, key, user_id, request_hash, fun) do
    case Repo.get_by(ControlCall, method: method, idempotency_key: key) do
      nil ->
        insert_and_run(method, key, user_id, request_hash, fun)

      %ControlCall{} = call ->
        replay_or_reject(call, request_hash)
    end
  end

  defp insert_and_run(method, key, user_id, request_hash, fun) do
    attrs = %{
      method: method,
      idempotency_key: key,
      user_id: user_id,
      request_hash: request_hash,
      status: "pending",
      expires_at: DateTime.add(DateTime.utc_now(), ttl_seconds(), :second)
    }

    case %ControlCall{} |> ControlCall.changeset(attrs) |> Repo.insert() do
      {:ok, call} ->
        execute_and_store(call, fun)

      {:error, changeset} ->
        if unique_conflict?(changeset) do
          run_idempotent(method, key, user_id, request_hash, fun)
        else
          {:error, {:invalid_idempotency_record, changeset}}
        end
    end
  end

  defp execute_and_store(call, fun) do
    case fun.() do
      {:ok, result} ->
        result = normalize_payload(result)

        {:ok, _call} =
          call
          |> ControlCall.changeset(%{
            status: "completed",
            result: result,
            error: %{},
            completed_at: DateTime.utc_now()
          })
          |> Repo.update()

        {:ok, result, replay?: false}

      {:error, reason} ->
        error = normalize_error(reason)

        {:ok, _call} =
          call
          |> ControlCall.changeset(%{
            status: "failed",
            result: %{},
            error: error,
            completed_at: DateTime.utc_now()
          })
          |> Repo.update()

        {:error, error, replay?: false}
    end
  end

  defp replay_or_reject(%ControlCall{} = call, request_hash) do
    cond do
      call.request_hash != request_hash ->
        {:error, :idempotency_key_conflict, replay?: false}

      call.status == "completed" ->
        {:ok, call.result || %{}, replay?: true}

      call.status == "failed" ->
        {:error, call.error || %{}, replay?: true}

      true ->
        {:error, :idempotency_key_in_progress, replay?: false}
    end
  end

  defp run_without_idempotency(fun) do
    case fun.() do
      {:ok, result} -> {:ok, normalize_payload(result), replay?: false}
      {:error, reason} -> {:error, normalize_error(reason), replay?: false}
    end
  end

  defp ttl_seconds do
    :maraithon
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_seconds, @default_ttl_seconds)
    |> normalize_positive_integer(@default_ttl_seconds)
  end

  defp stable_json(value) do
    case Jason.encode(normalize_payload(value)) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  defp normalize_payload(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_payload(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_payload(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_payload(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_payload(value) when is_struct(value),
    do: value |> Map.from_struct() |> normalize_payload()

  defp normalize_payload(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, nested_value} -> {to_string(key), normalize_payload(nested_value)} end)
  end

  defp normalize_payload(value) when is_list(value), do: Enum.map(value, &normalize_payload/1)
  defp normalize_payload(value) when is_tuple(value), do: inspect(value)
  defp normalize_payload(value) when is_pid(value), do: inspect(value)
  defp normalize_payload(value) when is_reference(value), do: inspect(value)
  defp normalize_payload(value) when is_function(value), do: inspect(value)
  defp normalize_payload(value), do: value

  defp normalize_error(reason) when is_map(reason) do
    reason
    |> Redaction.redact()
    |> normalize_payload()
  end

  defp normalize_error(reason) when is_binary(reason) do
    %{"message" => ToolErrorCopy.safe_message(reason, @generic_control_error)}
  end

  defp normalize_error(_reason), do: %{"message" => @generic_control_error}

  defp read_string(attrs, key), do: Normalization.read_string(attrs, key)

  defp unique_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {_, {_message, details}} -> details[:constraint] == :unique
      _other -> false
    end)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Normalization.parse_integer(value) do
      parsed when is_integer(parsed) and parsed > 0 -> parsed
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default
end
