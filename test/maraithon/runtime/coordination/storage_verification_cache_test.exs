defmodule Maraithon.Runtime.Coordination.StorageVerificationCacheTest do
  use ExUnit.Case, async: false

  alias Maraithon.Runtime.Coordination.StorageVerificationCache, as: Cache

  setup do
    previous = Application.get_env(:maraithon, Maraithon.Runtime, [])
    Cache.invalidate()

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, previous)
      Cache.invalidate()
    end)

    :ok
  end

  defp put_ttl(ms) do
    runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(runtime, :protocol_storage_verification_cache_ms, ms)
    )
  end

  defp counting_verify(pid, value) do
    fn ->
      send(pid, {:verified, value})
      value
    end
  end

  test "reuses a successful verification inside the window and never caches failures" do
    put_ttl(60_000)
    key = {__MODULE__, :ready}

    assert Cache.fetch(key, counting_verify(self(), true), &(&1 == true))
    assert_received {:verified, true}

    assert Cache.fetch(key, counting_verify(self(), :never_called), &(&1 == true))
    refute_received {:verified, _}

    Cache.invalidate()
    refute Cache.fetch(key, counting_verify(self(), false), &(&1 == true))
    assert_received {:verified, false}

    # The failure was not cached: the next call verifies again.
    assert Cache.fetch(key, counting_verify(self(), true), &(&1 == true))
    assert_received {:verified, true}
  end

  test "a zero window verifies on every call" do
    put_ttl(0)
    key = {__MODULE__, :uncached}

    assert :ok = Cache.fetch(key, counting_verify(self(), :ok), &(&1 == :ok))
    assert_received {:verified, :ok}
    assert :ok = Cache.fetch(key, counting_verify(self(), :ok), &(&1 == :ok))
    assert_received {:verified, :ok}
  end

  test "serializes a concurrent expiry into one verification" do
    put_ttl(60_000)
    key = {__MODULE__, :concurrent}
    counter = :atomics.new(1, signed: false)

    verify = fn ->
      :atomics.add_get(counter, 1, 1)
      Enum.each(1..1_000, fn _ -> :erlang.yield() end)
      :ok
    end

    results =
      1..32
      |> Task.async_stream(
        fn _ -> Cache.fetch(key, verify, &(&1 == :ok)) end,
        max_concurrency: 32,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert :atomics.get(counter, 1) == 1
  end

  test "keys are independent and an invalid setting falls back to the default window" do
    put_ttl(:bogus)
    assert Cache.ttl_ms() == :timer.minutes(5)

    assert Cache.fetch({__MODULE__, :a}, counting_verify(self(), :ok), &(&1 == :ok))
    assert_received {:verified, :ok}
    assert Cache.fetch({__MODULE__, :b}, counting_verify(self(), :ok), &(&1 == :ok))
    assert_received {:verified, :ok}
    assert Cache.fetch({__MODULE__, :a}, counting_verify(self(), :never), &(&1 == :ok))
    refute_received {:verified, _}
  end

  test "an invalidation during verification discards that proof and verifies again" do
    put_ttl(60_000)
    parent = self()
    counter = :atomics.new(1, signed: false)

    task =
      Task.async(fn ->
        Cache.fetch(
          {__MODULE__, :generation},
          fn ->
            attempt = :atomics.add_get(counter, 1, 1)
            send(parent, {:verification_started, self(), attempt})

            receive do
              :finish_proof -> attempt
            end
          end,
          &is_integer/1
        )
      end)

    assert_receive {:verification_started, verifier, 1}
    Cache.invalidate()
    send(verifier, :finish_proof)
    assert_receive {:verification_started, ^verifier, 2}
    send(verifier, :finish_proof)
    assert Task.await(task) == 2

    assert Cache.fetch(
             {__MODULE__, :generation},
             fn -> flunk("fresh proof was not cached") end,
             &is_integer/1
           ) == 2
  end

  test "simultaneous publication preserves independent keys" do
    put_ttl(60_000)
    parent = self()

    tasks =
      for key <- [:first, :second] do
        Task.async(fn ->
          Cache.fetch(
            {__MODULE__, key},
            fn ->
              send(parent, {:proof_ready, self()})

              receive do
                :publish -> key
              end
            end,
            &is_atom/1
          )
        end)
      end

    assert_receive {:proof_ready, first}
    assert_receive {:proof_ready, second}
    send(first, :publish)
    send(second, :publish)
    assert Enum.map(tasks, &Task.await/1) == [:first, :second]

    for key <- [:first, :second] do
      assert Cache.fetch(
               {__MODULE__, key},
               fn -> flunk("independent key was lost") end,
               &is_atom/1
             ) == key
    end
  end
end
