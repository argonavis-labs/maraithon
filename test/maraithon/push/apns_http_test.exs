defmodule Maraithon.Push.APNS.HTTPTest do
  use ExUnit.Case, async: false

  alias Maraithon.Push.APNS.HTTP

  test "derives only the HTTPS pool destination from an APNs device URL" do
    assert HTTP.pool_destination("https://api.push.apple.com/3/device/private-token") ==
             {:ok, {:https, "api.push.apple.com", 443}}

    assert HTTP.pool_destination("http://api.push.apple.com/3/device/token") ==
             {:error, :invalid_url}

    assert HTTP.pool_destination(:not_a_url) == {:error, :invalid_url}
  end

  test "serializes one pool generation across concurrent device sends" do
    parent = self()
    destination = {:https, "apns-lock-#{System.unique_integer([:positive])}.test", 443}

    stop_pool = fn stopped_destination ->
      send(parent, {:pool_stopped, stopped_destination})
      :ok
    end

    request = fn id ->
      fn ->
        send(parent, {:request_started, id, self()})

        receive do
          {:release_request, ^id} -> {:ok, 200, ""}
        after
          1_000 -> {:error, :test_timeout}
        end
      end
    end

    first_task =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(parent, {:task_ready, 1, self()})

             receive do
               :start_managed_request -> :ok
             end

             send(
               parent,
               {:request_result, 1, HTTP.managed_request(destination, request.(1), stop_pool)}
             )
           end},
          id: {:managed_apns_request, 1}
        )
      )

    second_task =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(parent, {:task_ready, 2, self()})

             receive do
               :start_managed_request -> :ok
             end

             send(
               parent,
               {:request_result, 2, HTTP.managed_request(destination, request.(2), stop_pool)}
             )
           end},
          id: {:managed_apns_request, 2}
        )
      )

    assert_receive {:task_ready, 1, ^first_task}
    assert_receive {:task_ready, 2, ^second_task}
    send(first_task, :start_managed_request)
    send(second_task, :start_managed_request)

    assert_receive {:pool_stopped, ^destination}
    assert_receive {:request_started, first_id, first_worker}
    assert first_id in [1, 2]
    assert first_worker in [first_task, second_task]

    second_id = if first_id == 1, do: 2, else: 1
    refute_receive {:request_started, ^second_id, _worker}, 50

    send(first_worker, {:release_request, first_id})
    assert_receive {:request_started, ^second_id, second_worker}, 1_000
    assert_receive {:request_result, ^first_id, {:ok, 200, ""}}, 1_000
    refute_received {:pool_stopped, ^destination}

    send(second_worker, {:release_request, second_id})
    assert_receive {:request_result, ^second_id, {:ok, 200, ""}}, 1_000

    assert {:error, :cleanup} =
             HTTP.managed_request(destination, fn -> {:error, :cleanup} end, stop_pool)
  end

  test "recycles only after the connection has been idle" do
    parent = self()
    destination = {:https, "apns-idle-#{System.unique_integer([:positive])}.test", 443}
    clock = :atomics.new(1, signed: true)
    :atomics.put(clock, 1, 1_000)

    monotonic_ms = fn -> :atomics.get(clock, 1) end

    stop_pool = fn stopped_destination ->
      send(parent, {:pool_stopped, stopped_destination})
      :ok
    end

    request = fn -> {:ok, 200, ""} end

    assert {:ok, 200, ""} =
             HTTP.managed_request(destination, request, stop_pool, monotonic_ms)

    assert_receive {:pool_stopped, ^destination}

    :atomics.put(clock, 1, 60_999)

    assert {:ok, 200, ""} =
             HTTP.managed_request(destination, request, stop_pool, monotonic_ms)

    refute_received {:pool_stopped, ^destination}

    :atomics.put(clock, 1, 121_000)

    assert {:ok, 200, ""} =
             HTTP.managed_request(destination, request, stop_pool, monotonic_ms)

    assert_receive {:pool_stopped, ^destination}

    assert {:error, :cleanup} =
             HTTP.managed_request(
               destination,
               fn -> {:error, :cleanup} end,
               stop_pool,
               monotonic_ms
             )
  end

  test "retires a failed connection before the next request" do
    parent = self()
    destination = {:https, "apns-reset-#{System.unique_integer([:positive])}.test", 443}

    stop_pool = fn stopped_destination ->
      send(parent, {:pool_stopped, stopped_destination})
      :ok
    end

    assert {:error, :request_timeout} =
             HTTP.managed_request(
               destination,
               fn -> {:error, :request_timeout} end,
               stop_pool
             )

    # Initial generation reset, then defensive retirement after the error.
    assert_receive {:pool_stopped, ^destination}
    assert_receive {:pool_stopped, ^destination}

    assert {:ok, 200, ""} =
             HTTP.managed_request(destination, fn -> {:ok, 200, ""} end, stop_pool)

    # The failed generation was erased, so the next request starts fresh.
    assert_receive {:pool_stopped, ^destination}
  end
end
