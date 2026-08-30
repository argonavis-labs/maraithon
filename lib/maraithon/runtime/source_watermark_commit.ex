defmodule Maraithon.Runtime.SourceWatermarkCommit do
  @moduledoc false

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.SourceCycleSettlement

  @job_watermark_kinds %{
    "runtime_partition:source_account_discovery" =>
      ~w(gmail_discovery_watermark slack_discovery_watermark),
    "runtime_partition:source_account_discovery_finalize" =>
      ~w(gmail_discovery_watermark slack_discovery_watermark),
    "runtime_partition:source_account_closure_acquire" =>
      ~w(gmail_closure_watermark slack_closure_watermark),
    "runtime_partition:source_account_closure_finalize" =>
      ~w(gmail_closure_watermark slack_closure_watermark)
  }

  @doc false
  def commit_and_sanitize(%BackgroundJob{} = job, {:ok, result}) when is_map(result) do
    case deferred_watermarks(result) do
      nil ->
        {:ok, {:ok, result}}

      watermarks when is_list(watermarks) ->
        with {:ok, allowed_kinds} <- allowed_kinds(job.job_type),
             account_id when is_integer(account_id) and account_id > 0 <-
               read_integer(result, "account_id"),
             %ConnectedAccount{} = account <- Repo.get(ConnectedAccount, account_id),
             true <- account.user_id == job.user_id,
             :ok <- validate_watermarks(watermarks, account_id, allowed_kinds),
             {:ok, _proof} <- SourceCycleSettlement.seal(job, result, account, watermarks),
             :ok <- commit_watermarks(account, watermarks) do
          {:ok, {:ok, sanitize_result(result, length(watermarks))}}
        else
          false -> {:error, :source_watermark_user_mismatch}
          nil -> {:error, :source_watermark_account_not_found}
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_deferred_source_watermark}
        end
    end
  end

  def commit_and_sanitize(%BackgroundJob{}, handler_result), do: {:ok, handler_result}

  @doc false
  def deferred?(handler_result) do
    case handler_result do
      {:ok, result} when is_map(result) -> is_list(deferred_watermarks(result))
      _other -> false
    end
  end

  defp allowed_kinds(job_type) do
    case Map.fetch(@job_watermark_kinds, job_type) do
      {:ok, kinds} -> {:ok, kinds}
      :error -> {:error, :source_watermark_job_type_not_allowed}
    end
  end

  defp validate_watermarks([watermark], account_id, allowed_kinds) when is_map(watermark) do
    with ^account_id <- read_integer(watermark, "account_id"),
         kind when is_binary(kind) <- read_string(watermark, "kind"),
         true <- kind in allowed_kinds,
         value when is_binary(value) and value != "" <- read_string(watermark, "value") do
      :ok
    else
      _invalid -> {:error, :invalid_deferred_source_watermark}
    end
  end

  defp validate_watermarks(_watermarks, _account_id, _allowed_kinds),
    do: {:error, :invalid_deferred_source_watermark}

  defp commit_watermarks(account, watermarks) do
    Enum.reduce_while(watermarks, :ok, fn watermark, :ok ->
      kind = read_string(watermark, "kind")
      value = read_string(watermark, "value")

      case SourceCursors.put(account, kind, %{"value" => value}) do
        {:ok, _cursor} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:source_cursor_advance_failed, reason}}}
      end
    end)
  end

  defp sanitize_result(result, advanced_count) do
    result
    |> Map.delete(:deferred_watermarks)
    |> Map.delete("deferred_watermarks")
    |> Map.delete(:source_item_refs)
    |> Map.delete("source_item_refs")
    |> Map.delete(:source_proof_items)
    |> Map.delete("source_proof_items")
    |> Map.put(:advanced_watermarks, advanced_count)
  end

  defp deferred_watermarks(result),
    do: Map.get(result, :deferred_watermarks, Map.get(result, "deferred_watermarks"))

  defp read_integer(map, key) do
    case Map.get(map, key, Map.get(map, existing_atom(key))) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp read_string(map, key) do
    case Map.get(map, key, Map.get(map, existing_atom(key))) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp existing_atom("account_id"), do: :account_id
  defp existing_atom("kind"), do: :kind
  defp existing_atom("value"), do: :value
end
