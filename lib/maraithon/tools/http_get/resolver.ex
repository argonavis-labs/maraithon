defmodule Maraithon.Tools.HttpGet.Resolver do
  @moduledoc false

  @families [:inet, :inet6]
  @max_resolved_addresses 32

  @type clock :: (-> integer())
  @type lookup :: (charlist(), :inet | :inet6, non_neg_integer() ->
                     {:ok, [:inet.ip_address()]} | {:error, term()})

  @spec resolve(String.t(), integer(), keyword()) ::
          {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve(hostname, deadline, opts \\ [])

  def resolve(hostname, deadline, opts)
      when is_binary(hostname) and is_integer(deadline) and is_list(opts) do
    clock = Keyword.get(opts, :clock, &monotonic_milliseconds/0)
    lookup = Keyword.get(opts, :lookup, &:inet.getaddrs/3)
    task_supervisor = Keyword.get(opts, :task_supervisor, Maraithon.Runtime.ToolCallSupervisor)

    with :ok <- validate_hostname(hostname) do
      case :inet.parse_address(String.to_charlist(hostname)) do
        {:ok, address} ->
          {:ok, [address]}

        {:error, :einval} ->
          resolve_hostname(hostname, deadline, clock, lookup, task_supervisor)

        {:error, reason} ->
          {:error, {:invalid_address, reason}}
      end
    end
  end

  def resolve(_hostname, _deadline, _opts), do: {:error, :invalid_hostname}

  defp resolve_hostname(hostname, deadline, clock, lookup, task_supervisor) do
    with {:ok, lookup_timeout} <- remaining_timeout(deadline, clock) do
      hostname = String.to_charlist(hostname)

      tasks =
        Enum.map(@families, fn family ->
          Task.Supervisor.async_nolink(task_supervisor, fn ->
            safe_lookup(lookup, hostname, family, lookup_timeout)
          end)
        end)

      yield_timeout = remaining_timeout_value(deadline, clock)
      yielded = Task.yield_many(tasks, yield_timeout)

      Enum.each(yielded, fn
        {task, nil} -> Task.shutdown(task, :brutal_kill)
        {_task, _result} -> :ok
      end)

      @families
      |> Enum.zip(yielded)
      |> collect_results()
    end
  rescue
    _error -> {:error, :dns_lookup_failed}
  catch
    _kind, _reason -> {:error, :dns_lookup_failed}
  end

  defp safe_lookup(lookup, hostname, family, timeout) do
    lookup.(hostname, family, timeout)
  rescue
    _error -> {:error, :lookup_failed}
  catch
    _kind, _reason -> {:error, :lookup_failed}
  end

  defp collect_results(family_results) do
    family_results
    |> Enum.reduce_while({:ok, []}, fn
      {_family, {_task, nil}}, _addresses ->
        {:halt, {:error, :dns_timeout}}

      {family, {_task, {:ok, {:ok, addresses}}}}, {:ok, collected}
      when is_list(addresses) ->
        combined = collected ++ addresses

        cond do
          length(combined) > @max_resolved_addresses ->
            {:halt, {:error, :too_many_addresses}}

          Enum.all?(addresses, &address_for_family?(&1, family)) ->
            {:cont, {:ok, combined}}

          true ->
            {:halt, {:error, :invalid_dns_response}}
        end

      {_family, {_task, {:ok, {:error, reason}}}}, {:ok, collected}
      when reason in [:nxdomain, :nodata] ->
        {:cont, {:ok, collected}}

      {family, {_task, {:ok, {:error, reason}}}}, _addresses ->
        {:halt, {:error, {:dns_error, family, reason}}}

      {_family, {_task, {:exit, _reason}}}, _addresses ->
        {:halt, {:error, :dns_lookup_failed}}

      {_family, {_task, _unexpected}}, _addresses ->
        {:halt, {:error, :invalid_dns_response}}
    end)
    |> case do
      {:ok, []} -> {:error, :no_addresses}
      {:ok, addresses} -> {:ok, Enum.uniq(addresses)}
      {:error, _reason} = error -> error
    end
  end

  defp address_for_family?(address, :inet),
    do: is_tuple(address) and tuple_size(address) == 4 and :inet.is_ip_address(address)

  defp address_for_family?(address, :inet6),
    do: is_tuple(address) and tuple_size(address) == 8 and :inet.is_ip_address(address)

  defp validate_hostname(hostname) do
    cond do
      hostname == "" -> {:error, :invalid_hostname}
      not String.valid?(hostname) -> {:error, :invalid_hostname}
      true -> :ok
    end
  end

  defp remaining_timeout(deadline, clock) do
    case remaining_timeout_value(deadline, clock) do
      timeout when timeout > 0 -> {:ok, timeout}
      _timeout -> {:error, :dns_timeout}
    end
  end

  defp remaining_timeout_value(deadline, clock) do
    max(deadline - clock.(), 0)
  end

  defp monotonic_milliseconds do
    System.monotonic_time(:millisecond)
  end
end
