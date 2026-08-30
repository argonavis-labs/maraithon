defmodule Maraithon.Runtime.SourceAccountClosure do
  @moduledoc """
  Runs one source-account closure worker as a durable provider/model handoff.

  The provider lane reads only the account's closure delta. Empty deltas move
  the closure cursor without model work; non-empty deltas are sealed into a
  bounded encrypted job and evaluated against only that account's open todos.
  """

  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Runtime.SourceAccountDiscovery
  alias Maraithon.Runtime.TodoCompletionSweep

  @allowed_watermark_kinds ~w(gmail_closure_watermark slack_closure_watermark)

  def acquire(account, opts \\ [])

  def acquire(%ConnectedAccount{status: "connected"} = account, opts) when is_list(opts) do
    with {:ok, bundle, proposals} <- TodoCompletionSweep.acquire_account_delta(account, opts),
         compact when is_map(compact) <- SourceAccountDiscovery.compact_bundle(bundle),
         watermarks <- serialize_watermarks(proposals, account.id),
         source_items <- SourceAccountDiscovery.source_item_count(compact) do
      if source_items == 0 do
        with :ok <- advance_watermarks(account, watermarks) do
          {:ok,
           %{
             outcome: "empty_delta",
             account_id: account.id,
             source_items: 0,
             model_calls: 0,
             advanced_watermarks: length(watermarks)
           }}
        end
      else
        {:ok,
         %{
           outcome: "handoff_ready",
           account_id: account.id,
           source_items: source_items,
           handoff: %{
             "account_id" => account.id,
             "acquisition_job_id" => Keyword.get(opts, :acquisition_job_id),
             "source_bundle" => compact,
             "watermarks" => watermarks
           }
         }}
      end
    else
      nil -> {:error, :invalid_source_bundle}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_closure_result}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def acquire(%ConnectedAccount{}, _opts), do: {:skip, :account_not_connected}
  def acquire(_account, _opts), do: {:error, :invalid_source_account}

  def reason(account, payload, opts \\ [])

  def reason(%ConnectedAccount{} = account, payload, opts)
      when is_map(payload) and is_list(opts) do
    with true <- read_integer(payload, "account_id") == account.id,
         {:ok, bundle} <- fetch_map(payload, "source_bundle"),
         {:ok, watermarks} <- fetch_list(payload, "watermarks"),
         result <-
           TodoCompletionSweep.run_for_account(
             account,
             Keyword.put(opts, :source_bundle, bundle)
           ),
         true <- settled_result?(result),
         :ok <- advance_watermarks(account, watermarks) do
      {:ok,
       %{
         outcome: "evaluated",
         account_id: account.id,
         source_items: SourceAccountDiscovery.source_item_count(bundle),
         result: result
       }}
    else
      false -> {:error, :source_closure_unsettled_or_identity_mismatch}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_source_closure_payload}
    end
  rescue
    error -> {:error, Maraithon.Redaction.error_class(error)}
  catch
    kind, reason -> {:error, {kind, Maraithon.Redaction.error_class(reason)}}
  end

  def reason(_account, _payload, _opts), do: {:error, :invalid_source_closure_payload}

  defp settled_result?(%{errors: 0, cross_source: {:error, _reason}}), do: false
  defp settled_result?(%{errors: 0, cross_source: {:skip, :no_open_todos}}), do: true
  defp settled_result?(%{errors: 0}), do: true
  defp settled_result?(_result), do: false

  defp serialize_watermarks(proposals, account_id) when is_list(proposals) do
    proposals
    |> Enum.flat_map(fn
      %{
        account: %ConnectedAccount{id: ^account_id},
        kind: kind,
        value: value
      }
      when kind in @allowed_watermark_kinds and is_binary(value) ->
        [%{"account_id" => account_id, "kind" => kind, "value" => value}]

      _other ->
        []
    end)
    |> Enum.uniq_by(&{&1["kind"], &1["value"]})
  end

  defp serialize_watermarks(_proposals, _account_id), do: []

  defp advance_watermarks(account, watermarks) do
    Enum.reduce_while(watermarks, :ok, fn watermark, :ok ->
      with true <- read_integer(watermark, "account_id") == account.id,
           kind when kind in @allowed_watermark_kinds <- read_string(watermark, "kind"),
           value when is_binary(value) <- read_string(watermark, "value"),
           {:ok, _cursor} <- SourceCursors.put(account, kind, %{"value" => value}) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, :source_closure_watermark_account_mismatch}}
        nil -> {:halt, {:error, :invalid_source_closure_watermark}}
        {:error, reason} -> {:halt, {:error, {:source_closure_cursor_advance_failed, reason}}}
        _other -> {:halt, {:error, :invalid_source_closure_watermark}}
      end
    end)
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> {:error, {:missing_map_payload, key}}
    end
  end

  defp fetch_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      _other -> {:error, {:missing_list_payload, key}}
    end
  end

  defp read_string(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp read_integer(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _other -> nil
        end

      _other ->
        nil
    end
  end
end
