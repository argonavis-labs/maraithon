defmodule Maraithon.LLM.BoundedResponse do
  @moduledoc false

  def collector(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    fn {:data, data}, {req, resp} when is_binary(data) ->
      bytes = Map.get(resp.private, :bounded_response_bytes, 0) + byte_size(data)
      chunk_count = Map.get(resp.private, :bounded_response_chunk_count, 0) + 1

      if bytes > max_bytes or chunk_count > 2_048 do
        next_resp =
          resp
          |> Req.Response.put_private(:bounded_response_bytes, bytes)
          |> Req.Response.put_private(:bounded_response_chunk_count, chunk_count)
          |> Req.Response.put_private(:bounded_response_chunks, [])
          |> Req.Response.put_private(:bounded_response_overflow, true)

        {:halt, {req, next_resp}}
      else
        chunks = [data | Map.get(resp.private, :bounded_response_chunks, [])]

        next_resp =
          resp
          |> Req.Response.put_private(:bounded_response_bytes, bytes)
          |> Req.Response.put_private(:bounded_response_chunk_count, chunk_count)
          |> Req.Response.put_private(:bounded_response_chunks, chunks)

        {:cont, {req, next_resp}}
      end
    end
  end

  def overflow?(%{private: private}) when is_map(private),
    do: Map.get(private, :bounded_response_overflow, false)

  def overflow?(_response), do: false

  def body(%{private: private}) when is_map(private) do
    private
    |> Map.get(:bounded_response_chunks, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  def body(_response), do: ""

  def decode_json(response) do
    if overflow?(response) do
      {:error, :response_body_too_large}
    else
      case Jason.decode(body(response)) do
        {:ok, value} -> {:ok, value}
        {:error, _reason} -> {:error, :invalid_json_response}
      end
    end
  end

  def run(request, timeout_ms)
      when is_function(request, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    owner = self()

    with {:ok, task} <- start_request_task(owner, request) do
      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, _reason} -> {:error, %{reason: :request_failed}}
        nil -> {:error, %{reason: :timeout}}
      end
    end
  end

  defp start_request_task(owner, request) do
    if Process.whereis(Maraithon.Runtime.ToolCallSupervisor) do
      task =
        Task.Supervisor.async_nolink(Maraithon.Runtime.ToolCallSupervisor, fn ->
          worker = self()
          watcher = spawn(fn -> watch_owner(owner, worker) end)
          result = safe_request(request)
          send(watcher, {:request_finished, worker})
          result
        end)

      {:ok, task}
    else
      {:error, %{reason: :request_supervisor_unavailable}}
    end
  rescue
    _error -> {:error, %{reason: :request_supervisor_unavailable}}
  catch
    :exit, _reason -> {:error, %{reason: :request_supervisor_unavailable}}
  end

  defp watch_owner(owner, worker) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        :ok

      {:request_finished, ^worker} ->
        Process.demonitor(owner_ref, [:flush])
        Process.demonitor(worker_ref, [:flush])
        :ok
    end
  end

  defp safe_request(request) do
    request.()
  rescue
    _error -> {:error, %{reason: :request_failed}}
  catch
    _kind, _reason -> {:error, %{reason: :request_failed}}
  end
end
