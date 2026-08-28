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

  test "keys are independent and an invalid setting falls back to the default window" do
    put_ttl(:bogus)
    assert Cache.ttl_ms() == 15_000

    assert Cache.fetch({__MODULE__, :a}, counting_verify(self(), :ok), &(&1 == :ok))
    assert_received {:verified, :ok}
    assert Cache.fetch({__MODULE__, :b}, counting_verify(self(), :ok), &(&1 == :ok))
    assert_received {:verified, :ok}
    assert Cache.fetch({__MODULE__, :a}, counting_verify(self(), :never), &(&1 == :ok))
    refute_received {:verified, _}
  end
end
